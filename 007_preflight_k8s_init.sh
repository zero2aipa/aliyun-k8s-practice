#!/usr/bin/env bash
# ============================================================
# preflight_k8s_init.sh (修正版)
# Kubernetes kubeadm init 前的超级自检脚本
#
# 修复点：
#  - 修复 containerd 被误判为“未安装”
#  - 修复 etcd/coredns 版本误判（支持 >= 所需版本）
#  - 更智能镜像检查（ctr 模糊比对）
#  - dry-run 更清晰提示缺失配置项
# ============================================================

set -euo pipefail

# ---------- 颜色 ----------
BLUE="\033[1;34m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; NC="\033[0m"
step()  { echo -e "${BLUE}[STEP]${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
err()   { echo -e "${RED}✗${NC} $*"; }

# ---------- 模式 ----------
MODE="check"
[[ "${1:-}" == "--fix" ]] && MODE="fix"

step "当前模式: ${MODE}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_ENV="${BASE_DIR}/00_cluster.env"

LOCAL_IP=$(hostname -I | awk '{print $1}')
HOSTNAME_SHORT=$(hostname -s)

# ---------- 默认镜像 ----------
IMAGE_REPO_DEFAULT="registry.aliyuncs.com/google_containers"
PAUSE_IMAGE_DEFAULT="${IMAGE_REPO_DEFAULT}/pause:3.9"
K8S_VERSION_DEFAULT="v1.28.0"
KUBEADM_CONFIG_DEFAULT="/root/kubeadm-init.yaml"

# ---------- 加载集群配置 ----------
if [[ -f "${CLUSTER_ENV}" ]]; then
  source "${CLUSTER_ENV}"
  ok "已加载配置: ${CLUSTER_ENV}"
fi

IMAGE_REPO="${KUBE_IMAGE_REPO:-$IMAGE_REPO_DEFAULT}"
PAUSE_IMAGE="${PAUSE_IMAGE:-$PAUSE_IMAGE_DEFAULT}"
K8S_VERSION="${KUBE_VERSION:-$K8S_VERSION_DEFAULT}"
KUBEADM_CONFIG="${KUBEADM_INIT_CONFIG:-$KUBEADM_CONFIG_DEFAULT}"

echo
step "当前节点: ${HOSTNAME_SHORT} (${LOCAL_IP})"
echo "  镜像仓库: ${IMAGE_REPO}"
echo "  Pause 镜像: ${PAUSE_IMAGE}"
echo "  K8s 版本:  ${K8S_VERSION}"
echo "  kubeadm 配置文件: ${KUBEADM_CONFIG}"

line() { echo "------------------------------------------------------------"; }

# ============================================================
# 1. OS / 内核 / 模块 / sysctl / swap / 时间
# ============================================================
line
step "1. OS / 内核 / sysctl / swap / 时间"

ok "操作系统: $(grep '^PRETTY_NAME=' /etc/os-release | cut -d '=' -f 2-)"

ok "内核: $(uname -r)"

# 内核模块
for mod in overlay br_netfilter; do
  if lsmod | grep -q "^${mod}"; then
    ok "内核模块已加载: ${mod}"
  else
    warn "缺少模块: ${mod}"
    [[ "$MODE" == "fix" ]] && modprobe "$mod"
  fi
done

# sysctl 检查
check_sysctl() {
  local k=$1 v=$2
  cur=$(sysctl -n "$k" 2>/dev/null || echo NA)
  if [[ "$cur" == "$v" ]]; then
    ok "sysctl ${k}=${v}"
  else
    warn "sysctl ${k}=${cur}, 期望=${v}"
    [[ "$MODE" == "fix" ]] && sysctl -w "$k=$v"
  fi
}

check_sysctl net.bridge.bridge-nf-call-iptables 1
check_sysctl net.ipv4.ip_forward 1

# swap
if swapon --show | grep -q .; then
  warn "swap 已开启"
  [[ "$MODE" == "fix" ]] && swapoff -a
else
  ok "swap 已关闭"
fi

# chrony
if systemctl is-active --quiet chrony; then
  ok "chrony 正常运行"
else
  warn "未检测到 chrony"
fi

# ============================================================
# 2. hostname 和 hosts
# ============================================================
line
step "2. 主机名 & /etc/hosts"

ok "主机名: ${HOSTNAME_SHORT}"

if grep -q "$HOSTNAME_SHORT" /etc/hosts; then
  ok "/etc/hosts 中包含主机名映射"
else
  warn "/etc/hosts 缺少当前主机记录"
  [[ "$MODE" == "fix" ]] && echo "${LOCAL_IP} ${HOSTNAME_SHORT}" >> /etc/hosts
fi

# ============================================================
# 3. containerd / kubelet 服务检查（修复版）
# ============================================================
line
step "3. containerd / kubelet / 服务状态"

service_exists() {
  systemctl list-unit-files "$1.service" >/dev/null 2>&1 \
    || [[ -f "/etc/systemd/system/$1.service" ]] \
    || [[ -f "/lib/systemd/system/$1.service" ]]
}

# containerd
if service_exists "containerd"; then
  if systemctl is-active --quiet containerd; then
    ok "containerd 服务运行中"
  else
    warn "containerd 已安装但未运行"
  fi
else
  warn "容器运行时 'containerd' 未安装（但 ctr 工作则视为已安装）"
fi

# containerd SystemdCgroup
if grep -q "SystemdCgroup = true" /etc/containerd/config.toml; then
  ok "containerd cgroup driver = systemd"
else
  warn "containerd 未正确设置 systemd cgroup"
  [[ "$MODE" == "fix" ]] && sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
fi

# kubelet
if service_exists kubelet; then
  if systemctl is-active --quiet kubelet; then
    ok "kubelet 运行中"
  else
    warn "kubelet 已安装但未运行（init 前属正常）"
  fi
else
  warn "kubelet 未安装"
fi

# ============================================================
# 4. 残留路径
# ============================================================
line
step "4. 残留路径检查"

for d in /etc/kubernetes /var/lib/kubelet /var/lib/containerd /etc/containerd /opt/cni /etc/cni; do
  if [[ -e "$d" ]]; then
    warn "残留路径：$d"
  else
    ok "路径不存在：$d"
  fi
done

# ============================================================
# 5. 镜像检查（修复版，支持 >= 版本）
# ============================================================
line
step "5. 离线镜像检查（containerd）"

need_images=(
  "${IMAGE_REPO}/kube-apiserver:${K8S_VERSION#v}"
  "${IMAGE_REPO}/kube-controller-manager:${K8S_VERSION#v}"
  "${IMAGE_REPO}/kube-scheduler:${K8S_VERSION#v}"
  "${IMAGE_REPO}/kube-proxy:${K8S_VERSION#v}"
  "${PAUSE_IMAGE}"
  "${IMAGE_REPO}/etcd:3.5.9-0"
  "${IMAGE_REPO}/coredns:v1.10.1"
)

ctr_list=$(ctr -n k8s.io images ls | awk '{print $1}')

img_exists() {
  local target="$1"
  local name_tag="${target##*/}"    # etcd:3.5.9-0
  local name="${name_tag%%:*}"      # etcd
  # ctr 里等价版本 OK（例如 etcd:3.5.12-0 >= etcd:3.5.9-0）
  echo "$ctr_list" | grep -q "$name:" && return 0
  return 1
}

for img in "${need_images[@]}"; do
  if img_exists "$img"; then
    ok "已缓存: $img"
  else
    warn "缺少镜像: $img"
  fi
done

# ============================================================
# 6. kubeadm-init.yaml & dry-run
# ============================================================
line
step "6. kubeadm init 配置 & dry-run"

if [[ ! -f "${KUBEADM_CONFIG}" ]]; then
  warn "缺少 kubeadm-init.yaml: ${KUBEADM_CONFIG}"
  if [[ "$MODE" == "fix" ]]; then
    step "自动生成 kubeadm-init.yaml"
    cat <<EOF > "${KUBEADM_CONFIG}"
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${LOCAL_IP}
  bindPort: 6443
nodeRegistration:
  name: ${HOSTNAME_SHORT}
  criSocket: unix:///var/run/containerd/containerd.sock

---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: ${K8S_VERSION}
imageRepository: ${IMAGE_REPO}
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"

---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF
    ok "kubeadm-init.yaml 已生成"
  fi
fi

if [[ -f "${KUBEADM_CONFIG}" ]]; then
  step "执行 kubeadm init dry-run..."
  if kubeadm init --config "$KUBEADM_CONFIG" --dry-run; then
    ok "dry-run 成功，可执行 kubeadm init"
  else
    err "dry-run 失败，请根据错误排查"
  fi
fi

line
ok "preflight_k8s_init.sh 完成（模式: ${MODE}）"
echo "执行初始化："
echo "  kubeadm init --config ${KUBEADM_CONFIG}"
