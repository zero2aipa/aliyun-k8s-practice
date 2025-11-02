#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  Kubernetes & Runtime 全量离线包下载脚本
#  适用于 Ubuntu 20.04 / 22.04，含 K8S、containerd、系统依赖
# ============================================================

# ========== 可配置变量 ==========
PKG_DIR="/opt/k8s-pkg-cache-full"
KEYRING="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
SOURCE_LIST="/etc/apt/sources.list.d/kubernetes.list"
K8S_VERSION="1.28.0-1.1"
K8S_MINOR=$(echo "$K8S_VERSION" | cut -d'.' -f1,2)
CRICTL_VERSION="v${K8S_MINOR}.0"

# ========== 输出样式 ==========
info()  { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[1;32m✅ $*\033[0m"; }
warn()  { echo -e "\033[1;33m⚠️  $*\033[0m"; }
err()   { echo -e "\033[1;31m❌ $*\033[0m"; }

mkdir -p "${PKG_DIR}" /etc/apt/keyrings

# ============================================================
# 0️⃣ 清理旧 Kubernetes APT 源，防止重复警告
# ============================================================
if grep -q "pkgs.k8s.io" /etc/apt/sources.list 2>/dev/null; then
  info "检测到旧的 Kubernetes APT 源，正在清理..."
  sed -i '/pkgs.k8s.io/d' /etc/apt/sources.list
  ok "旧 Kubernetes 源已清理"
fi
rm -f /etc/apt/sources.list.d/kubernetes.list 2>/dev/null || true

# ============================================================
# 1️⃣ 导入 Kubernetes GPG Key 并配置源
# ============================================================
info "导入 Kubernetes GPG key..."
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor --yes -o "${KEYRING}"
ok "Key 导入完成：${KEYRING}"

info "配置 APT 源..."
cat > "${SOURCE_LIST}" <<EOF
deb [signed-by=${KEYRING}] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /
EOF
ok "APT 源已写入：${SOURCE_LIST}"

# ============================================================
# 2️⃣ 更新索引
# ============================================================
info "执行 apt-get update..."
apt-get update -y
ok "APT 索引更新完成"

# ============================================================
# 3️⃣ 下载系统基础包（语言、工具、网络、系统组件）
# ============================================================
info "下载基础系统包（含中文、SSH、网络工具等）..."
BASE_PKGS=(
  locales language-pack-zh-hans tzdata sshpass curl ca-certificates gnupg
  lsb-release apt-transport-https net-tools iproute2 ipset bash-completion
  conntrack ebtables socat
)
apt-get install --reinstall --download-only -y "${BASE_PKGS[@]}"
ok "基础系统包下载完成"

# ============================================================
# 4️⃣ 下载 Containerd 运行时及依赖
# ============================================================
info "下载 containerd（及运行依赖 runc、bridge-utils、libseccomp2）..."
CONTAINERD_PKGS=(containerd runc bridge-utils libseccomp2)
apt-get install --reinstall --download-only -y "${CONTAINERD_PKGS[@]}"
ok "Containerd 运行时离线包下载完成"

# ============================================================
# 5️⃣ 下载 Kubernetes 核心组件
# ============================================================
info "下载 Kubernetes 核心组件 kubeadm / kubelet / kubectl / cri-tools ..."
apt-get install --reinstall --download-only -y \
  kubelet="${K8S_VERSION}" \
  kubeadm="${K8S_VERSION}" \
  kubectl="${K8S_VERSION}" \
  cri-tools \
  kubernetes-cni
ok "Kubernetes 核心包下载完成"

# ============================================================
# 6️⃣ 下载 crictl 工具包
# ============================================================
info "下载 crictl ${CRICTL_VERSION} ..."
CRICTL_FILE="crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
CRICTL_URL="https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/${CRICTL_FILE}"
curl -L -o "${PKG_DIR}/${CRICTL_FILE}" "${CRICTL_URL}"
ok "crictl 已下载：${PKG_DIR}/${CRICTL_FILE}"

# ============================================================
# 7️⃣ 汇总所有离线包
# ============================================================
info "整理下载的所有包..."
mv /var/cache/apt/archives/*.deb "${PKG_DIR}/" || true

cd "${PKG_DIR}"
COUNT=$(ls *.deb | wc -l)
echo "共有 ${COUNT} 个 DEB 包"
du -sh "${PKG_DIR}"

# ============================================================
# 8️⃣ 生成目标节点安装脚本
# ============================================================
cat > "${PKG_DIR}/install_all_local.sh" <<'EOSH'
#!/usr/bin/env bash
set -e
PKG_DIR="$(dirname "$0")"
echo "📦 正在离线安装全部依赖..."
dpkg -i ${PKG_DIR}/*.deb || apt-get install -f -y
echo "✅ 本地离线包全部安装完成"
EOSH
chmod +x "${PKG_DIR}/install_all_local.sh"

ok "install_all_local.sh 已生成"

# ============================================================
# 9️⃣ 总结输出
# ============================================================
ok "所有离线包已下载到 ${PKG_DIR}"
echo "➡ 可分发并在目标节点执行："
echo "   scp -r ${PKG_DIR} root@<node>:/opt/"
echo "   ssh root@<node> 'bash /opt/k8s-pkg-cache-full/install_all_local.sh'"
echo ""
ls -lh "${PKG_DIR}" | grep -E 'deb|tar.gz' || true

