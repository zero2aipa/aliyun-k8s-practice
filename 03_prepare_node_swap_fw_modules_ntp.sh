#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 03_prepare_node_swap_fw_modules_ntp_v3.sh
# 作用：基础基线准备（防火墙/Swap/内核/时区/语言/chrony）
# 特性：
#  - Master：自动对 ALL_NODES 远程执行相同逻辑（无需 scp）
#  - Worker：即使没有 00_cluster.env 也能独立执行
#  - 日志：/var/log/k8s-setup/03_prepare_node.log
# ============================================================

# ---------- 输出样式 ----------
bold()  { echo -e "\033[1m$*\033[0m"; }
ok()    { echo -e "✅ $*"; }
warn()  { echo -e "⚠️  $*"; }
err()   { echo -e "❌ $*" >&2; }
step()  { echo -e "\n\033[1;34m[STEP]\033[0m $*"; }

# ---------- 日志 ----------
LOG_DIR="/var/log/k8s-setup"
mkdir -p "${LOG_DIR}"
exec > >(tee -a "${LOG_DIR}/03_prepare_node.log") 2>&1

# ---------- 加载配置（允许无 env 运行） ----------
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${BASE_DIR}/00_cluster.env" ]]; then
  # shellcheck disable=SC1091
  source "${BASE_DIR}/00_cluster.env"
elif [[ -f "/tmp/00_cluster.env" ]]; then
  # shellcheck disable=SC1091
  source "/tmp/00_cluster.env"
else
  warn "未找到 00_cluster.env，使用默认参数（适用于单节点/Worker 本地执行）"
  SSH_USER="root"
  SSH_PASS="YourRootPassword"
  SSH_PORT=22
  TIMEZONE="Asia/Shanghai"
  LANG_TO_SET="zh_CN.UTF-8"
  ALL_NODES=()
fi

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# ---------- 公共函数：节点基线初始化 ----------
node_prepare_inline() {
  # 关闭防火墙 + Swap
  systemctl disable --now ufw 2>/dev/null || true
  systemctl disable --now firewalld 2>/dev/null || true
  swapoff -a || true
  sed -ri '/\sswap\s/s/^#?/#/g' /etc/fstab || true

  # 时区与语言
  timedatectl set-timezone "${TIMEZONE}" >/dev/null 2>&1 || true
  localectl set-locale "LANG=${LANG_TO_SET}" >/dev/null 2>&1 || true

  # 内核模块 + sysctl
  mkdir -p /etc/modules-load.d /etc/sysctl.d
  cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
  modprobe overlay  >/dev/null 2>&1 || true
  modprobe br_netfilter >/dev/null 2>&1 || true

  cat >/etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
  sysctl --system 2>&1 | grep -v -E "无效的参数|Invalid argument" >/dev/null || true

  # chrony
  if ! dpkg -s chrony >/dev/null 2>&1; then
    # 在线优先，失败则静默（可能靠 02 的离线包）
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install "${APT_FLAGS[@]}" chrony >/dev/null 2>&1 || true
  fi
  systemctl enable --now chrony >/dev/null 2>&1 || true
  sleep 2
  chronyc tracking 2>/dev/null | head -n1 || true
}

# ============================================================
# 1️⃣ 本机（当前节点）准备
# ============================================================
step "禁用防火墙、禁用 Swap、设置时区与语言、加载内核模块、配置 sysctl、安装并启用 chrony（本机）"
node_prepare_inline
ok "本机公共基线已完成（时区=${TIMEZONE}，语言=${LANG_TO_SET}）"

# ============================================================
# 2️⃣ （Master 才执行）对其他节点远程执行相同初始化
# ============================================================
if [[ "${#ALL_NODES[@]}" -gt 0 ]]; then
  step "分发并在其他节点执行相同初始化（SSH 远程执行，无需 scp）"

  SELF_IP="$(hostname -I | awk '{print $1}')"
  for NODE in "${ALL_NODES[@]}"; do
    bold "--------------------------------------------------"
    bold ">>> 处理节点 ${NODE}"
    bold "--------------------------------------------------"

    # 跳过本机
    if [[ "${NODE}" == "${SELF_IP}" ]]; then
      ok "跳过本机 ${NODE}"
      continue
    fi

    # 端口探测
    if ! timeout 3 bash -c "echo > /dev/tcp/${NODE}/${SSH_PORT}" 2>/dev/null; then
      warn "节点 ${NODE} SSH 端口 ${SSH_PORT} 不可达（跳过）"
      continue
    fi

    # 远程执行相同逻辑（注意：去掉 heredoc 引号以展开本地变量 TIMEZONE/LANG_TO_SET）
    if timeout 120s sshpass -p "${SSH_PASS}" ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=no "${SSH_USER}@${NODE}" "bash -s" <<EOSSH
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo -e "\n\033[1;34m[STEP]\033[0m ${NODE}: 关闭防火墙 & Swap"
systemctl disable --now ufw 2>/dev/null || true
systemctl disable --now firewalld 2>/dev/null || true
swapoff -a || true
sed -ri '/\sswap\s/s/^#?/#/g' /etc/fstab || true

echo -e "\n\033[1;34m[STEP]\033[0m ${NODE}: 设置时区与语言"
timedatectl set-timezone "${TIMEZONE}" >/dev/null 2>&1 || true
localectl set-locale "LANG=${LANG_TO_SET}" >/dev/null 2>&1 || true

echo -e "\n\033[1;34m[STEP]\033[0m ${NODE}: 加载内核模块 + sysctl"
mkdir -p /etc/modules-load.d /etc/sysctl.d
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay  >/dev/null 2>&1 || true
modprobe br_netfilter >/dev/null 2>&1 || true

cat >/etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sysctl --system 2>&1 | grep -v -E "无效的参数|Invalid argument" >/dev/null || true

echo -e "\n\033[1;34m[STEP]\033[0m ${NODE}: 安装并启用 chrony"
if ! dpkg -s chrony >/dev/null 2>&1; then
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y chrony >/dev/null 2>&1 || true
fi
systemctl enable --now chrony >/dev/null 2>&1 || true
sleep 2
chronyc tracking 2>/dev/null | head -n1 || true

echo "✅ ${NODE} 节点公共基线准备完成"
EOSSH
    then
      ok "节点 ${NODE} 初始化完成"
    else
      warn "节点 ${NODE} 初始化失败或超时（跳过）"
    fi
  done
else
  ok "未定义 ALL_NODES（检测为单节点/Worker 独立执行模式，跳过远程步骤）"
fi

ok "✅ 全部节点基础准备（防火墙/Swap/内核/时区/语言/chrony）流程完成"
