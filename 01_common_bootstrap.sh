#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/00_cluster.env"

# ---------- 美观输出 ----------
bold()  { echo -e "\033[1m$*\033[0m"; }
ok()    { echo -e "✅ $*"; }
warn()  { echo -e "⚠️  $*"; }
err()   { echo -e "❌ $*" >&2; }
step()  { echo -e "\n\033[1;34m[STEP]\033[0m $*"; }

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# ---------- 基础准备 ----------
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

# ---------- SSH key ----------
step "生成 SSH key（如无）"
if [[ ! -f /root/.ssh/id_rsa ]]; then
  mkdir -p /root/.ssh
  ssh-keygen -t rsa -N "" -f /root/.ssh/id_rsa <<<y >/dev/null 2>&1
  ok "已生成 SSH key"
else
  ok "SSH key 已存在"
fi

# ---------- 主机名与角色 ----------
step "识别节点角色并设置主机名"

MYIP=$(hostname -I | awk '{print $1}')
ROLE="node"
INDEX=1

# 判断是否为 master
for i in "${!ALL_MASTERS[@]}"; do
  if [[ "${ALL_MASTERS[$i]}" == "$MYIP" ]]; then
    ROLE="master"
    INDEX=$((i+1))
    break
  fi
done

# 如果不在 master 列表中，则判断是否属于 node
if [[ "$ROLE" == "node" ]]; then
  for i in "${!ALL_NODES[@]}"; do
    if [[ "${ALL_NODES[$i]}" == "$MYIP" ]]; then
      INDEX=$((i+1))
      break
    fi
  done
fi

NEW_HOSTNAME="${HOST_PREFIX}-${ROLE}-${INDEX}"
hostnamectl set-hostname "${NEW_HOSTNAME}"
ok "主机名已设置为：${NEW_HOSTNAME}（角色：${ROLE}）"

# ---------- /etc/hosts 更新 ----------
step "生成统一 /etc/hosts 文件"

{
  echo "127.0.0.1 localhost"
  for ((i=0; i<${#ALL_MASTERS[@]}; i++)); do
    echo "${ALL_MASTERS[$i]} ${HOST_PREFIX}-master-$((i+1))"
  done
  for ((i=0; i<${#ALL_NODES[@]}; i++)); do
    echo "${ALL_NODES[$i]} ${HOST_PREFIX}-node-$((i+1))"
  done
} > /etc/hosts

ok "本地 /etc/hosts 生成完成："
grep -E "${HOST_PREFIX}-" /etc/hosts | awk '{print "   "$0}'

# ---------- 分发 /etc/hosts ----------
ALL_CLUSTER_IPS=("${ALL_MASTERS[@]}" "${ALL_NODES[@]}")
step "分发 /etc/hosts 文件到所有节点"

for NODE in "${ALL_CLUSTER_IPS[@]}"; do
  if [[ "$NODE" == "$MYIP" ]]; then continue; fi
  if timeout 10s sshpass -p "${SSH_PASS}" scp -P "${SSH_PORT}" -o StrictHostKeyChecking=no /etc/hosts "${SSH_USER}@${NODE}:/etc/hosts" >/dev/null 2>&1; then
    ok "同步 /etc/hosts 至 ${NODE}"
  else
    warn "同步 /etc/hosts 至 ${NODE} 失败（跳过）"
  fi
done
ok "全部节点 /etc/hosts 分发完成"

# ---------- 分发 SSH key ----------
step "分发公钥免密登录（安全跳过失败节点）"

PUBKEY_PATH="/root/.ssh/id_rsa.pub"
for NODE in "${ALL_CLUSTER_IPS[@]}"; do
  if [[ "$NODE" == "$MYIP" ]]; then continue; fi
  echo "👉 正在处理节点 ${NODE} ..."
  
  # 测试连通性（3 秒超时）
  if ! timeout 3s bash -c "echo > /dev/tcp/${NODE}/${SSH_PORT}" 2>/dev/null; then
    warn "节点 ${NODE} SSH 端口不可达（跳过）"
    continue
  fi

  # 确保目标节点 .ssh 存在
  if timeout 8s sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no -p "${SSH_PORT}" "${SSH_USER}@${NODE}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh" >/dev/null 2>&1; then
    :
  else
    warn "节点 ${NODE} SSH 建立目录失败（跳过）"
    continue
  fi

  # 直接拷贝公钥内容（替代 ssh-copy-id）
  if timeout 10s sshpass -p "${SSH_PASS}" scp -P "${SSH_PORT}" -o StrictHostKeyChecking=no "${PUBKEY_PATH}" "${SSH_USER}@${NODE}:/tmp/id_rsa.pub.$$" >/dev/null 2>&1; then
    timeout 8s sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no -p "${SSH_PORT}" "${SSH_USER}@${NODE}" \
      "cat /tmp/id_rsa.pub.$$ >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && rm -f /tmp/id_rsa.pub.$$" >/dev/null 2>&1 \
      && ok "免密已配置：${NODE}" \
      || warn "节点 ${NODE} 更新 authorized_keys 失败"
  else
    warn "SCP 公钥到 ${NODE} 失败（跳过）"
  fi
done
ok "SSH 互信配置流程完成"

