#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/00_cluster.env"

bold()  { echo -e "\033[1m$*\033[0m"; }
ok()    { echo -e "✅ $*"; }
warn()  { echo -e "⚠️  $*"; }
err()   { echo -e "❌ $*" >&2; }
step()  { echo -e "\n\033[1;34m[STEP]\033[0m $*"; }

PKG_CACHE_DIR="/opt/k8s-pkg-cache"
TMP_INSTALL_SH="/tmp/install_k8s_pkgs.sh"

# ==========================================================
# 1️⃣ 生成本地临时安装脚本
# ==========================================================
step "生成临时安装脚本 $TMP_INSTALL_SH"

cat > "$TMP_INSTALL_SH" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
PKG_CACHE_DIR="/opt/k8s-pkg-cache"

install_from_cache_or_apt() {
  local pkg="$1"
  local deb_file
  deb_file=$(ls "$PKG_CACHE_DIR"/${pkg}_*.deb 2>/dev/null | head -n1 || true)
  if [[ -n "$deb_file" ]]; then
    echo "📦 本地安装: $deb_file"
    dpkg -i "$deb_file" || apt-get install -f -y
  else
    echo "🌐 无缓存包，尝试联网安装: $pkg"
    apt-get update -y || true
    apt-get install -y "$pkg" || true
  fi
}

for p in chrony containerd cri-tools kubelet kubeadm kubectl; do
  install_from_cache_or_apt "$p"
done

echo "✅ $(hostname) 所有包安装完成"

echo "✅ $(hostname) dpkg -l 列表："
dpkg -l | grep -E "chrony|containerd|cri-tools|kubelet|kubeadm|kubectl"

EOS

chmod +x "$TMP_INSTALL_SH"
ok "已生成安装脚本 $TMP_INSTALL_SH"

# ==========================================================
# 2️⃣ 分发缓存目录和安装脚本到各节点（含本地执行）
# ==========================================================
step "分发缓存目录和安装脚本到各节点"

for NODE in "${ALL_NODES[@]}"; do
  bold ">>> 处理节点 ${NODE}"

  LOCAL_IP=$(hostname -I | awk '{print $1}')

  if [[ "$NODE" == "$LOCAL_IP" ]]; then
    ok "检测到本机节点 (${NODE})，直接执行本地安装脚本"
    bash "$TMP_INSTALL_SH"
    continue
  fi

  # ---------- 同步缓存目录 ----------
  sshpass -p "${SSH_PASS}" scp -P "${SSH_PORT}" -o StrictHostKeyChecking=no -r "${PKG_CACHE_DIR}" "${SSH_USER}@${NODE}:/opt" >/dev/null 2>&1 && \
    ok "✅ 已同步缓存目录到 ${NODE}" || { warn "⚠️ 同步缓存目录失败"; continue; }

  # ---------- 传输安装脚本 ----------
  sshpass -p "${SSH_PASS}" scp -P "${SSH_PORT}" -o StrictHostKeyChecking=no "$TMP_INSTALL_SH" "${SSH_USER}@${NODE}:/opt/install_k8s_pkgs.sh" >/dev/null 2>&1 && \
    ok "✅ 已传输安装脚本到 ${NODE}" || { warn "⚠️ 传输脚本失败"; continue; }

  # ---------- 执行远程安装 ----------
  sshpass -p "${SSH_PASS}" ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=no "${SSH_USER}@${NODE}" "bash /opt/install_k8s_pkgs.sh" || warn "⚠️ 远程执行失败"
done

ok "✅ 所有节点安装流程完成"
