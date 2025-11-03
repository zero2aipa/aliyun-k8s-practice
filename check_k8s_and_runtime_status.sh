#!/usr/bin/env bash
# ================================================================
#  检查 Kubernetes 与 Containerd 安装或卸载状态
#  作者: zero2aipa
#  版本: v1.0
#  功能: 自动检测安装状态、服务运行状态、文件残留等
# ================================================================

set -euo pipefail

# ---------- 彩色输出 ----------
bold() { echo -e "\033[1m$*\033[0m"; }
ok()   { echo -e "✅ \033[1;32m$*\033[0m"; }
warn() { echo -e "⚠️  \033[1;33m$*\033[0m"; }
err()  { echo -e "❌ \033[1;31m$*\033[0m"; }
sep()  { echo -e "\n\033[1;34m[CHECK]\033[0m $*"; }

# ---------- 检查函数 ----------

check_pkg() {
  local pkg=$1
  dpkg -s "$pkg" &>/dev/null && ok "包已安装: $pkg" || warn "包缺失: $pkg"
}

check_service() {
  local svc=$1
  if systemctl list-unit-files | grep -q "^${svc}.service"; then
    if systemctl is-active --quiet "$svc"; then
      ok "服务运行中: $svc"
    else
      warn "服务存在但未运行: $svc"
    fi
  else
    warn "服务未安装: $svc"
  fi
}

check_bin() {
  local bin=$1
  if command -v "$bin" &>/dev/null; then
    ok "命令存在: $bin ($(command -v $bin))"
  else
    warn "命令缺失: $bin"
  fi
}

check_path_clean() {
  local path=$1
  if [ -e "$path" ]; then
    warn "残留路径存在: $path"
  else
    ok "路径已清理: $path"
  fi
}

# ---------- 开始检查 ----------

sep "Kubernetes 包检查"
for pkg in kubelet kubeadm kubectl cri-tools kubernetes-cni; do
  check_pkg "$pkg"
done

sep "Containerd 与运行时检查"
for pkg in containerd runc libseccomp2 bridge-utils; do
  check_pkg "$pkg"
done

sep "系统辅助工具检查"
for pkg in sshpass conntrack ebtables socat ipset bash-completion; do
  check_pkg "$pkg"
done

sep "关键命令检查"
for bin in kubelet kubeadm kubectl crictl containerd; do
  check_bin "$bin"
done

sep "服务状态检查"
for svc in kubelet containerd cri-dockerd; do
  check_service "$svc"
done

sep "残留路径检查"
for path in /etc/kubernetes /var/lib/kubelet /var/lib/containerd /etc/containerd /opt/cni /etc/cni /var/lib/cni /opt/k8s-pkg-cache /opt/k8s-pkg-cache-full; do
  check_path_clean "$path"
done

sep "网络接口检查"
if ip link show | grep -q "cni0"; then
  warn "检测到 CNI 接口 cni0"
else
  ok "CNI 接口 cni0 不存在（正常）"
fi
if ip link show | grep -q "flannel.1"; then
  warn "检测到 flannel 接口 flannel.1"
else
  ok "Flannel 接口 flannel.1 不存在（正常）"
fi

sep "APT 源检查"
if grep -qr "pkgs.k8s.io" /etc/apt/sources.list* 2>/dev/null; then
  warn "发现 Kubernetes APT 源残留"
else
  ok "Kubernetes APT 源已清理"
fi

# ---------- 汇总结果 ----------
echo
bold "📊 检查完成："

total_warn=$(grep -c "⚠️" <(bash -c ''))
total_err=$(grep -c "❌" <(bash -c ''))
if (( total_err > 0 )); then
  err "存在严重问题，请检查上方错误输出"
elif grep -q "⚠️" <<<"$(set)"; then
  warn "存在警告项，请人工复查"
else
  ok "系统状态正常，一切就绪 ✅"
fi

