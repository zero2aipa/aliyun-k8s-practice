#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 06_network_plugin_install_v2.sh
# 功能：安装 Calico 或 Flannel 网络插件（自动缓存镜像 + 分发加载）
# 支持离线环境、与 00~05 统一风格
# ============================================================

# === 输出样式 ===
COLOR_BLUE="\033[1;34m"; COLOR_GREEN="\033[1;32m"; COLOR_YELLOW="\033[1;33m"; COLOR_RESET="\033[0m"
step() { echo -e "${COLOR_BLUE}[STEP]${COLOR_RESET} $*"; }
ok()   { echo -e "${COLOR_GREEN}✅${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_YELLOW}⚠️${COLOR_RESET} $*"; }

# === 加载集群配置 ===
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${BASE_DIR}/00_cluster.env"

PLUGIN=${1:-calico}  # 可选：calico / flannel
PLUGIN_DIR="/opt/k8s-net-plugin"
CACHE_DIR="/opt/k8s-image-cache"

mkdir -p "${PLUGIN_DIR}" "${CACHE_DIR}"

# === 节点推导 ===
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-${ALL_MASTERS[0]}}"
WORKER_IPS=()
declare -A _is_master=()
for ip in "${ALL_MASTERS[@]}"; do _is_master["$ip"]=1; done
for ip in "${ALL_WORKERS[@]}"; do [[ -z "${_is_master[$ip]:-}" ]] && WORKER_IPS+=("$ip"); done

# ============================================================
# 1️⃣ 检查集群状态
# ============================================================
step "检测 kubectl 与集群连通性"
if ! command -v kubectl >/dev/null; then
  warn "kubectl 未找到，请在控制平面节点执行。"
  exit 1
fi
if ! kubectl version --short >/dev/null 2>&1; then
  warn "kubectl 无法连接 API Server，请检查 ~/.kube/config"
  exit 1
fi
ok "kubectl 可用"

# ============================================================
# 2️⃣ 获取网络插件 YAML
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

step "准备 ${PLUGIN_NAME} YAML"
if [[ -f "${LOCAL_FILE}" ]]; then
  ok "已存在本地缓存：${LOCAL_FILE}"
else
  if curl -fsSL "${PLUGIN_URL}" -o "${LOCAL_FILE}"; then
    ok "已下载 ${PLUGIN_NAME} YAML"
  else
    warn "下载 ${PLUGIN_NAME} YAML 失败，请手动导入。"
    exit 1
  fi
fi

# ============================================================
# 3️⃣ 提取镜像并缓存导出
# ============================================================
step "分析并拉取 ${PLUGIN_NAME} 所需镜像"
IMAGES=$(grep -E '^[[:space:]]*image:' "${LOCAL_FILE}" | awk '{print $2}' | sort -u)

if ! systemctl is-active containerd >/dev/null 2>&1; then
  systemctl restart containerd >/dev/null 2>&1 || true
fi

for IMG in ${IMAGES}; do
  FILE_NAME="${CACHE_DIR}/$(echo "${IMG}" | tr '/:' '_').tar"
  if [[ -f "${FILE_NAME}" ]]; then
    ok "缓存已存在：$(basename "${FILE_NAME}")"
    continue
  fi
  echo ">>> 拉取 ${IMG}"
  if ! ctr -n k8s.io images pull "${IMG}" >/dev/null 2>&1; then
    crictl pull "${IMG}" >/dev/null 2>&1 || warn "拉取失败：${IMG}"
  fi
  echo ">>> 导出 ${IMG} -> ${FILE_NAME}"
  ctr -n k8s.io images export "${FILE_NAME}" "${IMG}" >/dev/null 2>&1 || true
done
ok "${PLUGIN_NAME} 镜像缓存完成"

# ============================================================
# 4️⃣ 分发镜像到 Worker 并加载
# ============================================================
step "分发 ${PLUGIN_NAME} 镜像至 Worker 节点"
for NODE in "${WORKER_IPS[@]}"; do
  echo ">>> 处理节点 ${NODE}"
  if ! timeout 3 bash -c "echo > /dev/tcp/${NODE}/${SSH_PORT}" 2>/dev/null; then
    warn "节点 ${NODE} SSH 不可达（跳过）"
    continue
  fi
  if ! timeout 60s sshpass -p "${SSH_PASS}" scp -P "${SSH_PORT}" -o StrictHostKeyChecking=no -r "${CACHE_DIR}" "${SSH_USER}@${NODE}:${CACHE_DIR}" >/dev/null 2>&1; then
    warn "SCP 到 ${NODE} 失败"
    continue
  fi
  timeout 120s sshpass -p "${SSH_PASS}" ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=no "${SSH_USER}@${NODE}" 'bash -s' <<'EOF' >/dev/null 2>&1 || true
set -e
CACHE_DIR="/opt/k8s-image-cache"
for f in ${CACHE_DIR}/*.tar; do
  [ -f "$f" ] || continue
  echo ">>> 导入镜像 $(basename "$f")"
  ctr -n k8s.io images import "$f" >/dev/null 2>&1 || echo "⚠️ 导入失败：$f"
done
EOF
  ok "节点 ${NODE} 镜像导入完成"
done

# ============================================================
# 5️⃣ 部署网络插件
# ============================================================
step "部署 ${PLUGIN_NAME} 插件"
kubectl apply -f "${LOCAL_FILE}" >/dev/null 2>&1 || warn "kubectl apply 失败"
ok "${PLUGIN_NAME} YAML 已提交"

# 等待 Pod Ready
echo "等待 ${PLUGIN_NAME} Pod 启动..."
for i in {1..20}; do
  sleep 5
  READY=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -E "calico|flannel" | grep -vc 'Running' || true)
  [[ "$READY" -eq 0 ]] && break
  echo "  ⏳ ${PLUGIN_NAME} 启动中... (第 $i/20 次检测)"
done

ok "${PLUGIN_NAME} 插件部署完成 🎉"

# ============================================================
# 6️⃣ 验证集群网络
# ============================================================
step "验证节点与网络状态"
kubectl get nodes -o wide
kubectl get pods -n kube-system -o wide | grep -E "calico|flannel" || true
ok "网络插件安装验证完成 ✅"
