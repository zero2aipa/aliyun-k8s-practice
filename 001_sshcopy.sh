#!/usr/bin/env bash
# ============================================================
# 01_ssh_copy_id_all.sh
# 使用 00_cluster.env 中的 ALL_NODES / SSH_USER 批量配置免密 SSH
#
# 依赖：
#   - 本机已安装 openssh-client, ssh-copy-id
#   - 00_cluster.env 中定义：
#       SSH_USER   # 远端登录用户，比如 ubuntu 或 root
#       ALL_NODES  # 节点 IP 列表（数组）
#
# 可选：
#   - SSH_PORT    # 非 22 端口时
#   - SSH_PASS    # 如果希望用 sshpass 自动输入密码（可选）
# ============================================================

set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
CLUSTER_ENV="${BASE_DIR}/00_cluster.env"

# ----- 简单输出函数 -----
bold() { echo -e "\033[1m$*\033[0m"; }
ok()   { echo -e "✅ $*"; }
warn() { echo -e "⚠️  $*"; }
err()  { echo -e "❌ $*" >&2; }

# ----- 加载集群配置 -----
if [[ -f "$CLUSTER_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$CLUSTER_ENV"
  ok "已加载配置: $CLUSTER_ENV"
else
  err "未找到 $CLUSTER_ENV，无法获取 ALL_NODES / SSH_USER"
  exit 1
fi

# 校验必要变量
: "${SSH_USER:?请在 00_cluster.env 中定义 SSH_USER，例如 SSH_USER=ubuntu}"
if [[ -z "${ALL_NODES[*]-}" ]]; then
  err "ALL_NODES 为空，请在 00_cluster.env 中定义 ALL_NODES 数组"
  exit 1
fi

SSH_PORT="${SSH_PORT:-22}"

bold "[STEP] 使用的 SSH 用户: ${SSH_USER}"
bold "[STEP] 使用的 SSH 端口: ${SSH_PORT}"
bold "[STEP] 目标节点列表: ${ALL_NODES[*]}"

echo

# ----- 确保本机安装了必要工具 -----
bold "[STEP] 检查并安装本机 SSH 工具..."
apt-get install -y openssh-client sshpass ssh-copy-id
echo

# ----- 确保本地有 SSH 公钥 -----
if [[ ! -f "$HOME/.ssh/id_rsa.pub" && ! -f "$HOME/.ssh/id_ed25519.pub" ]]; then
  warn "未检测到现有 SSH 公钥，准备生成新的密钥对 (~/.ssh/id_ed25519)..."
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -C "${USER}@$(hostname)" </dev/null
  ok "已生成 SSH 密钥对 ~/.ssh/id_ed25519{,.pub}"
else
  ok "已存在 SSH 公钥，跳过生成"
fi

# 找一个可用的 pub key
PUB_KEY_FILE=""
if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
  PUB_KEY_FILE="$HOME/.ssh/id_ed25519.pub"
elif [[ -f "$HOME/.ssh/id_rsa.pub" ]]; then
  PUB_KEY_FILE="$HOME/.ssh/id_rsa.pub"
fi

if [[ -z "$PUB_KEY_FILE" ]]; then
  err "未找到 SSH 公钥文件，退出"
  exit 1
fi

bold "[STEP] 使用公钥文件: $PUB_KEY_FILE"
echo

# ----- 函数：对单个节点执行 ssh-copy-id + hostname 验证 -----
copy_key_to_host() {
  local host="$1"
  local target="${SSH_USER}@${host}"

  bold "[STEP] 配置免密: ${target}"

  # 先检测是否已经免密
  if ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 "$target" 'echo ok' 2>/dev/null | grep -q '^ok$'; then
    ok "${target} 已经配置免密 SSH，跳过 ssh-copy-id"
  else
    # 决定使用 sshpass 还是交互式 ssh-copy-id
    if command -v sshpass >/dev/null 2>&1 && [[ -n "${SSH_PASS:-}" ]]; then
      sshpass -p "$SSH_PASS" ssh-copy-id -i "$PUB_KEY_FILE" -p "$SSH_PORT" "$target"
    else
      warn "未检测到 SSH_PASS 或 sshpass，将使用交互方式执行 ssh-copy-id（需要你手动输入密码）"
      ssh-copy-id -i "$PUB_KEY_FILE" -p "$SSH_PORT" "$target"
    fi
  fi

  # 再验证一次 hostname
  if ssh -p "$SSH_PORT" "$target" hostname 2>/dev/null; then
    ok "免密验证成功: ${target}"
  else
    warn "无法免密 ssh 到 ${target}，请手动检查"
  fi

  echo
}

# ----- 主循环：遍历 ALL_NODES -----
for h in "${ALL_NODES[@]}"; do
  copy_key_to_host "$h"
done

bold "[DONE] 所有节点免密 SSH 配置流程执行完毕。"



# ✅ 已加载配置: /root/aliyun-k8s-practice/00_cluster.env
# [STEP] 使用的 SSH 用户: root
# [STEP] 使用的 SSH 端口: 22
# [STEP] 目标节点列表: 192.168.92.10 192.168.92.11 192.168.92.12

# ✅ 已存在 SSH 公钥，跳过生成
# [STEP] 使用公钥文件: /root/.ssh/id_rsa.pub

# [STEP] 配置免密: root@192.168.92.10
# ✅ root@192.168.92.10 已经配置免密 SSH，跳过 ssh-copy-id
# master1
# ✅ 免密验证成功: root@192.168.92.10

# [STEP] 配置免密: root@192.168.92.11
# ✅ root@192.168.92.11 已经配置免密 SSH，跳过 ssh-copy-id
# node1
# ✅ 免密验证成功: root@192.168.92.11

# [STEP] 配置免密: root@192.168.92.12
# ✅ root@192.168.92.12 已经配置免密 SSH，跳过 ssh-copy-id
# node2
# ✅ 免密验证成功: root@192.168.92.12

# [DONE] 所有节点免密 SSH 配置流程执行完毕。