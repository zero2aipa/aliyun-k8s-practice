#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Kubernetes 集群节点初始化脚本（多节点通用）
# 作者：WGP / ChatGPT 优化版
# 版本：v2.1 - 2025-11-03
# ============================================================

# ---------- 输出样式 ----------
bold()  { echo -e "\033[1m$*\033[0m"; }
ok()    { echo -e "✅ $*"; }
warn()  { echo -e "⚠️  $*"; }
err()   { echo -e "❌ $*" >&2; }
step()  { echo -e "\n\033[1;34m[STEP]\033[0m $*"; }

# ---------- 全局异常处理 ----------
trap 'err "脚本执行出错，查看日志 ${LOG_FILE} 的最后 20 行：" && tail -n 20 "${LOG_FILE}"' ERR

# ---------- 日志配置 ----------
LOG_DIR="/var/log/k8s-setup"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/cluster_init_$(date +%F_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

step "集群节点初始化开始 - 日志文件: ${LOG_FILE}"

# ---------- 配置加载 ----------
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_LOADED=false
PRIVATE_KEY_PATH=""

load_config() {
    local config_candidates=(
        "${BASE_DIR}/00_cluster.env"
        "/tmp/00_cluster.env"
        "/root/00_cluster.env"
    )
    for cfg in "${config_candidates[@]}"; do
        if [[ -f "$cfg" ]]; then
            step "加载配置文件: $cfg"
            # shellcheck disable=SC1090
            source "$cfg"
            CONFIG_LOADED=true
            PRIVATE_KEY_PATH="${PRIVATE_KEY_PATH:-/root/aliyun-k8s-practice/key3.pem}"
            ok "配置文件加载成功"
            return 0
        fi
    done

    warn "未找到配置文件，使用默认参数（单节点/worker 模式）"
    SSH_USER="${SSH_USER:-root}"
    SSH_PORT="${SSH_PORT:-22}"
    TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
    LANG_TO_SET="${LANG_TO_SET:-zh_CN.UTF-8}"
    HOST_PREFIX="${HOST_PREFIX:-k8s}"
    PRIVATE_KEY_PATH="${PRIVATE_KEY_PATH:-/root/aliyun-k8s-practice/key3.pem}"
    ALL_MASTERS=()
    ALL_WORKERS=()
}

load_config

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# ---------- 网络连通性检查 ----------
check_ssh_connectivity() {
    local node="$1"
    local port="${2:-22}"
    if timeout 3 bash -c "echo > /dev/tcp/${node}/${port}" 2>/dev/null; then
        ok "SSH ${node}:${port} 可达"
        return 0
    else
        warn "无法连接 ${node}:${port}"
        return 1
    fi
}

# ---------- SSH 服务配置 ----------
configure_ssh() {
    step "配置 SSH 服务（root 登录 + 密码认证）"

    local ssh_cfg="/etc/ssh/sshd_config"
    local root_pass="${ROOT_PASS:-K8s@1234}"

    echo "root:${root_pass}" | chpasswd
    ok "root 密码已设置"

    sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin yes/' "$ssh_cfg"
    sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/' "$ssh_cfg"
    sed -ri 's/^#?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$ssh_cfg"

    if [[ -f /etc/cloud/cloud.cfg ]]; then
        sed -ri 's/^disable_root: .*/disable_root: 0/' /etc/cloud/cloud.cfg
        sed -ri 's/^ssh_pwauth: .*/ssh_pwauth:   yes/' /etc/cloud/cloud.cfg
        ok "cloud-init 配置已更新"
    fi

    systemctl daemon-reexec >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart sshd 2>/dev/null || systemctl restart ssh || true

    if ss -tlnp | grep -q ':22'; then
        ok "SSH 服务运行正常"
    else
        warn "SSH 服务未在 22 端口监听"
    fi
}

# ---------- SSH 密钥管理 ----------
generate_ssh_keys() {
    step "生成 SSH 密钥对（root 用户）"

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    if [[ ! -f /root/.ssh/id_rsa ]]; then
        ssh-keygen -t rsa -b 2048 -m PEM -N "" -f /root/.ssh/id_rsa >/dev/null
        ok "已生成新的 PEM 格式密钥：/root/.ssh/id_rsa"
    else
        ok "已存在密钥：/root/.ssh/id_rsa"
    fi
}

# ---------- 主机名 & /etc/hosts ----------
configure_hosts() {
    step "配置主机名与 /etc/hosts"

    local my_ip
    my_ip=$(hostname -I | awk '{print $1}')
    local role="node"
    local index=1

    if [[ "$CONFIG_LOADED" == true ]]; then
        for i in "${!ALL_MASTERS[@]}"; do
            if [[ "${ALL_MASTERS[$i]}" == "$my_ip" ]]; then
                role="master"; index=$((i+1)); break
            fi
        done
        if [[ "$role" == "node" ]]; then
            for i in "${!ALL_WORKERS[@]}"; do
                if [[ "${ALL_WORKERS[$i]}" == "$my_ip" ]]; then
                    index=$((i+1)); break
                fi
            done
        fi
    fi

    local new_hostname="${HOST_PREFIX}${role}${index}"
    hostnamectl set-hostname "$new_hostname"
    ok "主机名设置为：${new_hostname}（角色：${role}）"

    if [[ "$CONFIG_LOADED" == true ]]; then
        step "生成 /etc/hosts 文件"
        {
            echo "127.0.0.1 localhost"
            echo "::1 localhost ip6-localhost"
            for ((i=0; i<${#ALL_MASTERS[@]}; i++)); do
                echo "${ALL_MASTERS[$i]} ${HOST_PREFIX}master$((i+1))"
            done
            for ((i=0; i<${#ALL_WORKERS[@]}; i++)); do
                echo "${ALL_WORKERS[$i]} ${HOST_PREFIX}node$((i+1))"
            done
        } > /etc/hosts
        ok "已更新 /etc/hosts："
        cat /etc/hosts
    fi
}

# ---------- 主函数 ----------
main() {
    configure_ssh
    generate_ssh_keys
    configure_hosts

    # 检查 SSH 连通性（可选）
    if [[ "$CONFIG_LOADED" == true ]]; then
        for node in "${ALL_MASTERS[@]}" "${ALL_WORKERS[@]}"; do
            [[ "$node" != "$(hostname -I | awk '{print $1}')" ]] && check_ssh_connectivity "$node" 22
        done
    fi

    ok "节点初始化完成 ✅"
}

main "$@"
