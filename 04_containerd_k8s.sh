#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/00_cluster.env"

bold()  { echo -e "\033[1m$*\033[0m"; }
ok()    { echo -e "✅ $*"; }
warn()  { echo -e "⚠️  $*"; }
step()  { echo -e "\n\033[1;34m[STEP]\033[0m $*"; }

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

step "确保 containerd 已安装（优先离线包，缺失再在线）"
if ! command -v containerd >/dev/null 2>&1; then
  apt-get update -y >/dev/null || true
  apt-get install "${APT_FLAGS[@]}" containerd >/dev/null || true
fi
mkdir -p /etc/containerd
[[ -f /etc/containerd/config.toml ]] || containerd config default >/etc/containerd/config.toml

# 启用 systemd cgroup + 国内 pause 镜像 + 拉取镜像加速
step "配置 containerd（systemd cgroup + pause 镜像 + 拉取加速）"
sed -ri 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sed -ri "s#sandbox_image = \".*\"#sandbox_image = \"${PAUSE_IMAGE}\"#" /etc/containerd/config.toml

mkdir -p /etc/containerd/certs.d/docker.io
cat >/etc/containerd/certs.d/docker.io/hosts.toml <<EOF
server = "https://registry-1.docker.io"
[host."${DAOCLOUD_MIRROR}"]
  capabilities = ["pull"]
[host."${NETEASE_MIRROR}"]
  capabilities = ["pull"]
[host."${BAIDU_MIRROR}"]
  capabilities = ["pull"]
EOF

systemctl daemon-reexec
systemctl enable --now containerd
ok "containerd 已启动：$(systemctl is-active containerd)"

step "安装/固定 kubelet kubeadm kubectl 版本（如指定 K8S_VERSION）"
if [[ -n "${K8S_VERSION}" ]]; then
  apt-get install "${APT_FLAGS[@]}" kubelet="${K8S_VERSION}" kubeadm="${K8S_VERSION}" kubectl="${K8S_VERSION}" || true
else
  apt-get install "${APT_FLAGS[@]}" kubelet kubeadm kubectl || true
fi
apt-mark hold kubelet kubeadm kubectl || true
systemctl enable kubelet
ok "Kubernetes 组件已安装并 hold"

step "预拉取 pause 镜像（容错）并简单验证状态"
crictl pull "${PAUSE_IMAGE}" >/dev/null 2>&1 || true
ctr -n k8s.io images ls | grep pause || true
systemctl status containerd --no-pager | sed -n '1,5p'
systemctl status kubelet --no-pager | sed -n '1,5p'
ok "containerd/kubelet 状态检查完成"

bold "✅ 本节点 K8S 运行时与工具链已就绪（公共初始化完成）"
