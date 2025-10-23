#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/00_cluster.env"

bold()  { echo -e "\033[1m$*\033[0m"; }
ok()    { echo -e "✅ $*"; }
warn()  { echo -e "⚠️  $*"; }
step()  { echo -e "\n\033[1;34m[STEP]\033[0m $*"; }

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

step "禁用防火墙（如开启）并禁用 swap"
systemctl disable --now ufw 2>/dev/null || systemctl disable --now firewalld 2>/dev/null || true
swapoff -a
sed -ri '/\sswap\s/s/^#?/#/g' /etc/fstab
ok "防火墙处理完毕，Swap 已禁用"

step "加载内核模块、设置 sysctl（容器与转发必需）"
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay || true
modprobe br_netfilter || true

cat >/etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null
ok "内核与内核参数设置完成"

step "安装并启用 chrony（时间同步）"
apt-get update -y >/dev/null
apt-get install "${APT_FLAGS[@]}" chrony >/dev/null
systemctl enable --now chrony
ok "chrony 已启动：$(chronyc tracking | head -n1 || echo 'N/A')"

ok "公共基线准备完成（可在全体节点执行）"
