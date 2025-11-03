#!/usr/bin/env bash
# ===============================================================
# 卸载 Kubernetes + Containerd 并清理所有残留
# ===============================================================
set -euo pipefail

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()   { echo -e "\033[1;32m✅ $*\033[0m"; }
warn() { echo -e "\033[1;33m⚠️  $*\033[0m"; }

wait_for_apt_lock() {
  local timeout=90 waited=0
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
        fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    (( waited++ ))
    (( waited > timeout )) && warn "APT 锁超时，强制继续" && break
    echo -ne "\r等待 apt 锁释放中... $waited s"
    sleep 1
  done
  echo
}

# ------------------ 停止服务 ------------------
info "停止 Kubernetes 与 Containerd 服务..."
systemctl disable --now kubelet 2>/dev/null || true
systemctl disable --now containerd 2>/dev/null || true
systemctl disable --now cri-dockerd 2>/dev/null || true
ok "服务已停止"

# ------------------ 卸载组件 ------------------
wait_for_apt_lock
info "卸载 Kubernetes 包..."
apt-get remove -y kubelet kubeadm kubectl cri-tools kubernetes-cni || true
apt-get purge  -y kubelet kubeadm kubectl cri-tools kubernetes-cni || true
ok "Kubernetes 包已卸载"

wait_for_apt_lock
info "卸载 Containerd 及依赖（保留 libseccomp2）..."
apt-get remove -y containerd runc bridge-utils || true
apt-get purge  -y containerd runc bridge-utils || true
ok "Containerd 已卸载"

wait_for_apt_lock
info "卸载系统辅助工具..."
apt-get remove -y sshpass conntrack ebtables socat ipset bash-completion || true
apt-get purge  -y sshpass conntrack ebtables socat ipset bash-completion || true
ok "辅助工具已卸载"

# ------------------ 删除残留文件 ------------------
info "清理残留文件与目录..."
rm -rf \
  /etc/kubernetes /var/lib/kubelet /var/lib/etcd \
  /var/lib/containerd /etc/containerd \
  /opt/cni /etc/cni /var/lib/cni \
  /usr/local/bin/crictl /usr/local/bin/ctr \
  /usr/bin/kubeadm /usr/bin/kubectl /usr/bin/kubelet \
  /root/.kube \
  /opt/k8s-pkg-cache /opt/k8s-pkg-cache-full

# systemd service 文件彻底删除
rm -f /etc/systemd/system/kubelet.service* \
      /etc/systemd/system/containerd.service* \
      /lib/systemd/system/kubelet.service \
      /lib/systemd/system/containerd.service
systemctl daemon-reload
ok "目录与服务文件已清理"

# ------------------ 清理网络 ------------------
info "重置 CNI 网络..."
ip link delete cni0 2>/dev/null || true
ip link delete flannel.1 2>/dev/null || true
rm -rf /etc/cni/net.d /var/lib/cni /run/flannel
ok "网络已重置"

# ------------------ 清理 APT 源与缓存 ------------------
wait_for_apt_lock
info "清理 APT 源与缓存..."
rm -f /etc/apt/sources.list.d/kubernetes.list
sed -i '/pkgs.k8s.io/d' /etc/apt/sources.list || true
apt-get autoremove -y >/dev/null 2>&1 || true
apt-get clean >/dev/null 2>&1
ok "APT 缓存已清理"

# ------------------ 最终检查 ------------------
info "验证残留..."
dpkg -l | grep -E 'kube|containerd|cri-tools' && warn "仍检测到包残留！" || ok "所有包已清理"
systemctl list-unit-files | grep -E 'kube|containerd' && warn "仍有 systemd 单元残留！" || ok "无服务残留"

ok "系统已彻底清理 Kubernetes + Containerd 环境"
echo
echo "✨ 建议执行: reboot"

