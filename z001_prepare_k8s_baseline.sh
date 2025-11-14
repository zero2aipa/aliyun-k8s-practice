#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Kubernetes 节点初始化脚本（基础准备阶段）
# 功能：防火墙 / Swap / 内核 / 时区 / 语言 / chrony ...
# 执行模式：
#   - 本地初始化当前节点
#   - 分发并远程初始化所有节点
# ============================================================

# ---------- 输出样式 ----------
bold()  { echo -e "\033[1m$*\033[0m"; }
ok()    { echo -e "✅ $*"; }
warn()  { echo -e "⚠️  $*"; }
err()   { echo -e "❌ $*" >&2; }
step()  { echo -e "\n\033[1;34m[STEP]\033[0m $*"; }

# ---------- 日志配置 ----------
LOG_DIR="/var/log/k8s-setup"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/baseline_prepare.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# ---------- 环境参数 ----------
SSH_USER="root"
SSH_PORT=22
TIMEZONE="Asia/Shanghai"
LANG_TO_SET="zh_CN.UTF-8"
PRIVATE_KEY_PATH="/root/aliyun-k8s-practice/key3.pem"

# 如果 00_cluster.env 存在则加载
if [[ -f ./00_cluster.env ]]; then
    step "加载配置文件 00_cluster.env"
    # shellcheck disable=SC1091
    source ./00_cluster.env
fi

ALL_NODES=("${ALL_NODES[@]:-172.18.208.11 172.18.208.12 172.18.208.13}")

# ============================================================
# 基础环境初始化（在远程节点执行）
# ============================================================
remote_node_script='
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "[STEP] 配置基础环境..."
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y locales language-pack-zh-hans tzdata curl ca-certificates gnupg lsb-release apt-transport-https chrony >/dev/null 2>&1 || true
locale-gen zh_CN.UTF-8 en_US.UTF-8 >/dev/null 2>&1 || true
update-locale LANG="zh_CN.UTF-8" LC_ALL="zh_CN.UTF-8" >/dev/null 2>&1 || true
timedatectl set-timezone "Asia/Shanghai" >/dev/null 2>&1 || true

echo "[STEP] 关闭防火墙并禁用 Swap..."
systemctl disable --now ufw 2>/dev/null || true
systemctl disable --now firewalld 2>/dev/null || true
swapoff -a || true
sed -ri "/\sswap\s/s/^#?/#/g" /etc/fstab || true

echo "[STEP] 加载内核模块..."
mkdir -p /etc/modules-load.d
cat >/etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay >/dev/null 2>&1 || true
modprobe br_netfilter >/dev/null 2>&1 || true

echo "[STEP] 配置 sysctl ..."
mkdir -p /etc/sysctl.d
cat >/etc/sysctl.d/99-k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null 2>&1 || true

echo "[STEP] 启用 chrony 同步时间..."
systemctl enable --now chrony >/dev/null 2>&1 || true
sleep 2
echo "✅ 节点 $(hostname) 初始化完成"
'

# ============================================================
# 函数定义
# ============================================================

# ---------- 分发脚本 ----------
scp_to_all() {
    step "分发初始化脚本到所有节点"
    local tmpfile="/tmp/node_baseline.sh"
    echo "$remote_node_script" > "$tmpfile"
    chmod +x "$tmpfile"

    for h in "${ALL_NODES[@]}"; do
        echo ">>> 复制到 $h ..."
        scp -q -P "$SSH_PORT" "$tmpfile" "${SSH_USER}@${h}:/tmp/node_baseline.sh"
    done
    ok "脚本分发完成"
}

# ---------- 远程执行 ----------
remote_exec_all() {
    step "顺序执行初始化脚本"
    for h in "${ALL_NODES[@]}"; do
        echo -e "\033[1;36m[$h]\033[0m"
        ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no "${SSH_USER}@${h}" "bash /tmp/node_baseline.sh"
        echo
    done
    ok "所有节点初始化完成 ✅"
}

# ============================================================
# 主执行逻辑
# ============================================================
main() {
    step "开始 K8S 节点环境准备"
    scp_to_all
    remote_exec_all
    ok "Kubernetes 节点基线准备工作全部完成 🎉"
}

main "$@"
