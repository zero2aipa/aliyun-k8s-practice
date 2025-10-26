check_k8s_pkg_and_service.sh#!/usr/bin/env bash
set -euo pipefail

# ========== 配置 ==========
PACKAGES=(
  chrony
  containerd
  cri-tools
  kubelet
  kubeadm
  kubectl
)

echo "==============================="
echo "🔍 检查包安装状态和服务运行情况"
echo "==============================="

# ---------- 检查包安装 ----------
for p in "${PACKAGES[@]}"; do
  echo -e "\n🧩 包: \033[1;34m$p\033[0m"
  if dpkg -l | grep -q "^ii\s\+$p"; then
    ver=$(dpkg -l | grep "^ii\s\+$p" | awk '{print $3}')
    echo "✅ 已安装，版本: $ver"
  else
    echo "❌ 未安装"
    continue
  fi

  # ---------- 检查服务 ----------
  # 只有部分包有 systemd 服务
  case "$p" in
    chrony|containerd|kubelet)
      echo "🧠 检查 systemd 服务状态..."
      if systemctl list-unit-files | grep -q "^${p}\.service"; then
        systemctl --no-pager --quiet is-active "$p" && status="active" || status="inactive"
        echo "   服务状态: $status"
        echo "🪵 最近日志（最后 50 行）:"
        echo "----------------------------------------"
        sudo journalctl -u "$p" -n 50 --no-pager || echo "(无日志)"
        echo "----------------------------------------"
      else
        echo "⚠️  没有发现 ${p}.service"
      fi
      ;;
    *)
      echo "（该包不提供 systemd 服务）"
      ;;
  esac
done

echo -e "\n✅ 检查完成。"
