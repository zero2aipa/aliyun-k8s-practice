#!/usr/bin/env bash
set -euo pipefail

# 读入配置
source "$(dirname "$0")/00_cluster.env"

# --------- 美观输出工具 ----------
bold()  { echo -e "\033[1m$*\033[0m"; }
ok()    { echo -e "✅ $*"; }
warn()  { echo -e "⚠️  $*"; }
err()   { echo -e "❌ $*" >&2; }
step()  { echo -e "\n\033[1;34m[STEP]\033[0m $*"; }

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

step "更新 APT 索引并安装基础包（含 sshpass）"
apt-get update -y >/dev/null
apt-get install "${APT_FLAGS[@]}" locales language-pack-zh-hans tzdata sshpass curl ca-certificates gnupg lsb-release apt-transport-https >/dev/null
ok "基础包就绪"

step "设置统一语言与本地化（${LANG_TO_SET}）"
locale-gen zh_CN.UTF-8 en_US.UTF-8 >/dev/null
update-locale LANG="${LANG_TO_SET}" LC_ALL="${LANG_TO_SET}"
ok "语言已设置：$(locale | grep -E 'LANG=|LC_ALL=')"

step "设置统一时区：${TIMEZONE}"
timedatectl set-timezone "${TIMEZONE}"
ok "当前时间：$(date)"

step "生成 SSH key（如无）并提示互信（可选）"
if [[ ! -f /root/.ssh/id_rsa ]]; then
  mkdir -p /root/.ssh
  ssh-keygen -t rsa -N "" -f /root/.ssh/id_rsa <<<y >/dev/null 2>&1
  ok "已生成 /root/.ssh/id_rsa"
else
  ok "已存在 SSH key，跳过生成"
fi

step "（可选）将公钥分发到各节点（免密）"
for NODE in "${ALL_NODES[@]}"; do
  if [[ "$NODE" == "$(hostname -I | awk '{print $1}')" ]]; then continue; fi
  sshpass -p "${SSH_PASS}" ssh-copy-id -o StrictHostKeyChecking=no -p "${SSH_PORT}" "${SSH_USER}@${NODE}" >/dev/null 2>&1 || warn "ssh-copy-id ${NODE} 失败，稍后可重试"
done
ok "互信分发流程完成（失败项可手动重试）"
