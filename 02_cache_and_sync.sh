#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/00_cluster.env"

bold()  { echo -e "\033[1m$*\033[0m"; }
ok()    { echo -e "✅ $*"; }
warn()  { echo -e "⚠️  $*"; }
err()   { echo -e "❌ $*" >&2; }
step()  { echo -e "\n\033[1;34m[STEP]\033[0m $*"; }

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

mkdir -p "${PKG_CACHE_DIR}"

# 要缓存/分发/安装的包清单（按需扩展）
BASE_PKGS=(chrony containerd cri-tools)
K8S_PKGS=(kubelet kubeadm kubectl)
RUNTIME_DEPS=(apt-transport-https ca-certificates curl gnupg lsb-release)

ALL_PKGS=("${BASE_PKGS[@]}" "${K8S_PKGS[@]}" "${RUNTIME_DEPS[@]}")

step "准备 Kubernetes APT 源（阿里云镜像）"
mkdir -p /etc/apt/keyrings
curl -fsSL "${ALIYUN_K8S_APT}/doc/apt-key.gpg" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-archive-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] ${ALIYUN_K8S_APT}/ kubernetes-xenial main" >/etc/apt/sources.list.d/kubernetes.list
apt-get update -y >/dev/null
ok "K8s APT 源配置完成（Aliyun 镜像）"

step "下载并缓存所需 .deb 包到 ${PKG_CACHE_DIR}"
pushd "${PKG_CACHE_DIR}" >/dev/null

# 小工具：存在即跳过下载
need_download() { [[ -z "$(ls -1 ${1}* 2>/dev/null || true)" ]]; }

for pkg in "${ALL_PKGS[@]}"; do
  if [[ "${pkg}" =~ ^(kubelet|kubeadm|kubectl)$ ]] && [[ -n "${K8S_VERSION}" ]]; then
    # 固定版本下载
    if need_download "${pkg}_${K8S_VERSION}"; then
      apt-get download "${pkg}=${K8S_VERSION}" || warn "下载 ${pkg}=${K8S_VERSION} 失败，稍后在线安装"
    else
      ok "${pkg}=${K8S_VERSION} 已存在缓存"
    fi
  else
    # 最新版下载
    if need_download "${pkg}_"; then
      apt-get download "${pkg}" || warn "下载 ${pkg} 失败，稍后在线安装"
    else
      ok "${pkg} 已存在缓存"
    fi
  fi
done

# crictl APT 有时抽风：准备 GitHub 回退包
if ! dpkg -s cri-tools >/dev/null 2>&1; then
  if [[ ! -f "crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" ]]; then
    curl -LO "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" || warn "下载 crictl 回退包失败"
  fi
fi
popd >/dev/null
ok "所需包已缓存（尽可能离线可用）"

step "将缓存目录分发到其他节点并执行本地优先安装"
for NODE in "${ALL_NODES[@]}"; do
  bold ">>> 处理节点 ${NODE}"
  # 1) 分发缓存
  sshpass -p "${SSH_PASS}" scp -P "${SSH_PORT}" -o StrictHostKeyChecking=no -r "${PKG_CACHE_DIR}" "${SSH_USER}@${NODE}:${PKG_CACHE_DIR}" >/dev/null || warn "SCP 到 ${NODE} 失败"
  # 2) 远程安装脚本：优先用本地缓存的 .deb 安装，缺失再 apt 在线补齐
  sshpass -p "${SSH_PASS}" ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=no "${SSH_USER}@${NODE}" "bash -s" <<"EOF" || warn "远程安装在该节点失败"
set -euo pipefail
source /etc/os-release || true
export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

PKG_CACHE_DIR="/opt/k8s-pkg-cache"
mkdir -p "${PKG_CACHE_DIR}"

install_from_cache_or_apt () {
  local pattern="$1"
  local found=0
  for f in "${PKG_CACHE_DIR}"/${pattern}*.deb; do
    if [[ -f "$f" ]]; then
      dpkg -i "$f" || apt-get install -f -y
      found=1
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    apt-get update -y >/dev/null || true
    apt-get install "${APT_FLAGS[@]}" "$(echo "$pattern" | sed 's/_.*//')" || true
  fi
}

# 先确保基础依赖
apt-get update -y >/dev/null || true
apt-get install "${APT_FLAGS[@]}" ca-certificates curl gnupg lsb-release apt-transport-https >/dev/null || true

# 安装 chrony / containerd / cri-tools / kubelet / kubeadm / kubectl
for p in chrony containerd cri-tools kubelet kubeadm kubectl ; do
  install_from_cache_or_apt "${p}"
done

# 如需本地放置 crictl 二进制的回退方案
if ! command -v crictl >/dev/null 2>&1 && [[ -f "${PKG_CACHE_DIR}/crictl-"*"-linux-amd64.tar.gz" ]]; then
  tar -zxvf "${PKG_CACHE_DIR}/crictl-"*"-linux-amd64.tar.gz" -C /usr/local/bin >/dev/null
fi
EOF
  ok "节点 ${NODE} 已执行本地优先安装"
done
ok "全部节点缓存分发 + 本地优先安装完成"
