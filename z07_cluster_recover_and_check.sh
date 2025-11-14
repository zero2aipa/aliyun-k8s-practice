#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 07_cluster_recover_and_check.sh
# 功能：
#   - 清理所有节点的 Kubernetes 状态（kubeadm reset）
#   - 检查基础服务（containerd/kubelet/chrony）
#   - Master 重新 init
#   - Worker 节点重新 join
# ============================================================

# ---------- 输出样式 ----------
COLOR_BLUE="\033[1;34m"; COLOR_GREEN="\033[1;32m"; COLOR_YELLOW="\033[1;33m"; COLOR_RESET="\033[0m"
step() { echo -e "${COLOR_BLUE}[STEP]${COLOR_RESET} $*"; }
ok()   { echo -e "${COLOR_GREEN}✅${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_YELLOW}⚠️${COLOR_RESET} $*"; }

# ---------- 加载全局配置 ----------
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${BASE_DIR}/00_cluster.env"

CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-${ALL_MASTERS[0]}}"
WORKER_IPS=()
declare -A _is_master=()
for ip in "${ALL_MASTERS[@]}"; do _is_master["$ip"]=1; done
for ip in "${ALL_NODES[@]}"; do [[ -z "${_is_master[$ip]:-}" ]] && WORKER_IPS+=("$ip"); done

CACHE_DIR="/opt/k8s-image-cache"

# ============================================================
# 1️⃣ 全节点集群清理
# ============================================================
step "开始集群清理（kubeadm reset + 残留目录）"

CLEAN_CMDS=$(cat <<'EOF'
set -e
systemctl stop kubelet containerd >/dev/null 2>&1 || true
kubeadm reset -f >/dev/null 2>&1 || true
rm -rf /etc/kubernetes /var/lib/etcd /var/lib/cni /etc/cni/net.d /root/.kube
rm -rf /opt/k8s-image-cache /opt/k8s-setup/phase*_done
systemctl restart containerd >/dev/null 2>&1 || true
EOF
)

for NODE in "${ALL_NODES[@]}"; do
  echo ">>> 清理节点 ${NODE}"
  if ! timeout 3 bash -c "echo > /dev/tcp/${NODE}/${SSH_PORT}" 2>/dev/null; then
    warn "节点 ${NODE} SSH 不可达，跳过"
    continue
  fi
  timeout 60s sshpass -p "${SSH_PASS}" ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=no "${SSH_USER}@${NODE}" "${CLEAN_CMDS}" >/dev/null 2>&1 || warn "节点 ${NODE} 清理失败"
done
ok "所有节点清理完成 ✅"

# ============================================================
# 2️⃣ 检查基础服务状态
# ============================================================
step "检查 containerd / kubelet / chrony 服务状态"
for NODE in "${ALL_NODES[@]}"; do
  echo ">>> 检查节点 ${NODE}"
  timeout 30s sshpass -p "${SSH_PASS}" ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=no "${SSH_USER}@${NODE}" \
    "systemctl is-active containerd kubelet chrony 2>/dev/null" || warn "节点 ${NODE} 服务异常"
done
ok "服务检查阶段完成"

# ============================================================
# 3️⃣ Master 重新 init
# ============================================================
step "在控制平面节点重新执行 kubeadm init"

INIT_ARGS=(
  "--apiserver-advertise-address=${CONTROL_PLANE_IP}"
  "--pod-network-cidr=${POD_CIDR}"
  "--image-repository=${PAUSE_IMAGE%/pause:*}"
  "--v=5"
)
[[ -n "${K8S_VERSION:-}" ]] && INIT_ARGS+=("--kubernetes-version=${K8S_VERSION}")

sshpass -p "${SSH_PASS}" ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=no "${SSH_USER}@${CONTROL_PLANE_IP}" \
  "kubeadm init ${INIT_ARGS[*]}" || warn "控制平面 init 失败"

sshpass -p "${SSH_PASS}" ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=no "${SSH_USER}@${CONTROL_PLANE_IP}" \
  "mkdir -p /root/.kube && cp -f /etc/kubernetes/admin.conf /root/.kube/config" >/dev/null 2>&1 || true
ok "Master 重新初始化完成"

# 生成新的 join.sh
step "生成新的 join 命令"
sshpass -p "${SSH_PASS}" ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=no "${SSH_USER}@${CONTROL_PLANE_IP}" \
  "kubeadm token create --print-join-command > /opt/k8s-image-cache/join.sh && chmod +x /opt/k8s-image-cache/join.sh"
ok "join 命令已更新"

# ============================================================
# 4️⃣ Worker 节点重新 join
# ============================================================
step "执行 Worker 节点重新 join"

for NODE in "${WORKER_IPS[@]}"; do
  echo ">>> 处理节点 ${NODE}"
  if ! timeout 3 bash -c "echo > /dev/tcp/${NODE}/${SSH_PORT}" 2>/dev/null; then
    warn "节点 ${NODE} SSH 不可达（跳过）"
    continue
  fi

  # 同步 join.sh
  sshpass -p "${SSH_PASS}" scp -P "${SSH_PORT}" -o StrictHostKeyChecking=no "${CONTROL_PLANE_IP}:${CACHE_DIR}/join.sh" \
    "${SSH_USER}@${NODE}:${CACHE_DIR}/join.sh" >/dev/null 2>&1 || warn "join.sh 分发失败"

  # 执行 join
  sshpass -p "${SSH_PASS}" ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=no "${SSH_USER}@${NODE}" \
    "bash ${CACHE_DIR}/join.sh" >/dev/null 2>&1 || warn "节点 ${NODE} join 失败"
done
ok "Worker 节点重新 join 完成"

# ============================================================
# 5️⃣ 集群验证
# ============================================================
step "验证集群状态"
sleep 10
sshpass -p "${SSH_PASS}" ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=no "${SSH_USER}@${CONTROL_PLANE_IP}" \
  "kubectl get nodes -o wide && kubectl get pods -A -o wide | grep -E 'calico|flannel'" || warn "kubectl 状态验证失败"
ok "集群恢复完成 🎉"
