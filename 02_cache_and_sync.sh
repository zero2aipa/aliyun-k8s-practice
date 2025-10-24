#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/00_cluster.env"

# ---------- 输出样式 ----------
bold()  { echo -e "\033[1m$*\033[0m"; }
ok()    { echo -e "✅ $*"; }
warn()  { echo -e "⚠️  $*"; }
err()   { echo -e "❌ $*" >&2; }
step()  { echo -e "\n\033[1;34m[STEP]\033[0m $*"; }

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# ---------- 准备缓存目录 ----------
mkdir -p "${PKG_CACHE_DIR}"
chown _apt:root "${PKG_CACHE_DIR}" 2>/dev/null || true
chmod 755 "${PKG_CACHE_DIR}" || true

BASE_PKGS=(chrony containerd cri-tools)
K8S_PKGS=(kubelet kubeadm kubectl)
RUNTIME_DEPS=(apt-transport-https ca-certificates curl gnupg lsb-release)
ALL_PKGS=("${BASE_PKGS[@]}" "${K8S_PKGS[@]}" "${RUNTIME_DEPS[@]}")

# ---------- 设置 APT 源 ----------
step "准备 Kubernetes APT 源（阿里云镜像）"
mkdir -p /etc/apt/keyrings
curl -fsSL "${ALIYUN_K8S_APT}/doc/apt-key.gpg" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-archive-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] ${ALIYUN_K8S_APT}/ kubernetes-xenial main" >/etc/apt/sources.list.d/kubernetes.list
apt-get update -y >/dev/null
ok "K8s APT 源配置完成（Aliyun 镜像）"

# ---------- 缓存包 ----------
step "下载并缓存所需 .deb 包到 ${PKG_CACHE_DIR}"
pushd "${PKG_CACHE_DIR}" >/dev/null

need_download() { [[ -z "$(ls -1 ${1}* 2>/dev/null || true)" ]]; }

for pkg in "${ALL_PKGS[@]}"; do
  if [[ "${pkg}" =~ ^(kubelet|kubeadm|kubectl)$ ]] && [[ -n "${K8S_VERSION}" ]]; then
    if need_download "${pkg}_${K8S_VERSION}"; then
      apt-get download "${pkg}=${K8S_VERSION}" >/dev/null 2>&1 || warn "下载 ${pkg}=${K8S_VERSION} 失败（将在线安装）"
    else
      ok "${pkg}=${K8S_VERSION} 已存在缓存"
    fi
  else
    if need_download "${pkg}_"; then
      apt-get download "${pkg}" >/dev/null 2>&1 || warn "下载 ${pkg} 失败（将在线安装）"
    else
      ok "${pkg} 已存在缓存"
    fi
  fi
done

# ---------- crictl 回退 ----------
if [[ ! -f "crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" ]]; then
  curl -LO "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" >/dev/null 2>&1 \
    && ok "crictl 回退包下载完成" \
    || warn "下载 crictl 回退包失败"
fi
popd >/dev/null
ok "所需包已缓存（尽可能离线可用）"

# ---------- 分发与远程安装 ----------
step "将缓存目录分发到其他节点并执行本地优先安装"

for NODE in "${ALL_NODES[@]}"; do
  bold ">>> 处理节点 ${NODE}"

  # 跳过本机
  if [[ "$NODE" == "$(hostname -I | awk '{print $1}')" ]]; then
    ok "跳过本机节点 ${NODE}"
    continue
  fi

  # (1) 分发缓存目录（带超时与错误跳过）
  if timeout 20s sshpass -p "${SSH_PASS}" scp -P "${SSH_PORT}" -o StrictHostKeyChecking=no -r "${PKG_CACHE_DIR}/" "${SSH_USER}@${NODE}:${PKG_CACHE_DIR}/" >/dev/null 2>&1; then
    ok "SCP 到 ${NODE} 成功"
  else
    warn "SCP 到 ${NODE} 失败或超时（跳过该节点）"
    continue
  fi

  # (2) 远程安装（超时 + 错误保护）
  if timeout 120s sshpass -p "${SSH_PASS}" ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=no "${SSH_USER}@${NODE}" "bash -s" <<"EOF" >/dev/null 2>&1; then
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
PKG_CACHE_DIR="/opt/k8s-pkg-cache"
mkdir -p "${PKG_CACHE_DIR}"

install_from_cache_or_apt() {
  local pattern="$1"
  local found=0
  for f in "${PKG_CACHE_DIR}"/${pattern}*.deb; do
    if [[ -f "$f" ]]; then
      dpkg -i "$f" >/dev/null 2>&1 || apt-get install -f -y >/dev/null 2>&1
      found=1
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install "${APT_FLAGS[@]}" "$pattern" >/dev/null 2>&1 || true
  fi
}

apt-get update -y >/dev/null 2>&1 || true
apt-get install "${APT_FLAGS[@]}" ca-certificates curl gnupg lsb-release apt-transport-https >/dev/null 2>&1 || true

for p in chrony containerd cri-tools kubelet kubeadm kubectl; do
  install_from_cache_or_apt "$p"
done

if ! command -v crictl >/dev/null 2>&1 && [[ -f "${PKG_CACHE_DIR}/crictl-"*"-linux-amd64.tar.gz" ]]; then
  tar -zxvf "${PKG_CACHE_DIR}/crictl-"*"-linux-amd64.tar.gz" -C /usr/local/bin >/dev/null 2>&1
fi
EOF
    ok "节点 ${NODE} 已完成本地优先安装"
  else
    warn "远程安装在节点 ${NODE} 失败或超时（跳过）"
  fi
done

ok "✅ 所有节点缓存分发 + 本地优先安装流程完成"
