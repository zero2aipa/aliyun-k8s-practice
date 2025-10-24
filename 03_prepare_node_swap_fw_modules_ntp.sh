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

# ========== 本地执行节点准备 ==========
step "禁用防火墙（如开启）并禁用 swap"
{
  systemctl disable --now ufw 2>/dev/null || systemctl disable --now firewalld 2>/dev/null || true
  swapoff -a
  sed -ri '/\sswap\s/s/^#?/#/g' /etc/fstab
} >/dev/null 2>&1
ok "防火墙处理完毕，Swap 已禁用"

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

if sysctl --system 2>&1 | grep -v -E "无效的参数|Invalid argument" >/dev/null; then
  ok "内核与内核参数设置完成"
else
  warn "部分 sysctl 参数在当前内核中不受支持（可忽略）"
fi

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

ok "✅ 本节点公共基线准备完成"

# ========== 分发并远程执行 ==========
step "分发并在其他节点执行相同初始化"

SCRIPT_PATH="$(realpath "$0")"

for NODE in "${ALL_NODES[@]}"; do
  bold ">>> 处理节点 ${NODE}"

  # 跳过本机
  if [[ "$NODE" == "$(hostname -I | awk '{print $1}')" ]]; then
    ok "跳过本机节点 ${NODE}"
    continue
  fi

  # SSH 连通性检测
  if ! timeout 3 bash -c "echo > /dev/tcp/${NODE}/${SSH_PORT}" 2>/dev/null; then
    warn "节点 ${NODE} SSH 端口 ${SSH_PORT} 不可达（跳过）"
    continue
  fi

  # 分发脚本
  if ! timeout 20s scp -P "${SSH_PORT}" -o StrictHostKeyChecking=no "${SCRIPT_PATH}" "${SSH_USER}@${NODE}:/tmp/03_prepare_node.sh" >/dev/null 2>&1; then
    warn "SCP 到 ${NODE} 失败（跳过）"
    continue
  fi

  # 远程执行
  if timeout 90s sshpass -p "${SSH_PASS}" ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=no "${SSH_USER}@${NODE}" 'bash /tmp/03_prepare_node.sh' >/dev/null 2>&1; then
    ok "节点 ${NODE} 初始化成功"
  else
    warn "节点 ${NODE} 初始化失败或超时（跳过）"
  fi
done

ok "✅ 全部节点基础准备（防火墙/Swap/内核/时间同步）流程完成"
