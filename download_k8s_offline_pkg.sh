#!/usr/bin/env bash
set -euo pipefail

# ========== 可配置变量 ==========
K8S_VERSION="1.30.4-1.1"           # 目标 Kubernetes 版本
#K8S_VERSION="1.30.14-1.1"           # 目标 Kubernetes 版本

PKG_DIR="/opt/k8s-pkg-cache"        # 离线包保存路径
KEYRING="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
SOURCE_LIST="/etc/apt/sources.list.d/kubernetes.list"

# 提取主版本号（用于 cri-tools & crictl）
K8S_MINOR=$(echo "$K8S_VERSION" | cut -d'.' -f1,2)
CRICTL_VERSION="v${K8S_MINOR}.0"

# ========== 输出样式 ==========
info()  { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[1;32m✅ $*\033[0m"; }
warn()  { echo -e "\033[1;33m⚠️  $*\033[0m"; }
err()   { echo -e "\033[1;31m❌ $*\033[0m"; }

# ========== 1. 环境准备 ==========
mkdir -p "${PKG_DIR}" /etc/apt/keyrings

info "导入 Kubernetes GPG key..."
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor --yes -o "${KEYRING}"

ok "Key 导入完成：${KEYRING}"

# ========== 2. 配置 APT 源 ==========
info "配置 APT 源..."
cat > "${SOURCE_LIST}" <<EOF
deb [signed-by=${KEYRING}] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /
EOF

ok "APT 源已写入：${SOURCE_LIST}"

# ========== 3. 更新索引 ==========
info "执行 apt-get update..."
apt-get update -y >/dev/null || (err "APT 更新失败"; exit 1)
ok "APT 索引更新完成"

# ========== 4. 检查可用版本 ==========
info "检查仓库中可用的版本..."
apt-cache madison kubelet kubeadm kubectl cri-tools | grep "${K8S_VERSION}" || \
  warn "仓库中未找到 ${K8S_VERSION}，将尝试下载相近版本"


# ========== 5. 下载 Kubernetes 核心组件 ==========
info "开始下载 Kubernetes 离线包到 ${PKG_DIR}"
cd "${PKG_DIR}"

# 检查 cri-tools 是否存在于 apt 仓库
if apt-cache madison cri-tools | grep -q "${K8S_MINOR}"; then
  info "检测到 cri-tools 存在于 APT 仓库，将一并下载..."
  apt-get install --download-only -y \
    kubelet="${K8S_VERSION}" \
    kubeadm="${K8S_VERSION}" \
    kubectl="${K8S_VERSION}" \
    cri-tools | tee "${PKG_DIR}/download.log" || warn "部分包未找到或版本不匹配"
  ok "Kubernetes 离线包下载完成"
else
  warn "APT 源中未发现 cri-tools（${K8S_MINOR}），将跳过此包"
  apt-get install --download-only -y \
    kubelet="${K8S_VERSION}" \
    kubeadm="${K8S_VERSION}" \
    kubectl="${K8S_VERSION}" | tee "${PKG_DIR}/download.log" || warn "部分包未找到或版本不匹配"
  ok "Kubernetes 离线包下载完成（不含 cri-tools）"
fi

# ========== 6. 下载 crictl（仅当 cri-tools 缺失时） ==========
if ! ls "${PKG_DIR}" | grep -q "cri-tools"; then
  info "下载 crictl ${CRICTL_VERSION} ..."
  CRICTL_FILE="crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
  CRICTL_URL="https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/${CRICTL_FILE}"

  if curl -fsSL -o "${PKG_DIR}/${CRICTL_FILE}" "${CRICTL_URL}"; then
    ok "crictl 已下载：${PKG_DIR}/${CRICTL_FILE}"
  else
    warn "crictl ${CRICTL_VERSION} 下载失败，请手动确认版本"
  fi
else
  ok "APT 已包含 cri-tools，无需单独下载 crictl"
fi



# ========== 7. 结果总结 ==========
info "离线包下载完成，文件保存在：/var/cache/apt/archives ${PKG_DIR}"
mv /var/cache/apt/archives/*deb "${PKG_DIR}"
ls -lh "${PKG_DIR}" | grep -E 'deb|tar.gz' || true


echo -e "\n✅ 离线包准备完成，可以通过以下命令分发到目标节点："
echo "   scp ${PKG_DIR}/*.deb root@<node_ip>:/opt/k8s-pkg-cache/"
echo "   scp ${PKG_DIR}/crictl-*.tar.gz root@<node_ip>:/opt/k8s-pkg-cache/"
