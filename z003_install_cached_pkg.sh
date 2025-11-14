#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# 021_install_cached_pkg.sh
# 功能：在本地节点准备并分发K8s运行时与基础包，远程离线安装
# 支持：
#   - 本地离线缓存目录 /opt/k8s-pkg-cache-full
#   - 本地和远端均可重复执行，无需联网
#   - 按下载时间(ctime)顺序补齐依赖
# ============================================================

# ---------- 彩色输出 ----------
bold()  { echo -e "\033[1m$*\033[0m"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()   { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
log()   { echo -e "\033[1;34m[PKG]\033[0m $*"; }

# ---------- 环境配置 ----------
PKG_CACHE_DIR="/opt/k8s-pkg-cache-full"
TMP_INSTALL_SH="/tmp/install_k8s_pkgs.sh"
mkdir -p "$PKG_CACHE_DIR"
export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# ---------- 集群节点 ----------
ALL_NODES=("172.18.208.11" "172.18.208.12" "172.18.208.13")
LOCAL_IP=$(hostname -I | awk '{print $1}')

# ============================================================
# 生成远端安装脚本
# ============================================================
cat > "$TMP_INSTALL_SH" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
PKG_CACHE_DIR="/opt/k8s-pkg-cache-full"
log() { echo -e "\033[1;34m[PKG]\033[0m $*"; }

sync_new_debs_to_cache() {
  find /var/cache/apt/archives -maxdepth 1 -type f -name "*.deb" -exec cp -u {} "$PKG_CACHE_DIR/" \; 2>/dev/null || true
}

install_pkg_with_cache() {
  local pkg="$1"
  local deb_file
  deb_file=$(ls "$PKG_CACHE_DIR"/${pkg}_*.deb 2>/dev/null | head -n1 || true)

  if [[ -n "$deb_file" ]]; then
    log "📦 本地安装: $(basename "$deb_file")"
    dpkg -i "$deb_file" >/dev/null 2>&1 || apt-get install "${APT_FLAGS[@]}" -f -y >/dev/null 2>&1
  else
    log "🌐 无缓存包，尝试联网安装: $pkg"
    apt-get update -y || true
    apt-get install -y --download-only "$pkg" || true
    sync_new_debs_to_cache
    apt-get install -y "$pkg" || true
    sync_new_debs_to_cache
  fi
}

# ---------- 定义分层 ----------
SYS_PKGS=(bridge-utils ipset libseccomp2 sshpass bash-completion net-tools)
RUNTIME_PKGS=(runc containerd)
NET_PKGS=(conntrack ebtables kubernetes-cni socat)
K8S_PKGS=(chrony cri-tools kubelet kubeadm kubectl)
OTHER_PKGS=(tzdata locales ca-certificates)

# ---------- 逐层安装 ----------
for p in "${SYS_PKGS[@]}"; do install_pkg_with_cache "$p"; done
for p in "${RUNTIME_PKGS[@]}"; do install_pkg_with_cache "$p"; done
for p in "${NET_PKGS[@]}"; do install_pkg_with_cache "$p"; done
for p in "${K8S_PKGS[@]}"; do install_pkg_with_cache "$p"; done
for p in "${OTHER_PKGS[@]}"; do install_pkg_with_cache "$p"; done

# ---------- 按创建时间顺序重放 ----------
install_all_cached_pkgs_by_ctime() {
  log "🕒 按下载时间顺序安装所有缓存包"
  local tmpfile
  tmpfile=$(mktemp)
  find "$PKG_CACHE_DIR" -maxdepth 1 -type f -name "*.deb" -printf '%W %p\n' 2>/dev/null | sort -n > "$tmpfile" || \
  find "$PKG_CACHE_DIR" -maxdepth 1 -type f -name "*.deb" -printf '%T@ %p\n' | sort -n > "$tmpfile"

  while read -r _time pkg; do
    [[ -n "$pkg" ]] || continue
    log "📦 按顺序安装: $(basename "$pkg")"
    dpkg -i "$pkg" >/dev/null 2>&1 || apt-get install -f -y >/dev/null 2>&1
  done < "$tmpfile"

  rm -f "$tmpfile"
}

install_all_cached_pkgs_by_ctime

# ---------- 收尾 ----------
log "🔍 二次检查并补齐依赖"
apt-get install -f -y >/dev/null 2>&1 || true
sync_new_debs_to_cache

log "✅ $(hostname) 所有包安装完成"
dpkg -l | grep -E "chrony|containerd|cri-tools|kubelet|kubeadm|kubectl|runc|conntrack|socat|ebtables|kubernetes-cni|ipset|bridge-utils|sshpass|bash-completion|libseccomp2|net-tools"
EOS

chmod +x "$TMP_INSTALL_SH"
ok "已生成安装脚本 $TMP_INSTALL_SH"

# ============================================================
# 分发缓存目录和脚本
# ============================================================
log "[STEP] 分发缓存目录与执行脚本"

for node in "${ALL_NODES[@]}"; do
  echo ">>> 处理节点 $node"

  if [[ "$node" == "$LOCAL_IP" ]]; then
    ok "检测到本机节点 ($node)，直接执行本地安装脚本"
    bash "$TMP_INSTALL_SH"
  else
    rsync -az --delete --info=progress2 "$PKG_CACHE_DIR"/ root@"$node":"$PKG_CACHE_DIR"/
    scp -q "$TMP_INSTALL_SH" root@"$node":/tmp/install_k8s_pkgs.sh
    ssh -o StrictHostKeyChecking=no root@"$node" "bash /tmp/install_k8s_pkgs.sh"
  fi
done

ok "🎉 全部节点安装流程完成"
