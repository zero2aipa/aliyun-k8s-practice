#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Kubernetes 集群基础环境初始化 + 基础包离线准备&分发&安装
# 不包含 K8S 组件，仅系统依赖 + 时区 + 语言 + chrony + sysctl
# ============================================================

# ---------- 输出样式 ----------
bold()  { echo -e "\033[1m$*\033[0m"; }
ok()    { echo -e "✅ $*"; }
warn()  { echo -e "⚠️  $*"; }
err()   { echo -e "❌ $*" >&2; }
step()  { echo -e "\n\033[1;34m[STEP]\033[0m $*"; }

# ---------- 环境参数 ----------
SSH_USER="root"
SSH_PORT=22
PRIVATE_KEY_PATH="/root/aliyun-k8s-practice/key3.pem"
BASE_PKG_DIR="/opt/base-pkg-cache"
REMOTE_PKG_DIR="/opt/base-pkg-cache"
LOG_DIR="/var/log/k8s-setup"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/base_prepare.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# ---------- 节点列表 ----------
ALL_NODES=("172.18.208.11" "172.18.208.12" "172.18.208.13")

# ============================================================
# 1️⃣ 本地下载基础包
# ============================================================
prepare_local_base_pkgs() {
    step "在本地下载基础系统包到 ${BASE_PKG_DIR}"
    mkdir -p "${BASE_PKG_DIR}"
    pushd "${BASE_PKG_DIR}" >/dev/null

    apt-get update -y >/dev/null

    pkgs=(
        "locales"
        "language-pack-zh-hans"
        "tzdata"
        "curl"
        "ca-certificates"
        "gnupg"
        "lsb-release"
        "apt-transport-https"
        "chrony"
    )

    for p in "${pkgs[@]}"; do
        echo "⬇️ 下载包: ${p}"
        apt-get download -y "${p}" || warn "${p} 下载失败"
    done

    ok "基础系统包已下载到: ${BASE_PKG_DIR}"
    popd >/dev/null
}

# ============================================================
# 2️⃣ 生成远程执行脚本（节点初始化 + 安装）
# ============================================================
generate_remote_script() {
    step "生成节点初始化脚本 /tmp/node_base_init.sh"
    cat >/tmp/node_base_init.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "[STEP] 配置基础环境..."
dpkg -i /opt/base-pkg-cache/*.deb >/dev/null 2>&1 || apt-get install -f -y >/dev/null 2>&1

# 关闭防火墙和 swap
systemctl disable --now ufw 2>/dev/null || true
systemctl disable --now firewalld 2>/dev/null || true
swapoff -a || true
sed -ri "/\sswap\s/s/^#?/#/g" /etc/fstab || true

# 设置语言和时区
locale-gen zh_CN.UTF-8 en_US.UTF-8 >/dev/null 2>&1 || true
update-locale LANG="zh_CN.UTF-8" LC_ALL="zh_CN.UTF-8" >/dev/null 2>&1 || true
timedatectl set-timezone "Asia/Shanghai" >/dev/null 2>&1 || true

# 加载内核模块
mkdir -p /etc/modules-load.d
cat >/etc/modules-load.d/k8s.conf <<EOM
overlay
br_netfilter
EOM
modprobe overlay >/dev/null 2>&1 || true
modprobe br_netfilter >/dev/null 2>&1 || true

# sysctl 设置
mkdir -p /etc/sysctl.d
cat >/etc/sysctl.d/99-k8s.conf <<EOM
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOM
sysctl --system >/dev/null 2>&1 || true

# 启动 chrony
systemctl enable --now chrony >/dev/null 2>&1 || true

echo "✅ $(hostname) 节点基础环境与包安装完成"
EOF

    chmod +x /tmp/node_base_init.sh
    ok "节点初始化脚本生成完成"
}

# ============================================================
# 3️⃣ 分发包目录 + 初始化脚本
# ============================================================
scp_script_and_pkgs() {
    step "分发基础包与初始化脚本到所有节点"
    for h in "${ALL_NODES[@]}"; do
        echo -e "\033[1;36m>>> ${h}\033[0m"
        ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no "${SSH_USER}@${h}" "mkdir -p ${REMOTE_PKG_DIR}"
        scp -q -P "$SSH_PORT" /tmp/node_base_init.sh "${SSH_USER}@${h}:/tmp/node_base_init.sh"
        scp -q -P "$SSH_PORT" "${BASE_PKG_DIR}"/*.deb "${SSH_USER}@${h}:${REMOTE_PKG_DIR}/"
    done
    ok "基础包与脚本分发完成"
}

# ============================================================
# 4️⃣ 远程执行节点初始化脚本
# ============================================================
remote_exec_all() {
    step "开始远程执行节点初始化脚本"
    for h in "${ALL_NODES[@]}"; do
        echo -e "\033[1;34m[EXEC] ${h}\033[0m"
        ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no "${SSH_USER}@${h}" "bash /tmp/node_base_init.sh"
        echo
    done
    ok "所有节点基础环境初始化完成 ✅"
}

# ============================================================
# 主执行流程
# ============================================================
main() {
    step "开始执行基础环境准备流程"
    prepare_local_base_pkgs
    generate_remote_script
    scp_script_and_pkgs
    remote_exec_all
    ok "🎉 全部节点基础环境与基础包准备完成，可继续 K8S 组件安装"
}

main "$@"
