#!/usr/bin/env bash
set -euo pipefail

# ==============================
# Kubernetes APT 源自动配置脚本
# - 自动导入 GPG Key（默认覆盖）
# - 自动写入源列表
# - 自动更新索引
# - 自动验证版本一致性
# ==============================

# --- 配置版本 ---
K8S_VERSION="1.30.4-1.1"
K8S_REPO_URL="https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION%%.*}/deb/"
KEY_FILE="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
LIST_FILE="/etc/apt/sources.list.d/kubernetes.list"

# --- 输出样式 ---
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()   { echo -e "\033[1;32m✅\033[0m $*"; }
warn() { echo -e "\033[1;33m⚠️ \033[0m $*"; }
err()  { echo -e "\033[1;31m❌\033[0m $*" >&2; }

# --- 检查 root 权限 ---
if [[ $EUID -ne 0 ]]; then
  err "请使用 sudo 运行此脚本"
  exit 1
fi

# --- 准备目录 ---
info "创建密钥目录：/etc/apt/keyrings"
mkdir -p /etc/apt/keyrings

# --- 导入 GPG Key（自动覆盖） ---
info "导入 Kubernetes 官方 GPG key ..."
curl -fsSL "${K8S_REPO_URL}/Release.key" | gpg --dearmor --yes -o "${KEY_FILE}" 2>/dev/null \
  && ok "GPG key 已写入 ${KEY_FILE}" \
  || err "导入 GPG key 失败，请检查网络"

# --- 写入源配置（覆盖旧配置） ---
info "写入 Kubernetes APT 源 ..."
echo "deb [signed-by=${KEY_FILE}] ${K8S_REPO_URL} /" > "${LIST_FILE}"
ok "APT 源已写入 ${LIST_FILE}"

# --- 更新索引 ---
info "执行 apt-get update ..."
if apt-get update -y >/dev/null 2>&1; then
  ok "APT 索引更新完成"
else
  warn "更新失败，请手动检查网络"
fi

# --- 检查候选版本 ---
info "检查可用的 Kubernetes 组件版本 ..."
apt-cache policy kubelet kubeadm kubectl cri-tools 2>/dev/null | grep Candidate || true

# --- 验证版本一致性 ---
info "验证目标版本一致性 ..."
MISSING=0
for pkg in kubelet kubeadm kubectl cri-tools; do
  ver=$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2}')
  if [[ -z "$ver" ]]; then
    warn "$pkg 未在仓库中找到"
    MISSING=1
  elif [[ "$ver" != "$K8S_VERSION" && "$pkg" != "cri-tools" ]]; then
    warn "$pkg 版本不匹配：$ver ≠ $K8S_VERSION"
    MISSING=1
  else
    ok "$pkg 版本匹配：$ver"
  fi
done

if [[ $MISSING -eq 0 ]]; then
  ok "✅ 所有组件版本一致，可以安全安装"
else
  warn "⚠️ 存在版本不匹配或缺失，请检查上方提示"
fi
