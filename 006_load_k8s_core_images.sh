#!/usr/bin/env bash
# ============================================================
# load_k8s_core_images.sh
# 功能：
#   1. 自动下载 K8s 核心镜像（如在线，但你一般在 master 上下载）
#   2. 保存为 /opt/k8s-image-cache/*.tar
#   3. 全自动分发到所有节点
#   4. 在所有节点执行 ctr -n k8s.io images import
#
# 适配你的环境：
#   - 镜像仓库：registry.aliyuncs.com/google_containers
#   - K8S 版本：v1.28.0
#   - ETCD：3.5.12-0
#   - CoreDNS：v1.11.1
# ============================================================

set -e

# --- 镜像列表 ---
IMGS=(
  "registry.aliyuncs.com/google_containers/kube-apiserver:v1.28.0"
  "registry.aliyuncs.com/google_containers/kube-controller-manager:v1.28.0"
  "registry.aliyuncs.com/google_containers/kube-scheduler:v1.28.0"
  "registry.aliyuncs.com/google_containers/kube-proxy:v1.28.0"
  "registry.aliyuncs.com/google_containers/etcd:3.5.12-0"
  "registry.aliyuncs.com/google_containers/coredns:v1.11.1"
  "registry.aliyuncs.com/google_containers/pause:3.9"
)

CACHE_DIR="/opt/k8s-image-cache"
mkdir -p "${CACHE_DIR}"

# --- 节点列表（按你之前 00_cluster.env 中 ALL_NODES）---
ALL_NODES=("192.168.92.10" "192.168.92.11" "192.168.92.12")
SSH_USER="root"
SSH_PORT=22

COLOR_GREEN="\033[1;32m"; COLOR_YELLOW="\033[1;33m"; COLOR_RED="\033[1;31m"; COLOR_RESET="\033[0m"
ok(){ echo -e "${COLOR_GREEN}✔${COLOR_RESET} $*"; }
warn(){ echo -e "${COLOR_YELLOW}!${COLOR_RESET} $*"; }
err(){ echo -e "${COLOR_RED}✘${COLOR_RESET} $*"; }

echo "📦 加载 Kubernetes 核心镜像（支持在线下载 + 离线分发）"

# ============================================================
# 1. 下载镜像（如果在线）并保存为 tar
# ============================================================
for IMG in "${IMGS[@]}"; do
  FILE="${CACHE_DIR}/$(echo ${IMG##*/} | tr ':' '-')".tar  # 如 kube-apiserver-v1.28.0.tar

  echo ">>> 处理镜像: $IMG"

  if [[ -f "$FILE" ]]; then
    ok "已存在本地缓存: $FILE"
  else
    warn "本地不存在，将下载并保存为 TAR（若网络可用）"
    if ctr images pull "$IMG" >/dev/null 2>&1; then
      ok "已成功从仓库拉取: $IMG"
      ctr images export "$FILE" "$IMG"
      ok "已导出到: $FILE"
    else
      warn "无法在线拉取：$IMG（若是完全离线，此警告正常）"
    fi
  fi

  if [[ ! -f "$FILE" ]]; then
    warn "缺少 TAR 文件: $FILE（请确保你有离线镜像）"
  fi
done

echo
echo "📤 开始分发镜像到所有节点..."

# ============================================================
# 2. 分发 tar 到所有节点
# ============================================================
for NODE in "${ALL_NODES[@]}"; do
  echo ">>> 分发到节点: $NODE"

  if [[ "$NODE" == "$(hostname -I | awk '{print $1}')" ]]; then
    ok "(本机) 跳过 scp 分发"
    continue
  fi
  # 在远端提前创建目录
  ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no "${SSH_USER}@${NODE}" \
    "mkdir -p ${CACHE_DIR}" >/dev/null 2>&1 \
    && ok "远端目录已创建: $NODE:${CACHE_DIR}" \
    || warn "无法在节点 ${NODE} 创建目录 ${CACHE_DIR}"

  for IMG in "${IMGS[@]}"; do
    FILE="${CACHE_DIR}/$(echo ${IMG##*/} | tr ':' '-')".tar
    if [[ -f "$FILE" ]]; then
      scp -P "$SSH_PORT" "$FILE" "${SSH_USER}@${NODE}:${CACHE_DIR}/" >/dev/null 2>&1 \
        && ok "已分发 $FILE 到 $NODE" \
        || warn "分发失败：$NODE - $FILE"
    else
      warn "本机缺少 TAR：$FILE，无法分发"
    fi
  done
done

echo
echo "🛠 开始在各节点 load 镜像到 containerd..."

# ============================================================
# 3. 所有节点执行 ctr load
# ============================================================
for NODE in "${ALL_NODES[@]}"; do
  echo ">>> 节点加载: $NODE"

  for IMG in "${IMGS[@]}"; do
    FILE="$(echo ${IMG##*/} | tr ':' '-')".tar
    FULL="${CACHE_DIR}/${FILE}"

    CMD="if [ -f '${FULL}' ]; then ctr -n k8s.io images import '${FULL}' >/dev/null 2>&1 && echo '   ✔ load ${FILE}' || echo '   ✘ load 失败：${FILE}'; else echo '   ✘ 缺少镜像文件：${FILE}'; fi"

    if [[ "$NODE" == "$(hostname -I | awk '{print $1}')" ]]; then
      # 本机执行
      eval "$CMD"
    else
      ssh -p "$SSH_PORT" "${SSH_USER}@${NODE}" "$CMD"
    fi
  done
done

echo
echo "🎉 所有镜像分发 + 加载完成"
