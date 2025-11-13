#!/usr/bin/env bash
# ============================================================
# calico_offline_prepare.sh
# 功能：
#   1. 下载（或离线使用）Calico 所需镜像
#   2. 保存为 .tar
#   3. 分发到 Node 节点
#   4. 在所有节点 containerd 中 import 镜像
#   5. 生成 calico.yaml（已替换镜像路径）
# ============================================================

set -e

CALICO_VERSION="v3.27.2"
CACHE_DIR="/opt/k8s-calico-cache"
mkdir -p "${CACHE_DIR}"

# Calico 镜像列表
IMGS=(
  "docker.io/calico/node:${CALICO_VERSION}"
  "docker.io/calico/cni:${CALICO_VERSION}"
  "docker.io/calico/pod2daemon-flexvol:${CALICO_VERSION}"
  "docker.io/calico/kube-controllers:${CALICO_VERSION}"
)

# 集群节点（你之前 ALL_NODES）
ALL_NODES=("192.168.92.10" "192.168.92.11" "192.168.92.12")
SSH_USER="root"
SSH_PORT=22

COLOR_GREEN="\033[1;32m"; COLOR_YELLOW="\033[1;33m"; COLOR_RED="\033[1;31m"; COLOR_RESET="\033[0m"
ok(){ echo -e "${COLOR_GREEN}✔${COLOR_RESET} $*"; }
warn(){ echo -e "${COLOR_YELLOW}!${COLOR_RESET} $*"; }
err(){ echo -e "${COLOR_RED}✘${COLOR_RESET} $*"; }

echo "📦 准备 Calico ${CALICO_VERSION} 离线镜像..."

# ============================================================
# 下载 / 保存镜像
# ============================================================
for IMG in "${IMGS[@]}"; do
  FILE="${CACHE_DIR}/$(echo ${IMG##*/} | tr ':' '-')".tar

  echo ">>> 处理镜像：$IMG"

  if [[ -f "$FILE" ]]; then
    ok "已存在 TAR: $FILE"
    continue
  fi

  warn "本地不存在 TAR，将尝试下载..."

  if ctr images pull "$IMG" >/dev/null 2>&1; then
    ok "已下载: $IMG"
    ctr images export "$FILE" "$IMG"
    ok "已保存为: $FILE"
  else
    warn "无法下载（若离线环境，此警告正常）"
  fi

done

echo
echo "📤 分发 TAR 到各节点..."

for NODE in "${ALL_NODES[@]}"; do
  echo ">>> 分发到节点: $NODE"

  # 本机不需要分发
  if [[ "$NODE" == "$(hostname -I | awk '{print $1}')" ]]; then
    ok "(本机跳过 SCP)"
    continue
  fi

  ssh -p "${SSH_PORT}" "${SSH_USER}@${NODE}" "mkdir -p ${CACHE_DIR}"

  for IMG in "${IMGS[@]}"; do
    FILE="${CACHE_DIR}/$(echo ${IMG##*/} | tr ':' '-')".tar
    [ -f "$FILE" ] || continue

    scp -P "$SSH_PORT" "$FILE" "${SSH_USER}@${NODE}:${CACHE_DIR}/" >/dev/null \
      && ok "已分发 $FILE" \
      || warn "分发失败 $FILE"
  done
done

echo
echo "🛠 加载镜像到 containerd..."

for NODE in "${ALL_NODES[@]}"; do
  echo ">>> 加载节点 $NODE"

  for IMG in "${IMGS[@]}"; do
    FILE="${CACHE_DIR}/$(echo ${IMG##*/} | tr ':' '-')".tar

    CMD="if [ -f '${FILE}' ]; then ctr -n k8s.io images import '${FILE}' >/dev/null 2>&1 && echo '✔ load $(basename $FILE)' || echo '✘ load 失败 $(basename $FILE)'; else echo '✘ 缺少 $(basename $FILE)'; fi"

    if [[ "$NODE" == "$(hostname -I | awk '{print $1}')" ]]; then
      eval "$CMD"
    else
      ssh -p "$SSH_PORT" "${SSH_USER}@${NODE}" "$CMD"
    fi
  done
done

echo
echo "📄 生成 calico.yaml..."

CALICO_YAML="${CACHE_DIR}/calico.yaml"

curl -sSL https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml -o "$CALICO_YAML"

# 替换镜像路径（使用你本地 containerd namespace）
for IMG in "${IMGS[@]}"; do
  NAME_TAG="${IMG##*/}"             # node:v3.27.2
  NAME="${NAME_TAG%:*}"             # node
  TAG="${NAME_TAG##*:}"             # v3.27.2

  # Calico manifest 中原始字段: image: docker.io/calico/node:v3.27.2
#   sed -i "s#docker.io/calico/${NAME}:${TAG}#localhost/${NAME}:${TAG}#g" "$CALICO_YAML"
done

ok "calico.yaml 已生成：$CALICO_YAML"
echo "🎉 Calico 离线准备完成！"

