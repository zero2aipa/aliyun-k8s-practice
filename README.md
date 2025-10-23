# aliyun-k8s-practice-

# Kubernetes 集群初始化执行手册（顺序/目的/节点）

> 适用脚本（已就绪）  
> `00_cluster.env*` `01_common_bootstrap.sh*` `02_cache_and_sync.sh*` `03_prepare_node.sh*`  
> `04_containerd_k8s.sh*` `05_k8s_fix_and_init.sh*` `06_network_plugin_install.sh*`  
> `check_prepare_node_status.sh*`

---

## TL;DR（首次全新部署顺序）

1. **编辑全局变量**（所有 IP、密码、版本）
   - **节点**：`cp-1`
   - **命令**：`nano 00_cluster.env`
   - **目的**：统一配置（语言、时区、K8S 版本、镜像仓库、节点清单、缓存目录等）

2. **基础环境/免交互/sshpass/互信**
   - **节点**：`cp-1`（自动分发密钥到所有节点）
   - **命令**：`bash 01_common_bootstrap.sh`
   - **目的**：语言/时区一致、安装 sshpass、免交互 APT、建立 SSH 互信

3. **离线包下载 + 分发 + 本地优先安装**
   - **节点**：`cp-1` 触发，远端在 **所有节点** 安装
   - **命令**：`bash 02_cache_and_sync.sh`
   - **目的**：在 cp-1 下载各类 `.deb` 到缓存目录并 **scp** 到所有节点；远端优先用缓存安装，缺失再在线补齐

4. **OS 内核/网络前置（必须执行）**
   - **节点**：**所有节点（cp-1 + wk***）**
   - **命令**：`bash 03_prepare_node.sh`
   - **目的**：禁用 swap、关闭 ufw/firewalld、加载 `overlay/br_netfilter`、设置 `sysctl`、启用 chrony

5. **容器运行时与 K8S 组件（版本锁定可选）**
   - **节点**：**所有节点**
   - **命令**：`bash 04_containerd_k8s.sh`
   - **目的**：安装并配置 containerd（SystemdCgroup=true、国内 pause 镜像/加速），安装并 hold `kubelet/kubeadm/kubectl`

6. **初始化控制平面 + 分发镜像 + 自动加入集群**
   - **节点**：**仅 cp-1**
   - **命令**：`bash 05_k8s_fix_and_init.sh`
   - **目的**：`kubeadm init`（指定 **稳定 K8S 版本**），在 cp-1 拉取/导出 **核心镜像**，分发到 worker 并远端 `ctr import`，执行 `join.sh` 加入集群

7. **网络插件部署 + 镜像分发加载（Calico/Flannel）**
   - **节点**：**仅 cp-1**
   - **命令**：`bash 06_network_plugin_install.sh calico`（或 `flannel`）
   - **目的**：下载 YAML；从 YAML 解析所有镜像 → cp-1 拉取并导出 → 分发给所有 worker → 远端 `ctr import` → `kubectl apply` 部署网络

8. **一致性与合规检查（可反复执行）**
   - **节点**：`cp-1`
   - **命令**：`bash check_prepare_node_status.sh`
   - **目的**：批量检查 **swap/sysctl/modules/chrony/firewall** 是否达标；用于复核第 3 步脚本（OS 前置）是否已执行到位

---

## 分步明细（一览表）

| 顺序 | 脚本名 | 目的 | 作用范围 | 执行节点 | 关键输出/副作用 |
|---|---|---|---|---|---|
| 0 | `00_cluster.env` | 统一参数/节点清单/版本/镜像仓库/缓存路径 | 全局 | `cp-1` 编辑 | 所有脚本 `source` 使用 |
| 1 | `01_common_bootstrap.sh` | 语言/时区/sshpass/免交互，生成 SSH key，分发互信 | 基础设施 | `cp-1` 运行 | 所有节点可免密 SSH |
| 2 | `02_cache_and_sync.sh` | 在 `cp-1` 下载 `.deb` → 分发到各节点 → 远端本地优先安装 | 包分发/离线优先 | `cp-1` 触发（远端全节点执行安装） | `/opt/k8s-pkg-cache/` 缓存目录 |
| 3 | `03_prepare_node.sh` | 关闭 swap/防火墙、加载模块、设 sysctl、启用 chrony | OS 前置必备 | **所有节点** | `sysctl` 生效、重启内核参数；chrony 运行 |
| 4 | `04_containerd_k8s.sh` | 配置 containerd（SystemdCgroup/pause/镜像加速），安装并 hold kubelet/kubeadm/kubectl | 运行时/工具链 | **所有节点** | containerd/kubelet 运行；版本可锁定 |
| 5 | `05_k8s_fix_and_init.sh` | `kubeadm init`（**指定 K8S 稳定版本**），导出/分发**核心镜像**至 worker 并远端加载，自动 `join` | 集群诞生/镜像分发 | **仅 cp-1** | `/opt/k8s-image-cache/*.tar`、`join.sh` |
| 6 | `06_network_plugin_install.sh` | 解析 YAML → 拉取/导出 **Calico/Flannel 镜像** → 分发到 worker 并加载 → `kubectl apply` | CNI 网络 | **仅 cp-1** | 所有网元镜像已本地化；Pod 可启动 |
| 7 | `check_prepare_node_status.sh` | swap/sysctl/modules/firewall/chrony 批量巡检 | 健康验证 | `cp-1` | 逐节点 ✅/❌ 扫描报告 |

---

## 关键参数与依赖关系

- **版本锁定**：在 `00_cluster.env` 设置 `K8S_VERSION="1.30.4-00"`（或期望版本）；`04` 与 `05` 脚本会据此安装/初始化  
- **镜像分发路径**：统一使用 `/opt/k8s-image-cache/`（由 `05` 与 `06` 生成并分发、worker 端自动 `ctr import`）  
- **离线包缓存**：`/opt/k8s-pkg-cache/`（由 `02` 下载 `.deb` 并分发，worker 端优先本地安装）  
- **网络要求**：外网只需 **cp-1** 可访问（拉镜像/拉 YAML）；worker 可离线  
- **先决条件**：`03_prepare_node.sh` **必须在所有节点执行**，否则 kubelet/网络插件可能异常  
- **幂等性**：所有脚本支持重复执行，已存在配置会跳过或覆盖到期望状态

---

## 常用验证命令（按阶段）

- **节点 OS 前置（执行 `03` 后）**
  - `swapon --show` → 无输出（swap 关闭）
  - `sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables` → 全为 `1`
  - `lsmod | egrep 'overlay|br_netfilter'` → 均存在
  - `systemctl is-active chrony` → `active`

- **运行时与工具链（执行 `04` 后）**
  - `systemctl is-active containerd` → `active`
  - `systemctl is-active kubelet` → `active`
  - `crictl version` / `ctr version` / `kubeadm version`

- **控制平面初始化（执行 `05` 后，cp-1）**
  - `kubectl get nodes -o wide` → 至少 `cp-1` 出现
  - `ls /opt/k8s-image-cache/*.tar` → 镜像包存在
  - Worker 节点：`ctr -n k8s.io images ls | grep pause` → 已加载

- **网络插件部署（执行 `06` 后）**
  - `kubectl get pods -n kube-system -o wide | egrep 'calico|flannel'` → Pod Running/Ready
  - `kubectl get nodes` → 所有节点 `Ready`

---

## 典型问题与处理

- **Worker NotReady / NetworkUnavailable**  
  → 确认第 `06` 步已执行；检查 CNI Pod 是否就绪；确认镜像已在 worker 导入

- **kubeadm init 报 swap 错**  
  → 说明第 `03` 步未执行或失败；在所有节点重新 `bash 03_prepare_node.sh`

- **apt 安装失败/版本不一致**  
  → 使用 `02` 统一缓存分发；在 `00_cluster.env` 固定 `K8S_VERSION` 并重新执行 `04`

---

## 建议的再次执行顺序（已有部分执行过）

1. 所有节点：`bash 03_prepare_node.sh`（确保到位）  
2. 所有节点：`bash 04_containerd_k8s.sh`  
3. **cp-1**：`bash 05_k8s_fix_and_init.sh`  
4. **cp-1**：`bash 06_network_plugin_install.sh calico`  
5. **cp-1**：`bash check_prepare_node_status.sh`（健康巡检）

> 完成后：`kubectl get nodes -o wide` 应显示 `cp-1` + 所有 `wk-*` 均为 `Ready`。

---
