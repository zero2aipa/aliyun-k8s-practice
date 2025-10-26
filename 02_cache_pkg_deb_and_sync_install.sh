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
mkdir -p /etc/apt/keyrings

# ---------- 准备缓存目录 ----------
mkdir -p "${PKG_CACHE_DIR}"
chown _apt:root "${PKG_CACHE_DIR}" 2>/dev/null || true
chmod 755 "${PKG_CACHE_DIR}" || true

BASE_PKGS=(chrony containerd cri-tools)
K8S_PKGS=(kubelet kubeadm kubectl)
RUNTIME_DEPS=(apt-transport-https ca-certificates curl gnupg lsb-release)
ALL_PKGS=("${BASE_PKGS[@]}" "${K8S_PKGS[@]}" "${RUNTIME_DEPS[@]}")

ALIYUN_APT="${ALIYUN_K8S_APT:-https://mirrors.aliyun.com/kubernetes/apt}"
OFFICIAL_APT="https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION%%.*}/deb"
KEYRING="/etc/apt/keyrings/kubernetes-archive-keyring.gpg"

# ---------- 设置阿里云源 ----------
use_aliyun_source() {
  step "配置阿里云 Kubernetes APT 源"
  curl -fsSL "${ALIYUN_APT}/doc/apt-key.gpg" | gpg --dearmor -o "${KEYRING}" 2>/dev/null
  echo "deb [signed-by=${KEYRING}] ${ALIYUN_APT}/ kubernetes-xenial main" \
    >/etc/apt/sources.list.d/kubernetes.list
  apt-get update -y >/dev/null
  ok "K8s APT 源已设置为 Aliyun 镜像"
}

# ---------- 设置官方 pkgs.k8s.io 源 ----------
use_official_source() {
  step "切换到官方 pkgs.k8s.io 源"
  mkdir -p /etc/apt/keyrings

  # 选择对应版本
  OFFICIAL_KEY_URL="https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key"
  OFFICIAL_REPO="deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /"

  # 强制覆盖旧 keyring，不再交互
  curl -fsSL "${OFFICIAL_KEY_URL}" | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-archive-keyring.gpg

  # 写入源
  echo "${OFFICIAL_REPO}" > /etc/apt/sources.list.d/kubernetes.list

  # 更新索引
  apt-get update -y >/dev/null || warn "官方源更新失败"
  ok "✅ 已切换至官方源并刷新索引"
}


# ---------- 下载所需包 ----------
download_pkgs() {
  local success=0
  pushd "${PKG_CACHE_DIR}" >/dev/null
  need_download() { [[ -z "$(ls -1 ${1}* 2>/dev/null || true)" ]]; }

  for pkg in "${ALL_PKGS[@]}"; do
    if [[ "${pkg}" =~ ^(kubelet|kubeadm|kubectl)$ ]] && [[ -n "${K8S_VERSION}" ]]; then
      if need_download "${pkg}_${K8S_VERSION}"; then
        if apt-get download "${pkg}=${K8S_VERSION}" >/dev/null 2>&1; then
          ok "${pkg}=${K8S_VERSION} 下载成功"
          success=$((success+1))
        else
          warn "${pkg}=${K8S_VERSION} 下载失败"
        fi
      else
        ok "${pkg}=${K8S_VERSION} 已存在缓存"
      fi
    else
      if need_download "${pkg}_"; then
        apt-get download "${pkg}" >/dev/null 2>&1 && ok "${pkg} 下载成功" || warn "${pkg} 下载失败"
      else
        ok "${pkg} 已存在缓存"
      fi
    fi
  done

  popd >/dev/null
  return $success
}

# ---------- 主流程 ----------
step "尝试使用阿里云源下载 K8s 组件"
use_aliyun_source
if ! download_pkgs || [[ $(ls -1 ${PKG_CACHE_DIR}/kubelet_* 2>/dev/null | wc -l) -eq 0 ]]; then
  warn "阿里云源下载 kubelet/kubeadm/kubectl 失败，自动切换到官方源重试"
  use_official_source
  download_pkgs || err "❌ 官方源下载仍失败，请检查网络或版本号。"
else
  ok "✅ 已成功从阿里云源下载所有包"
fi

# ---------- crictl 回退 ----------
step "检查 crictl 回退包"
pushd "${PKG_CACHE_DIR}" >/dev/null
if [[ ! -f "crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" ]]; then
  curl -LO "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" >/dev/null 2>&1 \
    && ok "crictl 回退包下载完成" \
    || warn "下载 crictl 回退包失败"
else
  ok "crictl 回退包已存在缓存"
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

  # 同步缓存目录
  if timeout 60s sshpass -p "${SSH_PASS}" scp -P "${SSH_PORT}" -o StrictHostKeyChecking=no -r "${PKG_CACHE_DIR}" "${SSH_USER}@${NODE}:/opt" >/dev/null 2>&1; then
      ok "✅ 已同步缓存到 ${NODE}"
  else
      warn "⚠️  同步到 ${NODE} 失败（跳过）"
      continue
  fi

  # 远程执行安装逻辑
  # 远程执行安装逻辑
  timeout 180s sshpass -p "${SSH_PASS}" ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=no "${SSH_USER}@${NODE}" bash -s <<EOF || warn "远程安装失败"
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
PKG_CACHE_DIR="/opt/k8s-pkg-cache"

install_from_cache_or_apt() {
  local pattern="$1"
  local found=0
  for f in "${PKG_CACHE_DIR}"/${pattern}*.deb; do
    if [[ -f "$f" ]]; then
      echo "📦 本地安装: $f"
      dpkg -i "$f" || apt-get install -f -y
      found=1
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    echo "🌐 网络安装: $pattern"
    apt-get update -y || true
    apt-get install "\$pattern" -y || true
  fi
}

for p in chrony containerd cri-tools kubelet kubeadm kubectl; do
  install_from_cache_or_apt "\$p"
done

echo "✅ 节点安装完成: \$(hostname)"
echo "    节点安装dpkg -l情况如下："
dpkg -l | grep -E "chrony|containerd|cri-tools|kubelet|kubeadm|kubectl"


EOF


  ok "节点 ${NODE} 已完成本地优先安装"
done

ok "✅ 所有节点缓存分发 + 本地优先安装流程完成"
