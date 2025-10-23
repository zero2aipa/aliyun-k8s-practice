#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# kubeadm_cluster_init.sh
# 控制平面节点(cp-1) 初始化 K8S 集群 + 分发镜像到其他节点
# ============================================================

# === 1️⃣ 基本配置 ===
CONTROL_PLANE_IP="10.0.1.1"
WORKER_IPS=("10.0.2.1" "10.0.2.2")
SSH_USER="root"
SSH_PASS="YourRootPassword"

POD_CIDR="192.168.0.0/16"
K8S_VERSION="1.30.4-00"      # 指定稳定版本
IMAGE_REPO="registry.aliyuncs.com/google_containers"
PAUSE_IMG="${IMAGE_REPO}/pause:3.9"

IMAGE_LIST=(
  "kube-apiserver:v1.30.4"
  "kube-controller-manager:v1.30.4"
  "kube-scheduler:v1.30.4"
  "kube-proxy:v1.30.4"
  "etcd:3.5.12-0"
  "coredns:v1.11.1"
  "pause:3.9"
)

COLOR_BLUE="\033[1;34m"; COLOR_GREEN="\033[1;32m"; COLOR_YELLOW="\033[1;33m"; COLOR_RESET="\033[0m"
step() { echo -e "${COLOR_BLUE}[STEP]${COLOR_RESET} $*"; }
ok()   { echo -e "${COLOR_GREEN}✅${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_YELLOW}⚠️${COLOR_RESET} $*"; }

# === 2️⃣ 初始化 containerd / kubeadm 参数修复 ===
step "修复 containerd 配置为 systemd 驱动 + 国内 pause 镜像"
mkdir -p /etc/containerd
if [[ ! -f /etc/containerd/config.toml ]]; then
  containerd config default >/etc/containerd/config.toml
fi
sed -i 's#SystemdCgroup = false#SystemdCgroup = true#' /etc/containerd/config.toml
sed -i "s#sandbox_image = .*#sandbox_image = \"${PAUSE_IMG}\"#" /etc/containerd/config.toml
systemctl daemon-reexec && systemctl restart containerd && systemctl enable containerd
ok "containerd 配置修复完成"

# === 3️⃣ 拉取并缓存镜像 ===
step "拉取 Kubernetes v${K8S_VERSION} 镜像到本地"
mkdir -p /opt/k8s-image-cache
cd /opt/k8s-image-cache
for img in "${IMAGE_LIST[@]}"; do
  full="${IMAGE_REPO}/${img}"
  echo ">>> 拉取 ${full}"
  crictl pull "${full}" || (echo "尝试 ctr 拉取 ${full}" && ctr -n k8s.io images pull "${full}")
  imgfile=$(echo "${img}" | tr '/:' '_')
  echo ">>> 保存 ${imgfile}.tar"
  ctr -n k8s.io images export "${imgfile}.tar" "${IMAGE_REPO}/${img}" || true
done
ok "镜像拉取并缓存完成"

# === 4️⃣ 初始化控制平面 ===
step "执行 kubeadm init (版本 ${K8S_VERSION})"
kubeadm reset -f || true
rm -rf /etc/kubernetes /var/lib/etcd /var/lib/cni /etc/cni/net.d || true

kubeadm init \
  --apiserver-advertise-address="${CONTROL_PLANE_IP}" \
  --pod-network-cidr="${POD_CIDR}" \
  --image-repository="${IMAGE_REPO}" \
  --kubernetes-version="${K8S_VERSION}" \
  --v=5

ok "kubeadm init 完成"

# === 5️⃣ 配置 kubectl 环境 ===
mkdir -p $HOME/.kube
cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config
ok "kubectl 已配置：$(kubectl version --short | head -n 1)"

# === 6️⃣ 生成 join 命令 ===
JOIN_CMD=$(kubeadm token create --print-join-command)
echo "${JOIN_CMD}" >/opt/k8s-image-cache/join.sh
chmod +x /opt/k8s-image-cache/join.sh
ok "Join 命令已保存到 /opt/k8s-image-cache/join.sh"

# === 7️⃣ 分发镜像到其他节点并离线加载 ===
step "分发镜像包与 join 命令到 worker 节点"
for NODE in "${WORKER_IPS[@]}"; do
  echo ">>> 分发到 ${NODE}"
  sshpass -p "${SSH_PASS}" scp -o StrictHostKeyChecking=no -r /opt/k8s-image-cache "${SSH_USER}@${NODE}:/opt/" >/dev/null
  sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no "${SSH_USER}@${NODE}" bash -s <<'EOF'
set -e
cd /opt/k8s-image-cache
for f in *.tar; do
  echo ">>> 加载镜像 \$f"
  ctr -n k8s.io images import "\$f" >/dev/null || echo "跳过加载 \$f"
done
chmod +x /opt/k8s-image-cache/join.sh
/opt/k8s-image-cache/join.sh || true
EOF
done
ok "镜像分发与离线加载完成"

# === 8️⃣ 验证节点状态 ===
step "验证节点状态"
kubectl get nodes -o wide || warn "kubectl 连接失败，稍等 kubelet 注册"
ok "集群初始化流程全部完成 🎉"
