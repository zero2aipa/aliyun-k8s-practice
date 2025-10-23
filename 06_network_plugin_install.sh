#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 06_network_plugin_install.sh
# 安装 Calico 或 Flannel 网络插件（支持镜像分发到 worker 节点）
# ============================================================

PLUGIN=${1:-calico}  # 可传入 flannel
PLUGIN_DIR="/opt/k8s-net-plugin"
CACHE_DIR="/opt/k8s-image-cache"

# ======== 集群节点信息（与 00_cluster.env 保持一致）========
CONTROL_PLANE_IP="10.0.1.1"
WORKER_IPS=("10.0.2.1" "10.0.2.2")
SSH_USER="root"
SSH_PASS="YourRootPassword"

# ======== 彩色输出 =========
COLOR_BLUE="\033[1;34m"; COLOR_GREEN="\033[1;32m"; COLOR_YELLOW="\033[1;33m"; COLOR_RESET="\033[0m"
step() { echo -e "${COLOR_BLUE}[STEP]${COLOR_RESET} $*"; }
ok()   { echo -e "${COLOR_GREEN}✅${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_YELLOW}⚠️${COLOR_RESET} $*"; }

mkdir -p "${PLUGIN_DIR}" "${CACHE_DIR}"
cd "${PLUGIN_DIR}"

# ============================================================
# 1️⃣ 检查 kubectl 状态
# ============================================================
step "检测 kubectl 与集群连通性"
if ! command -v kubectl >/dev/null; then
  warn "kubectl 未找到，请确保在 cp-1 执行。"
  exit 1
fi
if ! kubectl version --short >/dev/null 2>&1; then
  warn "kubectl 无法连接 API Server，请检查 ~/.kube/config"
  exit 1
fi
ok "kubectl 可用"

# ============================================================
# 2️⃣ 下载网络插件 YAML（如无则缓存）
# ============================================================
case "${PLUGIN,,}" in
  calico)
    PLUGIN_NAME="Calico"
    PLUGIN_URL="https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml"
    LOCAL_FILE="${PLUGIN_DIR}/calico.yaml"
    ;;
  flannel)
    PLUGIN_NAME="Flannel"
    PLUGIN_URL="https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"
    LOCAL_FILE="${PLUGIN_DIR}/flannel.yaml"
    ;;
  *)
    warn "未知插件类型: ${PLUGIN}。仅支持 calico / flannel"
    exit 1
    ;;
esac

step "准备 ${PLUGIN_NAME} 网络插件 YAML"
if [[ -f "${LOCAL_FILE}" ]]; then
  ok "已存在本地缓存 ${LOCAL_FILE}"
else
  curl -fL "${PLUGIN_URL}" -o "${LOCAL_FILE}" || {
    warn "下载 ${PLUGIN_NAME} YAML 失败，请检查网络或手动导入"
    exit 1
  }
  ok "已下载 ${PLUGIN_NAME} YAML"
fi

# ============================================================
# 3️⃣ 提取并拉取镜像
# ============================================================
step "分析并拉取 ${PLUGIN_NAME} 所需镜像"
IMAGES=$(grep -Eo 'image: [^ ]+' "${LOCAL_FILE}" | awk '{print $2}' | sort -u)

for IMG in ${IMAGES}; do
  FILE_NAME="${CACHE_DIR}/$(echo "${IMG}" | tr '/:' '_').tar"
  if [[ -f "${FILE_NAME}" ]]; then
    ok "缓存存在：${FILE_NAME}"
  else
    echo ">>> 拉取 ${IMG}"
    crictl pull "${IMG}" >/dev/null 2>&1 || ctr -n k8s.io images pull "${IMG}"
    echo ">>> 导出 ${IMG} 到 ${FILE_NAME}"
    ctr -n k8s.io images export "${FILE_NAME}" "${IMG}" >/dev/null 2>&1
  fi
done
ok "${PLUGIN_NAME} 镜像缓存完毕"

# ============================================================
# 4️⃣ 将镜像分发并加载到 Worker 节点
# ============================================================
step "分发并加载 ${PLUGIN_NAME} 镜像到 Worker 节点"
for NODE in "${WORKER_IPS[@]}"; do
  echo ">>> 分发到 ${NODE}"
  sshpass -p "${SSH_PASS}" scp -o StrictHostKeyChecking=no -r "${CACHE_DIR}" "${SSH_USER}@${NODE}:${CACHE_DIR}" >/dev/null
  sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no "${SSH_USER}@${NODE}" bash -s <<'EOF'
set -e
CACHE_DIR="/opt/k8s-image-cache"
for f in ${CACHE_DIR}/*.tar; do
  [ -f "$f" ] || continue
  echo ">>> 导入镜像: $(basename "$f")"
  ctr -n k8s.io images import "$f" >/dev/null || echo "⚠️ 导入 $f 失败"
done
EOF
done
ok "镜像已同步至所有 Worker 节点"

# ============================================================
# 5️⃣ 部署网络插件 YAML
# ============================================================
step "部署 ${PLUGIN_NAME} 插件"
kubectl apply -f "${LOCAL_FILE}"

echo "等待 ${PLUGIN_NAME} Pod 启动中..."
sleep 5
kubectl get pods -n kube-system -o wide | grep -E "calico|flannel" || true
ok "${PLUGIN_NAME} 插件部署完成 🎉"

# ============================================================
# 6️⃣ 验证节点状态
# ============================================================
step "验证节点网络状态"
kubectl get nodes -o wide
kubectl get pods -n kube-system -o wide | grep -E "calico|flannel" || true
ok "网络插件部署验证完成"
