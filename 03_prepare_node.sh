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

# ---------- 防火墙与 Swap ----------
step "禁用防火墙（如开启）并禁用 swap"
{
  systemctl disable --now ufw 2>/dev/null || systemctl disable --now firewalld 2>/dev/null || true
  swapoff -a
  sed -ri '/\sswap\s/s/^#?/#/g' /etc/fstab
} >/dev/null 2>&1
ok "防火墙处理完毕，Swap 已禁用"

# ---------- 内核模块与 sysctl ----------
step "加载内核模块、设置 sysctl（容器与转发必需）"
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay >/dev/null 2>&1 || true
modprobe br_netfilter >/dev/null 2>&1 || true

cat >/etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF

# 过滤掉“无效参数”类警告
if sysctl --system 2>&1 | grep -v -E "无效的参数|Invalid argument" >/dev/null; then
  ok "内核与内核参数设置完成"
else
  warn "部分 sysctl 参数在当前内核中不受支持（可忽略）"
fi

# ---------- 时间同步 ----------
step "安装并启用 chrony（时间同步）"
if ! dpkg -s chrony >/dev/null 2>&1; then
  apt-get update -y >/dev/null
  apt-get install "${APT_FLAGS[@]}" chrony >/dev/null 2>&1
fi

systemctl enable --now chrony >/dev/null 2>&1 || warn "chrony 启动失败"
sleep 2

if chronyc tracking >/dev/null 2>&1; then
  REF_LINE=$(chronyc tracking | grep 'Reference ID' | head -n1)
  ok "chrony 已启动：${REF_LINE:-未检测到时钟源}"
else
  warn "chrony 已安装但暂未同步，请稍后检查"
fi

ok "公共基线准备完成（可在全体节点执行）"
