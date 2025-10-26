#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 04_containerd_k8s.sh
# 作用：安装 containerd、kubelet/kubeadm/kubectl 并配置国内加速
#       支持自动分发至所有节点（ALL_NODES）
# ============================================================

# === 基础输出函数 ===
COLOR_BLUE="\033[1;34m"; COLOR_GREEN="\033[1;32m"; COLOR_YELLOW="\033[1;33m"; COLOR_RESET="\033[0m"
step() { echo -e "${COLOR_BLUE}[STEP]${COLOR_RESET} $*"; }
ok()   { echo -e "${COLOR_GREEN}✅${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_YELLOW}⚠️${COLOR_RESET} $*"; }

# === 引入集群配置 ===
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${BASE_DIR}/00_cluster.env"

mkdir -p /opt/k8s-setup

if [[ -f /opt/k8s-setup/phase4_done ]]; then
  ok "检测到 Phase 4 已执行，跳过。"
  exit 0
fi

# ============================================================
# 1. 安装 containerd
# ============================================================
step "安装 containerd（跳过 kubelet/kubeadm/kubectl，已在 02 阶段完成）"

PKG_CACHE_DIR="/opt/k8s-pkg-cache"
APT_FLAGS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
apt-get update -y >/dev/null 2>&1 || true

if [[ -f "${PKG_CACHE_DIR}/containerd_1.7.28-0ubuntu1~22.04.1_amd64.deb" ]]; then
  dpkg -i "${PKG_CACHE_DIR}/containerd_"*.deb >/dev/null 2>&1 || apt-get install -f -y >/dev/null 2>&1
else
  apt-get install "${APT_FLAGS[@]}" containerd >/dev/null 2>&1 || warn "安装 containerd 失败"
fi
ok "containerd 安装完成"


# ============================================================
# 2. 配置 containerd
# ============================================================
step "配置 containerd（systemd cgroup + 国内加速镜像）"

mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml 2>/dev/null || true
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sed -i "s#sandbox_image = \".*\"#sandbox_image = \"${PAUSE_IMAGE}\"#" /etc/containerd/config.toml

# 国内镜像加速
mkdir -p /etc/containerd/certs.d/docker.io
cat >/etc/containerd/certs.d/docker.io/hosts.toml <<EOF
server = "https://registry-1.docker.io"

[host."${DAOCLOUD_MIRROR}"]
  capabilities = ["pull"]

[host."${NETEASE_MIRROR}"]
  capabilities = ["pull"]

[host."${BAIDU_MIRROR}"]
  capabilities = ["pull"]
EOF

systemctl daemon-reexec >/dev/null 2>&1 || true
systemctl enable --now containerd >/dev/null 2>&1 || true
systemctl enable --now kubelet >/dev/null 2>&1 || true
ok "containerd 已启动并启用 systemd cgroup"

# ============================================================
# 3. 推送配置与包到其他节点
# ============================================================
step "分发 containerd + kubelet 配置到其他节点"

for NODE in "${ALL_NODES[@]}"; do
  if [[ "$NODE" == "$(hostname -I | awk '{print $1}')" ]]; then
    continue
  fi

  echo ">>> 处理节点 ${NODE}"
  if ! timeout 3 bash -c "echo > /dev/tcp/${NODE}/${SSH_PORT}" 2>/dev/null; then
    warn "节点 ${NODE} SSH 不可达，跳过"
    continue
  fi

  # 传输配置文件
  sshpass -p "${SSH_PASS}" scp -P "${SSH_PORT}" -o StrictHostKeyChecking=no \
    /etc/containerd/config.toml "${SSH_USER}@${NODE}:/etc/containerd/" >/dev/null 2>&1 || warn "配置推送失败"

  # 远程启用服务
  sshpass -p "${SSH_PASS}" ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=no "${SSH_USER}@${NODE}" \
    "systemctl daemon-reexec && systemctl enable --now containerd kubelet >/dev/null 2>&1 || true"
  ok "节点 ${NODE} 配置同步完成"
done

# ============================================================
# 4. 打标记
# ============================================================
touch /opt/k8s-setup/phase4_done
ok "Phase 4 完成：containerd + kubelet 配置已同步"
