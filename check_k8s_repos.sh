#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 脚本名称：check_k8s_repos.sh
# 功能：自动检测K8S apt源可达性、列出版本、验证K8S_VERSION是否完整可用
# 适用于Ubuntu 20.04 / 22.04
# ============================================================

# ====== 用户配置 ======
K8S_VERSION="1.30.4-1.1"

# 候选Kubernetes APT源列表（可自动补全）
declare -A K8S_REPOS=(
  ["Aliyun"]="https://mirrors.aliyun.com/kubernetes/apt"
  ["Official"]="https://pkgs.k8s.io/core:/stable:/v1.30/deb/"
  ["USTC"]="https://mirrors.ustc.edu.cn/kubernetes/apt"
  ["Tsinghua"]="https://mirrors.tuna.tsinghua.edu.cn/kubernetes/apt"
  ["Azure"]="https://packages.cloud.google.com/apt"
)

# ====== 检查命令依赖 ======
for cmd in curl apt-cache grep awk; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "❌ 缺少命令：$cmd，请先安装它"; exit 1;
  }
done

TMP_DIR="/tmp/k8s_repo_check"
mkdir -p "$TMP_DIR"

echo -e "\033[1;34m[INFO]\033[0m 开始检测K8S APT源..."
echo "目标版本: ${K8S_VERSION}"
echo

# ============================================================
# 函数定义
# ============================================================

check_repo_reachable() {
  local name="$1" url="$2"
  if curl -Is --max-time 3 "${url}" >/dev/null 2>&1; then
    echo "✅ ${name} (${url}) 可达"
    return 0
  else
    echo "⚠️  ${name} (${url}) 不可达"
    return 1
  fi
}

test_repo_versions() {
  local name="$1" url="$2"
  local list_file="${TMP_DIR}/${name}.list"
  local keyring="/etc/apt/keyrings/kubernetes-${name}.gpg"

  # 清理旧list
  rm -f "$list_file"

  # 写入临时APT源
  echo "deb [trusted=yes] ${url} /" > "$list_file"

  # 尝试更新
  apt-get update -o Dir::Etc::sourcelist="$list_file" -o Dir::Etc::sourceparts="-" \
    -o APT::Get::List-Cleanup="0" >/dev/null 2>&1 || {
      echo "⚠️  ${name} 更新失败，跳过"
      return 1
    }

  echo "🔍 检查 ${name} 可用版本："
  local pkgs=(kubeadm kubelet kubectl cri-tools)
  local all_ok=true
  for pkg in "${pkgs[@]}"; do
    local version_list
    version_list=$(apt-cache madison "$pkg" 2>/dev/null | awk '{print $3}' || true)
    if [[ -z "$version_list" ]]; then
      echo "  ❌ ${pkg} 未在源中找到"
      all_ok=false
      continue
    fi
    echo "  📦 ${pkg} 可用版本: $(echo "$version_list" | head -n 3 | paste -sd ',')"

    if echo "$version_list" | grep -q "${K8S_VERSION}"; then
      echo "     ✅ 含目标版本 ${K8S_VERSION}"
    else
      echo "     ⚠️  未找到 ${K8S_VERSION}"
      all_ok=false
    fi
  done

  if $all_ok; then
    echo -e "\033[1;32m✅ ${name} 源满足全部包版本要求！\033[0m"
  else
    echo -e "\033[1;33m⚠️  ${name} 源缺少部分包版本。\033[0m"
  fi
  echo
}

# ============================================================
# 主执行逻辑
# ============================================================

for name in "${!K8S_REPOS[@]}"; do
  url="${K8S_REPOS[$name]}"
  echo "------------------------------------------------------------"
  if check_repo_reachable "$name" "$url"; then
    test_repo_versions "$name" "$url"
  fi
done

echo "------------------------------------------------------------"
echo -e "\033[1;34m[INFO]\033[0m 检测完成。可根据上方结果选择最佳源。"
