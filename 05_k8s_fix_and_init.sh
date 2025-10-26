#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 05_k8s_fix_and_init_v2.sh
# 作用：初始化 Kubernetes 控制平面，导出镜像，分发并 join worker
# ============================================================

# === 输出函数 ===
COLOR_BLUE="\033[1;34m"; COLOR_GREEN="\033[1;32m"; COLOR_YELLOW="\033[1;33m"; COLOR_RESET="\033[0m"
step() { echo -e "${COLOR_BLUE}[STEP]${COLOR_RESET} $*"; }
ok()   { echo -e "${COLOR_GREEN}✅${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_YELLOW}⚠️${COLOR_RESET} $*"; }

# === 引入配置 ===
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${BASE_DIR}/00_cluster.env"

if [[ ! -f /opt/k8s-setup/phase4_done ]]; then
  warn "未检测到 Phase 4 标记，请先执行 04_containerd_k8s.sh"
  exit 1
fi

mkdir -p /opt/k8s-setup
if [[ -f /opt/k8s-setup/phase5_done ]]; then
  ok "检测到 Phase 5 已执行，跳过。"
  exit 0
fi

CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-${ALL_MASTERS[0]}}"
POD_CIDR="${POD_CIDR:-192.168.0.0/16}"
IMAGE_REPO="${PAUSE_IMAGE%/pause:*}"

# === 镜像列表 ===
IMAGE_LIST=(
  "kube-apiserver:v${K8S_VERSION%%-*}"
  "kube-controller-manager:v${K8S_VERSION%%-*}"
  "kube-scheduler:v${K8S_VERSION%%-*}"
  "kube-proxy:v${K8S_VERSION%%-*}"
  "etcd:3.5.12-0"
  "coredns:v1.11.1"
  "pause:3.9"
)

CACHE_DIR="/opt/k8s-image-cache"
mkdir -p "${CACHE_DIR}"

# ============================================================
# 1. 镜像拉取与缓存
# ============================================================
step "拉取 Kubernetes 核心镜像到 ${CACHE_DIR}"

for img in "${IMAGE_LIST[@]}"; do
  full="${IMAGE_REPO}/${img}"
  tarname="$(echo "${img}" | tr '/:' '_').tar"
  echo ">>> 拉取 ${full}"
  if ! ctr -n k8s.io images pull "${full}" >/dev/null 2>&1; then
    crictl pull "${full}" >/dev/null 2>&1 || warn "拉取失败：${full}"
  fi
  ctr -n k8s.io images export "${CACHE_DIR}/${tarname}" "${full}" >/dev/null 2>&1 || true
done
ok "镜像缓存完成"

# ============================================================
# 2. kubeadm init
# ============================================================
step "执行 kubeadm init"
kubeadm reset -f >/dev/null 2>&1 || true
rm -rf /etc/kubernetes /var/lib/etcd /var/lib/cni /etc/cni/net.d || true

INIT_ARGS=(
  "--apiserver-advertise-address=${CONTROL_PLANE_IP}"
  "--pod-network-cidr=${POD_CIDR}"
  "--image-repository=${IMAGE_REPO}"
  "--v=5"
)
kubeadm init "${INIT_ARGS[@]}"
ok "kubeadm init 成功"

# ============================================================
# 3. 配置 kubectl
# ============================================================
mkdir -p "$HOME/.kube"
cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"
ok "kubectl 已配置"

# ============================================================
# 4. 生成 join 命令
# ============================================================
JOIN_CMD="$(kubeadm token create --print-join-command)"
echo "${JOIN_CMD}" >"${CACHE_DIR}/join.sh"
chmod +x "${CACHE_DIR}/join.sh"
ok "Join 命令已生成"

# ============================================================
# 5. 分发镜像与 join.sh 并远程执行 join
# ============================================================
step "分发镜像缓存并 join"

for NODE in "${ALL_WORKERS[@]}"; do
  if [[ "$NODE" == "$(hostname -I | awk '{print $1}')" ]]; then continue; fi
  echo ">>> 处理节点 ${NODE}"
  if ! timeout 3 bash -c "echo > /dev/tcp/${NODE}/${SSH_PORT}" 2>/dev/null; then
    warn "节点 ${NODE} 不可达"
    continue
  fi

  if ! timeout 60s sshpass -p "${SSH_PASS}" scp -P "${SSH_PORT}" -o StrictHostKeyChecking=no -r "${CACHE_DIR}" "${SSH_USER}@${NODE}:/opt/" >/dev/null 2>&1; then
    warn "SCP 到 ${NODE} 失败"
    continue
  fi

  timeout 150s sshpass -p "${SSH_PASS}" ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=no "${SSH_USER}@${NODE}" 'bash -s' <<'EOF' >/dev/null 2>&1 || true
set -e
CACHE_DIR="/opt/k8s-image-cache"
cd "${CACHE_DIR}" || exit 0
for f in *.tar; do
  [ -f "$f" ] || continue
  ctr -n k8s.io images import "$f" >/dev/null 2>&1 || crictl images >/dev/null 2>&1 || true
done
bash "${CACHE_DIR}/join.sh" || true
EOF
  ok "节点 ${NODE} join 已执行"
done

# ============================================================
# 6. 验证节点
# ============================================================
step "等待节点注册"
sleep 10
kubectl get nodes -o wide || warn "kubectl 尚未返回全部节点"
ok "Phase 5 完成：集群已初始化 🎉"

touch /opt/k8s-setup/phase5_done
