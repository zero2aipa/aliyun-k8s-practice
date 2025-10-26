#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# check_prepare_node_status.sh
# 检查所有节点是否已正确执行 03_prepare_node.sh
# ============================================================

# ======== 集群节点信息（请按需修改）========
source "/tmp/00_cluster.env"

# ======== 彩色输出 =========
GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"

bold()  { echo -e "\033[1m$*\033[0m"; }
ok()    { echo -e "${GREEN}✅${RESET} $*"; }
err()   { echo -e "${RED}❌${RESET} $*"; }
warn()  { echo -e "${YELLOW}⚠️ ${RESET} $*"; }
step()  { echo -e "\n${BLUE}[STEP]${RESET} $*"; }

# ======== 检查函数（远程执行）========
check_node() {
  local NODE="$1"
  echo -e "\n🔹 检查节点: ${NODE}"
  ssh -o BatchMode=yes -o ConnectTimeout=3 ${SSH_USER}@${NODE} bash -s <<'EOF'
set -e
RESULT_OK=1

check_swap() {
  if [[ "$(swapon --show | wc -l)" -eq 0 ]]; then
    echo "SWAP 状态: ✅ 已关闭"
  else
    echo "SWAP 状态: ❌ 未关闭"
    RESULT_OK=0
  fi
}

check_sysctl() {
  echo -n "SYSCTL 参数: "
  local ok_count=0
  local total=3
  local f1 f2 f3
  f1=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
  f2=$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null)
  f3=$(sysctl -n net.bridge.bridge-nf-call-ip6tables 2>/dev/null)
  if [[ "$f1" == "1" && "$f2" == "1" && "$f3" == "1" ]]; then
    echo "✅ 全部正确"
  else
    echo "❌ 存在错误 (ip_forward=$f1, nf-call-iptables=$f2, nf-call-ip6tables=$f3)"
    RESULT_OK=0
  fi
}

check_modules() {
  local miss=()
  for mod in br_netfilter overlay; do
    lsmod | grep -q "$mod" || miss+=("$mod")
  done
  if [[ "${#miss[@]}" -eq 0 ]]; then
    echo "内核模块: ✅ br_netfilter / overlay 已加载"
  else
    echo "内核模块: ❌ 缺少 ${miss[*]}"
    RESULT_OK=0
  fi
}

check_firewall() {
  if systemctl is-active --quiet ufw 2>/dev/null; then
    echo "防火墙: ❌ ufw 仍在运行"
    RESULT_OK=0
  elif systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "防火墙: ❌ firewalld 仍在运行"
    RESULT_OK=0
  else
    echo "防火墙: ✅ 已禁用"
  fi
}

check_chrony() {
  if systemctl is-active --quiet chrony 2>/dev/null; then
    echo "Chrony: ✅ 正常运行"
  else
    echo "Chrony: ❌ 未启动"
    RESULT_OK=0
  fi
}

check_swap
check_sysctl
check_modules
check_firewall
check_chrony

if [[ $RESULT_OK -eq 1 ]]; then
  echo -e "整体状态: ✅ 节点通过检查"
else
  echo -e "整体状态: ❌ 节点需重新执行 03_prepare_node.sh"
fi
EOF
}

# ======== 主流程 ========
step "开始检查集群节点准备状态"

for NODE in "${ALL_NODES[@]}"; do
  check_node "$NODE"
done

echo -e "\n${GREEN}🎯 检查完成。若任一节点出现 ❌，请重新执行..."
