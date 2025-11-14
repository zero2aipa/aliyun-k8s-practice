#!/usr/bin/env bash
# ============================================================
# check_cluster_all.sh
# 离线 K8s 集群全局状态检查脚本
#
# 功能：
#   - 本机 K8s 包 / 二进制 / 服务 / containerd 配置检查
#   - 残留路径 / APT 源 / CNI 网卡检查
#   - 读取 00_cluster.env，按 ALL_NODES 做远端节点检查
#   - 如有 kubeconfig，则做集群级 kubectl 检查
#
# 适用环境：
#   - Ubuntu 22.04 + containerd + kubeadm
#   - 离线环境 / 半离线环境
# ============================================================

set -euo pipefail

# ---------- 基础输出样式 ----------
COLOR_BLUE="\033[1;34m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_RED="\033[1;31m"
COLOR_RESET="\033[0m"

step()  { echo -e "${COLOR_BLUE}[STEP]${COLOR_RESET} $*"; }
ok()    { echo -e "${COLOR_GREEN}✅${COLOR_RESET} $*"; }
warn()  { echo -e "${COLOR_YELLOW}⚠️ ${COLOR_RESET} $*"; }
err()   { echo -e "${COLOR_RED}❌${COLOR_RESET} $*"; }

# ---------- 加载集群配置 ----------
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_ENV="${BASE_DIR}/00_cluster.env"

if [[ -f "${CLUSTER_ENV}" ]]; then
  # shellcheck disable=SC1090
  source "${CLUSTER_ENV}"
  ok "已加载集群配置: ${CLUSTER_ENV}"
else
  warn "未找到 00_cluster.env，将仅检查本机（不做远端节点检查）"
fi

LOCAL_IP="$(hostname -I | awk '{print $1}')"
HOSTNAME_SHORT="$(hostname -s)"
echo
step "当前节点: ${HOSTNAME_SHORT} (${LOCAL_IP})"

# ---------- 辅助函数 ----------

check_pkg() {
  local pkg="$1"
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    ok "包已安装: ${pkg}"
  else
    warn "包未安装: ${pkg}"
  fi
}

check_cmd() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    local path
    path="$(command -v "$cmd")"
    ok "命令存在: ${cmd} (${path})"
  else
    warn "命令不存在: ${cmd}"
  fi
}

check_service_unit_exists() {
  local svc="$1"
  if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
    return 0
  fi
  # 再保险：查文件是否存在
  if [[ -f "/lib/systemd/system/${svc}.service" ]] || [[ -f "/etc/systemd/system/${svc}.service" ]]; then
    return 0
  fi
  return 1
}

check_service_status() {
  local svc="$1"
  if check_service_unit_exists "$svc"; then
    if systemctl is-active --quiet "$svc"; then
      ok "服务运行中: ${svc}"
    else
      warn "服务已安装但未运行: ${svc}"
    fi
  else
    warn "服务未安装: ${svc}"
  fi
}

line() {
  echo "------------------------------------------------------------"
}

# ============================================================
# 1. 本机包 / 命令 / 服务检查
# ============================================================
echo
line
step "本机 Kubernetes 包检查"

K8S_PKGS=(kubelet kubeadm kubectl cri-tools kubernetes-cni)
for p in "${K8S_PKGS[@]}"; do
  check_pkg "$p"
done

echo
step "本机 Containerd 与运行时包检查"
RUNTIME_PKGS=(containerd runc libseccomp2 bridge-utils)
for p in "${RUNTIME_PKGS[@]}"; do
  check_pkg "$p"
done

echo
step "本机系统辅助工具检查"
AUX_PKGS=(sshpass conntrack ebtables socat ipset bash-completion)
for p in "${AUX_PKGS[@]}"; do
  check_pkg "$p"
done

echo
step "本机关键命令检查"
CMDS=(kubelet kubeadm kubectl crictl containerd)
for c in "${CMDS[@]}"; do
  check_cmd "$c"
done

echo
step "本机 systemd 服务状态检查"
check_service_status containerd
check_service_status kubelet
# cri-dockerd 在 containerd 模式通常不用
if check_service_unit_exists "cri-dockerd"; then
  check_service_status cri-dockerd
else
  ok "cri-dockerd 未安装（使用 containerd 模式可忽略）"
fi

# ============================================================
# 2. containerd 配置检查
# ============================================================
echo
line
step "本机 containerd 配置检查 (/etc/containerd/config.toml)"

if [[ -f /etc/containerd/config.toml ]]; then
  ok "发现 /etc/containerd/config.toml"

  if grep -q 'SystemdCgroup = true' /etc/containerd/config.toml 2>/dev/null; then
    ok "SystemdCgroup = true（与 kubelet systemd cgroup 匹配）"
  else
    warn "未检测到 SystemdCgroup = true，可能导致 kubeadm init/join 报 cgroup 错误"
  fi

  # 检查 sandbox_image（不强制，给个提示）
  # local sandbox
  sandbox="$(grep -E 'sandbox_image *= *"' /etc/containerd/config.toml 2>/dev/null || true)"
  if [[ -n "$sandbox" ]]; then
    echo "  当前 sandbox_image: ${sandbox}"
  else
    warn "未检测到 sandbox_image 配置，可能使用默认 gcr.io 镜像（离线环境建议改为本地镜像）"
  fi
else
  warn "/etc/containerd/config.toml 不存在，containerd 正在使用默认内置配置"
fi

# ============================================================
# 3. 残留路径 / CNI / APT 源检查
# ============================================================
echo
line
step "本机残留路径检查（用于判断是否彻底清理过集群）"

RESIDUAL_PATHS=(
  /etc/kubernetes
  /var/lib/kubelet
  /var/lib/containerd
  /etc/containerd
  /opt/cni
  /etc/cni
  /var/lib/cni
  /opt/k8s-pkg-cache
  /opt/k8s-pkg-cache-full
)

for p in "${RESIDUAL_PATHS[@]}"; do
  if [[ -e "$p" ]]; then
    warn "残留路径存在: $p"
  else
    ok "路径不存在（已清理或未使用）: $p"
  fi
done

echo
step "本机 CNI 虚拟网卡检查"

if ip link show cni0 >/dev/null 2>&1; then
  warn "发现 CNI 网卡: cni0（说明之前初始化过网络插件）"
else
  ok "CNI 接口 cni0 不存在（适合干净 init）"
fi

if ip link show flannel.1 >/dev/null 2>&1; then
  warn "发现 Flannel 网卡: flannel.1"
else
  ok "Flannel 接口 flannel.1 不存在"
fi

echo
step "Kubernetes APT 源检查（避免在线源影响离线流程）"
if grep -Rqi "pkgs.k8s.io\|apt.kubernetes.io" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
  warn "发现 Kubernetes APT 源残留（离线环境建议注释或移除）"
else
  ok "未发现 Kubernetes APT 源（适合纯离线环境）"
fi

# ============================================================
# 4. 远端节点检查（基于 00_cluster.env / ALL_NODES）
# ============================================================
echo
line
step "远端节点基础检查"

SSH_USER_LOCAL="${SSH_USER:-root}"
SSH_PORT_LOCAL="${SSH_PORT:-22}"

if [[ -n "${ALL_NODES[*]:-}" ]]; then
  for NODE in "${ALL_NODES[@]}"; do
    echo
    echo ">>> 检查节点 ${NODE}"

    if [[ "$NODE" == "$LOCAL_IP" ]]; then
      echo "  (本机，已完成详细检查)"
      continue
    fi

    if ! timeout 3 bash -c "echo > /dev/tcp/${NODE}/${SSH_PORT_LOCAL}" 2>/dev/null; then
      warn "  节点 ${NODE} SSH (${SSH_PORT_LOCAL}) 不可达，跳过远端检查"
      continue
    fi

    ssh -p "${SSH_PORT_LOCAL}" -o StrictHostKeyChecking=no "${SSH_USER_LOCAL}@${NODE}" bash -s <<'EOF'
COLOR_GREEN="\033[1;32m"; COLOR_YELLOW="\033[1;33m"; COLOR_RESET="\033[0m"
ok()   { echo -e "${COLOR_GREEN}✅${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_YELLOW}⚠️ ${COLOR_RESET} $*"; }

NODE_HOST="$(hostname -s)"
NODE_IP="$(hostname -I | awk '{print $1}')"
echo "  节点: ${NODE_HOST} (${NODE_IP})"

# 包检查（简版）
for p in kubelet kubeadm kubectl containerd; do
  if dpkg -s "$p" >/dev/null 2>&1; then
    ok "  包已安装: $p"
  else
    warn "  包未安装: $p"
  fi
done

# 服务状态（简版）
if systemctl is-active --quiet containerd; then
  ok "  containerd 运行中"
else
  warn "  containerd 未运行"
fi

if systemctl is-active --quiet kubelet; then
  ok "  kubelet 运行中（如未 init/join 可能不断重启）"
else
  warn "  kubelet 未运行"
fi

# containerd 配置存在性
if [[ -f /etc/containerd/config.toml ]]; then
  ok "  存在 /etc/containerd/config.toml"
else
  warn "  缺少 /etc/containerd/config.toml"
fi
EOF

  done
else
  warn "ALL_NODES 未定义，跳过远端节点检查（请在 00_cluster.env 中定义 ALL_NODES 数组）"
fi

# ============================================================
# 5. 集群级检查（kubectl）
# ============================================================
echo
line
step "集群级状态检查（kubectl）"

KUBECONFIG_LOCAL="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

if command -v kubectl >/dev/null 2>&1 && [[ -f "${KUBECONFIG_LOCAL}" ]]; then
  export KUBECONFIG="${KUBECONFIG_LOCAL}"
  ok "使用 KUBECONFIG=${KUBECONFIG}"

  echo
  echo ">>> kubectl get nodes"
  if ! kubectl get nodes; then
    warn "kubectl get nodes 失败，请检查 apiserver / 网络插件 / 防火墙"
  fi

  echo
  echo ">>> kubectl get pods -A | head -n 30"
  if ! kubectl get pods -A | head -n 30; then
    warn "无法获取 Pod 列表，可能集群尚未 init/join 或 APIServer 未就绪"
  fi
else
  warn "未找到可用的 kubeconfig（${KUBECONFIG_LOCAL}），跳过集群级检查（可能尚未执行 kubeadm init）"
fi

echo
line
ok "check_cluster_all.sh 检查完成（本机 + 远端 + 集群）"
