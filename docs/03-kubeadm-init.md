# 第 03 章 · kubeadm init：一条命令建起控制面，再一层层拆开看

## 🎯 本章目标

1. 搞懂 control plane 由哪几个组件组成，它们之间怎么协作
2. 读懂 kubeadm 的配置文件（v1beta4），先预演（dry-run），再用**一条命令**建起控制面
3. 对照 init 的输出，**按阶段"考古"**：它生成了哪些证书、哪些 kubeconfig、哪些 static pod，kubelet 又是怎么从重启循环里"活过来"的
4. 弄明白两件事：节点为什么是 `NotReady`？CoreDNS 为什么是 `Pending`？
5. 认识第一批 K8s 对象：Node、Pod、Deployment、DaemonSet、ConfigMap、CSR……

大约需要 **2.5 小时**，全程只在 **cp-1** 上操作。worker 第 05 章再加入。

> 开始之前，💻 **Mac：** 如果机器是停着的，先 `./scripts/lab-up.sh`；再用 `./scripts/status.sh` 确认 SSM 全部 `Online`。

---

## 🧠 概念 1：control plane 全景

```
                         你：kubectl ...
                              │ HTTPS（带着你的证书）
                              ▼
 ┌─────────────────────── control plane（cp-1）─────────────────────────┐
 │                                                                      │
 │   ┌──────┐        ┌────────────────┐        ┌─────────────────────┐  │
 │   │ etcd │ ◄────► │ kube-apiserver │ ◄───── │ kube-scheduler       │  │
 │   │ 数据库│        │  唯一的"大门"   │        │ 决定 Pod 放哪个节点   │  │
 │   └──────┘        └────────────────┘ ◄───── │ kube-controller-     │  │
 │                      ▲          ▲           │ manager：各种"对账员" │  │
 │                      │          │           └─────────────────────┘  │
 └──────────────────────┼──────────┼────────────────────────────────────┘
                        │          │
              每个节点上的 kubelet、kube-proxy，也都只找 apiserver
```

| 组件 | 干什么 | 打个比方 |
|---|---|---|
| **kube-apiserver** | 集群唯一的入口。所有读写请求都要先经过它的认证（你是谁）、授权（你能干什么）、校验，再存进 etcd | 前台 + 档案室管理员 |
| **etcd** | 一个分布式键值数据库，保存集群的**全部状态**：有哪些 Pod、哪些 Service、配置、Secret…… | 档案室 |
| **kube-scheduler** | 发现"有 Pod 还没分配节点"，就挑一个合适的节点，把结果写回 apiserver | 排班员 |
| **kube-controller-manager** | 几十个"控制器"的合集，每个负责一类对象，不停地把"实际状态"往"期望状态"拉 | 一群对账员 |
| **kubelet** | 每个节点上的代理人（第 02 章装的），领任务、跑容器、汇报状态 | 各地分店店长 |
| **kube-proxy** | 每个节点上，把 Service 的虚拟 IP 翻译成真实 Pod 的地址（第 08 章细讲） | 电话总机 |
| **CoreDNS** | 集群内部的 DNS，让 Pod 能用名字找到 Service | 通讯录 |

**最重要的一条规则：只有 apiserver 能碰 etcd，其他所有组件都只和 apiserver 对话。** 组件之间从不直接通信，而是都去 apiserver 那里"看公告、写公告"。

### 期望状态与对账

K8s 的工作方式和你熟悉的"执行命令"不一样：

- 你不是说"去启动 3 个 nginx"，而是声明"**我希望**一直有 3 个 nginx"。这句话被 apiserver 存进 etcd，就是**期望状态**。
- 控制器在一个无限循环里不停地对账：看看**实际状态**（现在有几个）→ 和期望比 → 少了就补、多了就删 → 再看……
- 某个 nginx 挂了？不需要谁"处理故障"，下一轮对账自然就把它补回来。

这个"声明期望 + 不停对账"的模式贯穿整个 K8s，第 07 章会专门讲。今天你会在几个地方看到它的影子。

---

## 🧠 概念 2：鸡生蛋问题，static pod

kubeadm 搭的集群里，apiserver、etcd、scheduler、controller-manager **本身也是以 Pod 的形式运行的**。

这就出现了一个鸡生蛋的问题：正常的 Pod 要先写进 apiserver，再由 scheduler 分配节点，最后由 kubelet 启动。可现在 apiserver 自己还不存在，谁来启动它？

答案是 **static pod（静态 Pod）**：

```
   /etc/kubernetes/manifests/          kubelet 盯着这个目录
   ├── etcd.yaml                  ──►  发现一个文件，就直接启动一个 Pod
   ├── kube-apiserver.yaml        ──►  文件删了，Pod 就停掉
   ├── kube-controller-manager.yaml    文件改了，Pod 就重建
   └── kube-scheduler.yaml
                                       完全不需要 apiserver！
```

kubeadm 只需要把这 4 个文件写进目录，kubelet 就会把控制面一个个拉起来。apiserver 起来之后，kubelet 再在 apiserver 里给每个 static pod 登记一个"影子"（mirror pod），这样 `kubectl get pods` 也能看到它们。

---

## 🧠 概念 3：证书就是身份

K8s 里几乎所有通信都是**双向 TLS（mTLS）**：不光客户端要验证服务端的证书，服务端也要验证客户端的证书。

而且，**客户端证书本身就是身份证**：

```
   证书里的 Subject：  O = kubeadm:cluster-admins,  CN = kubernetes-admin
                        └─ 组（Group）                └─ 用户名（User）
```

apiserver 只要验证"这张证书是我信任的 CA 签的"，就知道你是谁、属于哪个组，然后再按组和用户名去查权限（RBAC，第 16 章细讲）。K8s **没有用户数据库**，谁手里有 CA 签过的证书，谁就是证书上写的那个人。

kubeadm 会建 **3 个 CA**，外加一对密钥：

| CA / 密钥 | 签给谁 | 用途 |
|---|---|---|
| `ca`（集群 CA） | apiserver、kubelet、admin、controller-manager、scheduler…… | 集群里绝大多数身份 |
| `etcd/ca` | etcd 自己、apiserver 访问 etcd 用的客户端证书 | etcd 单独一套，和集群 CA 隔离 |
| `front-proxy-ca` | apiserver 转发请求给扩展 API 时用 | 第 14 章 metrics-server 会用到 |
| `sa.key` / `sa.pub` | 不是 CA，是一对密钥 | 给 ServiceAccount（Pod 的身份）签发 token |

> 📌 先记住一点：**kubelet 手里有两张证书**。一张是**客户端证书**，用来向 apiserver 证明"我是节点 ip-10-0-10-11"（步骤 8）；另一张是**服务端证书**，apiserver 反过来访问 kubelet（比如查看容器日志）时用来证明"我真的是这个节点"（步骤 15）。

---

## 🧠 概念 4：先认识几个词

今天会第一次见到这些对象，先有个印象就行，后面每个都有专门的章节：

| 词 | 一句话解释 |
|---|---|
| **Node** | 集群里的一台机器（cp-1、worker-1……） |
| **Pod** | K8s 调度的最小单位：一个或几个共享网络的容器 |
| **Namespace** | 给对象分组的"文件夹"。系统组件都在 `kube-system` 里 |
| **Deployment** | "我要 N 个一模一样的 Pod"，由控制器保证数量（CoreDNS 就是） |
| **DaemonSet** | "每个节点上都要有一个这样的 Pod"（kube-proxy 就是） |
| **Service / ClusterIP** | 一组 Pod 的固定访问入口，有一个虚拟 IP |
| **ConfigMap** | 存配置的对象，一堆键值对 |
| **label** | 贴在对象上的标签，比如 `node-role.kubernetes.io/control-plane` |
| **taint / toleration** | 节点上的"禁止入内"牌子 / Pod 身上的"通行证" |
| **CSR** | 证书签名请求：申请让集群 CA 签一张证书 |

---

## 🛠 动手 A：写配置，先预演

### 步骤 1：写 kubeadm 配置文件

💻 **Mac：**

```bash
cd ~/Desktop/code/K8s-learning
./scripts/ssm.sh cp-1
```

🖥️ **cp-1：**

```bash
sudo -i          # 本章全程用 root：kubeadm、crictl、读证书目录都需要 root 权限
```

把下面整段粘贴进去（仓库里也有一份一模一样的：`manifests/ch03-kubeadm-init/kubeadm-config.yaml`）：

🖥️ **cp-1（root）：**

```bash
cat > /root/kubeadm-config.yaml <<'EOF'
# kubeadm 配置（第 03 章）。只写"和默认值不同"或"需要固定住"的项。
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
clusterName: k8s-lab
kubernetesVersion: v1.36.6                  # 固定版本，和第 02 章预拉的镜像一致
controlPlaneEndpoint: api.k8s.internal:6443 # 集群的"门牌号"，第 11 章扩 HA 全靠它
networking:
  podSubnet: 192.168.0.0/16                 # Pod 的 IP 池，第 04 章 Calico 用同一个
  serviceSubnet: 10.96.0.0/12               # Service 的 IP 池（就是默认值，写出来固定住）
controllerManager:
  extraArgs:
    - name: bind-address                    # 指标端口对外监听，第 14 章 Prometheus 要来抓
      value: 0.0.0.0
scheduler:
  extraArgs:
    - name: bind-address
      value: 0.0.0.0
etcd:
  local:
    extraArgs:
      - name: listen-metrics-urls
        value: http://0.0.0.0:2381
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
serverTLSBootstrap: true                    # kubelet 的 HTTPS 证书由集群 CA 签发（步骤 15）
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: iptables                              # 现在就是默认值，固定住，第 08 章要看它生成的规则
metricsBindAddress: 0.0.0.0:10249           # 同样是给第 14 章抓指标用
EOF
```

一个文件里有 3 段（用 `---` 隔开），分别配置 3 个程序：

| 段 | 配置的是谁 |
|---|---|
| `ClusterConfiguration` | 整个集群：版本、地址、网段、控制面组件的参数 |
| `KubeletConfiguration` | 每个节点上的 kubelet |
| `KubeProxyConfiguration` | 每个节点上的 kube-proxy |

逐项解读。原则是"**只写和默认值不同的，或者需要固定住的**"，所以每一项都能说出它属于哪一类：

| 配置项 | 类别 | 为什么 |
|---|---|---|
| `kubernetesVersion: v1.36.6` | 固定住 | 不写的话，kubeadm 会上网查"最新稳定版"，可能装成比预拉镜像更新的版本 |
| `clusterName: k8s-lab` | 改默认值 | 默认叫 `kubernetes`。这个名字会出现在 kubeconfig 里 |
| `controlPlaneEndpoint` | 改默认值 | **最重要的一行**。不写的话，所有组件都会记住 cp-1 的 IP；写成域名，第 11 章扩 HA 时只改 DNS（见第 01 章深入原理 1） |
| `podSubnet: 192.168.0.0/16` | 改默认值 | 默认不分配 Pod 网段。必须和第 04 章 Calico 的配置一致，并且不能和 VPC（10.0.0.0/16）重叠 |
| `serviceSubnet: 10.96.0.0/12` | 固定住 | 就是默认值，显式写出来，免得以后"默认值变了"自己还不知道 |
| `bind-address`、`listen-metrics-urls`、`metricsBindAddress` | 为第 14 章准备 | 这几个组件的指标端口默认只监听 127.0.0.1，Prometheus 从别的机器上抓不到。现在改好，省得以后去改正在运行的控制面。⚠️ 第 14 章还要给安全组补上对应端口的规则 |
| `serverTLSBootstrap: true` | 改默认值 | 默认 kubelet 用自己签的证书，apiserver 和 metrics-server 无法验证它。打开后由集群 CA 签发（代价是要人工批准，步骤 15） |
| `mode: iptables` | 固定住 | 现在就是默认值。较新的 nftables 模式已经 GA，默认值将来可能会变，而第 08 章要专门看 iptables 规则 |

**没写的东西**也值得一提：

- **节点 IP 和节点名**：kubeadm 自动取默认路由网卡的 IP（10.0.10.11）和主机名（ip-10-0-10-11）。不写死，这份配置就和具体的机器无关。
- **apiserver 证书的额外域名（certSANs）**：kubeadm 会自动把 `controlPlaneEndpoint` 里的 `api.k8s.internal` 加进证书。
- **CRI socket**：kubeadm 会自动探测到 containerd。

### 步骤 2：校验配置

🖥️ **cp-1（root）：**

```bash
kubeadm config validate --config /root/kubeadm-config.yaml
```

输出 `ok` 就对了。如果有拼写错误（比如把 `extraArgs` 写成 `extraArg`），它会明确指出是哪一行。

想知道"默认值"到底是什么，可以让 kubeadm 打印一份完整的默认配置，略看一下就行：

```bash
kubeadm config print init-defaults | head -45
```

注意里面的 `advertiseAddress: 1.2.3.4`、`name: node`、`token: abcdef.0123456789abcdef`，这些都是**占位值**。这份输出是"模板"，不能直接拿来用。

### 步骤 3：预演（dry-run）

`--dry-run` 会把 init 完整地走一遍，但**不改动系统**：证书、kubeconfig、manifest 都写到一个临时目录里，要调用 apiserver 的操作只打印出来。

🖥️ **cp-1（root）：**

```bash
KUBEADM_INIT_DRYRUN_DIR=/root/dryrun \
  kubeadm init --config /root/kubeadm-config.yaml --dry-run > /root/dryrun.log 2>&1
echo "退出码 $?"
wc -l /root/dryrun.log           # 一千多行
```

- `KUBEADM_INIT_DRYRUN_DIR` 指定临时文件写到哪。不指定的话会写到 `/etc/kubernetes/tmp/` 下面，跟真正的文件混在一起，后面考古时容易看花眼。
- `2>&1` 把错误输出也存进文件，有些重要的信息是从错误输出里打印的。

看看 init 要经过哪些阶段：

```bash
grep -oE '^\[[a-z-]+\]' /root/dryrun.log | grep -v dryrun | uniq
```

```
[init]
[preflight]
[certs]
[kubeconfig]
[etcd]
[control-plane]
[kubelet-start]
[patches]
[kubelet-start]
[wait-control-plane]
...
```

这就是下面要"考古"的路线图。再看看它准备生成哪些文件：

```bash
ls /root/dryrun
grep -A3 'apiserver serving cert' /root/dryrun.log | head -2
```

最后一定要注意 dry-run 的结尾：

```bash
tail -n 25 /root/dryrun.log
```

> ⚠️ 结尾会打印 `Your Kubernetes control-plane has initialized successfully!`，还有一句 `sudo cp -i /root/dryrun/admin.conf $HOME/.kube/config`。**这些都是假的，不要照着执行。** 预演完的集群并不存在。

预演确认没问题，删掉临时目录。里面有一套"假的"CA 证书，留着只会让人困惑：

```bash
rm -rf /root/dryrun /root/dryrun.log
```

---

## 🛠 动手 B：kubeadm init

### 步骤 4：执行 init

🖥️ **cp-1（root）：**

```bash
kubeadm init --config /root/kubeadm-config.yaml 2>&1 | tee /root/kubeadm-init.log
```

`tee` 让输出一边显示在屏幕上，一边存进文件，方便以后回头看。大约 30 秒到 1 分钟就能完成（镜像第 02 章已经预拉好了）。

> 💡 如果中途 SSM 断线，init 可能只做了一半。不要直接重跑，先看本章末尾的「🧯 附录：init 失败了怎么办」。

输出很长，下面是精简后的样子（`...` 表示省略的行）。**每一段开头方括号里的就是阶段名**，旁边标出了后面哪一步会去"考古"它：

```
[init] Using Kubernetes version: v1.36.6
[preflight] Running pre-flight checks                                   ← 预检：swap、端口、内核参数……
[preflight] Pulling images required for setting up a Kubernetes cluster

[certs] Using certificateDir folder "/etc/kubernetes/pki"               ← 步骤 7
[certs] Generating "ca" certificate and key
[certs] Generating "apiserver" certificate and key
[certs] apiserver serving cert is signed for DNS names [api.k8s.internal ip-10-0-10-11 kubernetes
        kubernetes.default kubernetes.default.svc kubernetes.default.svc.cluster.local] and IPs [10.96.0.1 10.0.10.11]
...
[certs] Generating "sa" key and public key

[kubeconfig] Using kubeconfig folder "/etc/kubernetes"                  ← 步骤 8
[kubeconfig] Writing "admin.conf" kubeconfig file
[kubeconfig] Writing "super-admin.conf" kubeconfig file
...

[etcd] Creating static Pod manifest for local etcd in "/etc/kubernetes/manifests"     ← 步骤 9
[control-plane] Creating static Pod manifest for "kube-apiserver"
...

[kubelet-start] Writing kubelet environment file with flags to file "/var/lib/kubelet/kubeadm-flags.env"   ← 步骤 10
[kubelet-start] Writing kubelet configuration to file "/var/lib/kubelet/instance-config.yaml"
[patches] Applied patch of type "application/strategic-merge-patch+json" to target "kubeletconfiguration"
[kubelet-start] Writing kubelet configuration to file "/var/lib/kubelet/config.yaml"
[kubelet-start] Starting the kubelet

[wait-control-plane] Waiting for the kubelet to boot up the control plane as static Pods ...           ← 步骤 11
[kubelet-check] Waiting for a healthy kubelet at http://127.0.0.1:10248/healthz. This can take up to 4m0s
[kubelet-check] The kubelet is healthy after 501.6ms
[control-plane-check] Checking kube-apiserver at https://10.0.10.11:6443/livez
[control-plane-check] Checking kube-controller-manager at https://0.0.0.0:10257/healthz
[control-plane-check] Checking kube-scheduler at https://0.0.0.0:10259/livez
...
[control-plane-check] kube-apiserver is healthy after 3.5s

[upload-config] Storing the configuration used in ConfigMap "kubeadm-config" in the "kube-system" Namespace   ← 步骤 13
[kubelet] Creating a ConfigMap "kubelet-config" in namespace kube-system with the configuration for the kubelets
[upload-certs] Skipping phase. Please see --upload-certs
[mark-control-plane] Marking the node ip-10-0-10-11 as control-plane by adding the labels: [...]
[mark-control-plane] Marking the node ip-10-0-10-11 as control-plane by adding the taints [node-role.kubernetes.io/control-plane:NoSchedule]
[bootstrap-token] Using token: abcdef.0123456789abcdef
[bootstrap-token] Configuring bootstrap tokens, cluster-info ConfigMap, RBAC Roles
...
[kubelet-finalize] Updating "/etc/kubernetes/kubelet.conf" to point to a rotatable kubelet client certificate and key   ← 步骤 8
[addons] Applied essential addon: CoreDNS                                ← 步骤 13、14
[addons] Applied essential addon: kube-proxy

Your Kubernetes control-plane has initialized successfully!
...
Alternatively, if you are the root user, you can run:
  export KUBECONFIG=/etc/kubernetes/admin.conf
...
Then you can join any number of worker nodes by running the following on each as root:

kubeadm join api.k8s.internal:6443 --token abcdef.0123456789abcdef \
	--discovery-token-ca-cert-hash sha256:1234...
```

几个说明：

- `[control-plane-check]` 里出现的 `0.0.0.0:10257`，就是我们给 controller-manager 设的 `bind-address`。kubeadm 照着这个地址去检查它是否健康。
- 最后的 **`kubeadm join` 命令先不用管**。里面的 token 24 小时后就过期了，第 05 章加 worker 时我们再生成新的。
- `/root/kubeadm-init.log` 里有这个 token，24 小时内谁拿到都能把机器加入你的集群。它只留在节点上，别贴到公开的地方。

### 步骤 5：配置 kubectl

kubectl 需要一个 kubeconfig 文件，才知道"集群在哪、我是谁"。kubeadm 刚刚生成了一个管理员用的：`/etc/kubernetes/admin.conf`。

🖥️ **cp-1（root）：**

```bash
# 当前 shell 立即生效
export KUBECONFIG=/etc/kubernetes/admin.conf

# 写进 root 的 .bashrc，以后每次 sudo -i 都自动生效；顺便配上命令补全和缩写 k
cat >> /root/.bashrc <<'EOF'
export KUBECONFIG=/etc/kubernetes/admin.conf
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
EOF
source /root/.bashrc

kubectl get nodes
```

> 💡 命令补全：输入 `kubectl get no` 再按 Tab，会补全成 `nodes`。`k` 是 `kubectl` 的缩写，后面的文档仍然写全称，你可以随意用缩写。

顺手给登录时的普通用户 ssm-user 也配一份，以后不切 root 也能用 kubectl（就是 init 输出里那三行命令）：

```bash
mkdir -p /home/ssm-user/.kube
cp /etc/kubernetes/admin.conf /home/ssm-user/.kube/config
chown -R ssm-user:ssm-user /home/ssm-user/.kube
```

### 步骤 6：先看一眼

🖥️ **cp-1（root）：**

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl auth whoami
```

你会看到类似：

```
NAME            STATUS     ROLES           AGE   VERSION   INTERNAL-IP   ...   CONTAINER-RUNTIME
ip-10-0-10-11   NotReady   control-plane   2m    v1.36.6   10.0.10.11    ...   containerd://2.2.1

NAMESPACE     NAME                                    READY   STATUS    RESTARTS   AGE   IP
kube-system   coredns-xxxxxxxxxx-xxxxx                0/1     Pending   0          2m    <none>
kube-system   coredns-xxxxxxxxxx-xxxxx                0/1     Pending   0          2m    <none>
kube-system   etcd-ip-10-0-10-11                      1/1     Running   0          2m    10.0.10.11
kube-system   kube-apiserver-ip-10-0-10-11            1/1     Running   0          2m    10.0.10.11
kube-system   kube-controller-manager-ip-10-0-10-11   1/1     Running   0          2m    10.0.10.11
kube-system   kube-proxy-xxxxx                        1/1     Running   0          2m    10.0.10.11
kube-system   kube-scheduler-ip-10-0-10-11            1/1     Running   0          2m    10.0.10.11
```

三个疑点先记下来，后面一个个解开：

1. 节点为什么是 **NotReady**？
2. CoreDNS 为什么 **Pending**，而其他 Pod 都 Running？
3. 那些 Running 的 Pod，IP 为什么都是**节点自己的 IP**（10.0.10.11）？

`kubectl auth whoami` 告诉你"在集群眼里你是谁"：用户名 `kubernetes-admin`，组 `kubeadm:cluster-admins`。这些信息正是从 admin.conf 里那张证书上读出来的（概念 3）。

---

## 🛠 动手 C：按阶段考古

### 步骤 7：`[certs]`，证书

🖥️ **cp-1（root）：**

```bash
find /etc/kubernetes/pki -type f | sort
```

对照概念 3 的表：`ca.*`、`etcd/ca.*`、`front-proxy-ca.*` 是 3 个 CA，`sa.key`/`sa.pub` 是那对密钥，其余的都是 CA 签出来的证书。`.crt` 是证书（公开的），`.key` 是私钥（绝对不能泄露）。

拆开 apiserver 的证书看看：

```bash
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -subject -issuer -dates -ext subjectAltName
```

```
subject=CN = kube-apiserver
issuer=CN = kubernetes                      ← 由集群 CA 签发
notBefore=...
notAfter=...                                ← 有效期 1 年
X509v3 Subject Alternative Name:
    DNS:api.k8s.internal, DNS:ip-10-0-10-11, DNS:kubernetes, DNS:kubernetes.default,
    DNS:kubernetes.default.svc, DNS:kubernetes.default.svc.cluster.local,
    IP Address:10.96.0.1, IP Address:10.0.10.11
```

**SAN（Subject Alternative Name）就是"这张证书对哪些名字有效"**。客户端用哪个名字连 apiserver，那个名字就必须在这个列表里，否则 TLS 验证失败：

| SAN | 谁会用这个名字连过来 |
|---|---|
| `api.k8s.internal` | kubectl、worker 上的 kubelet、kube-proxy（就是 `controlPlaneEndpoint`） |
| `10.0.10.11`、`ip-10-0-10-11` | 本机上的组件直接连 |
| `kubernetes.default.svc...`、`10.96.0.1` | **集群里的 Pod**。每个集群都有一个叫 `kubernetes` 的 Service，地址是 Service 网段的第一个 IP（10.96.0.1），Pod 通过它访问 apiserver |

再看看所有证书的有效期：

```bash
kubeadm certs check-expiration
```

普通证书 1 年（`364d`），3 个 CA 10 年（`9y`）。证书到期会怎样、怎么续，见深入原理 1。

### 步骤 8：`[kubeconfig]`，每个组件的"身份证"

kubeconfig 文件 = **连哪个 apiserver（server）+ 我是谁（客户端证书）+ 信任哪个 CA**。kubeadm 为每个需要访问 apiserver 的组件都生成了一个。用一个小循环把它们的"地址"和"身份"都打印出来：

🖥️ **cp-1（root）：**

```bash
cd /etc/kubernetes
for f in admin super-admin controller-manager scheduler; do
  printf '%-24s %-32s ' "$f.conf" "$(grep -m1 'server:' $f.conf | awk '{print $2}')"
  grep 'client-certificate-data' $f.conf | awk '{print $2}' | base64 -d | openssl x509 -noout -subject
done
cd
```

```
admin.conf               https://api.k8s.internal:6443    subject=O = kubeadm:cluster-admins, CN = kubernetes-admin
super-admin.conf         https://api.k8s.internal:6443    subject=O = system:masters, CN = kubernetes-super-admin
controller-manager.conf  https://10.0.10.11:6443          subject=CN = system:kube-controller-manager
scheduler.conf           https://10.0.10.11:6443          subject=CN = system:kube-scheduler
```

kubelet.conf 不一样，它不再内嵌证书，而是指向一个文件：

```bash
grep -E 'server:|client-certificate:' /etc/kubernetes/kubelet.conf
openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -subject
```

```
    server: https://10.0.10.11:6443
    client-certificate: /var/lib/kubelet/pki/kubelet-client-current.pem
subject=O = system:nodes, CN = system:node:ip-10-0-10-11
```

这是 init 的倒数第二个阶段 `[kubelet-finalize]` 做的：把 kubelet 的客户端证书换成一个**可以自动轮换**的文件（`-current.pem` 是个软链接，证书快到期时 kubelet 会自己申请新的、再把链接指过去）。这就是 kubelet 的第一张证书，**客户端证书**。

**admin 和 super-admin 有什么区别？** 比较一下：

```bash
kubectl auth whoami
kubectl auth whoami --kubeconfig /etc/kubernetes/super-admin.conf
```

一个属于 `kubeadm:cluster-admins` 组，一个属于 `system:masters` 组。后者是"破窗用"的超级身份，详见深入原理 2。

最后，整理一张**"谁连哪个地址"**的表。kube-proxy 的 kubeconfig 不在文件里，而是存在一个 ConfigMap 里：

```bash
kubectl -n kube-system get configmap kube-proxy -o jsonpath='{.data.kubeconfig\.conf}' | grep server
```

| 组件 | 连哪个地址 | 为什么 |
|---|---|---|
| kubectl（admin.conf） | `api.k8s.internal` | 从集群外面来，走"门牌号" |
| kube-proxy | `api.k8s.internal` | 每个节点都有，worker 上只能走门牌号 |
| controller-manager、scheduler | 本机 `10.0.10.11` | 和 apiserver 在同一台机器上，直接连本机最可靠 |
| cp-1 上的 kubelet | 本机 `10.0.10.11` | 同上（K8s 1.35 起的默认行为） |
| worker 上的 kubelet（第 05 章） | `api.k8s.internal` | 只能走门牌号 |

第 11 章有 3 个 control plane 时，这张表的意义就出来了：每个 control plane 上的组件只依赖**本机**的 apiserver，不会因为门牌号背后的负载均衡出问题而一起瘫痪。

### 步骤 9：`[etcd]` 和 `[control-plane]`：static pod

🖥️ **cp-1（root）：**

```bash
ls -l /etc/kubernetes/manifests/
grep staticPodPath /var/lib/kubelet/config.yaml       # kubelet 盯着的目录，就是这里
```

这 4 个文件就是概念 2 里说的 static pod。挑 apiserver 的看几个关键参数：

```bash
grep -E -- '--(advertise-address|etcd-servers|service-cluster-ip-range|authorization-mode|client-ca-file)=' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
```

| 参数 | 含义 |
|---|---|
| `--advertise-address=10.0.10.11` | apiserver 对外宣告的地址 |
| `--etcd-servers=https://127.0.0.1:2379` | 去哪里找 etcd：就在本机 |
| `--service-cluster-ip-range=10.96.0.0/12` | 我们配置的 serviceSubnet |
| `--authorization-mode=Node,RBAC` | 授权方式：节点专用规则 + RBAC |
| `--client-ca-file=/etc/kubernetes/pki/ca.crt` | 用哪个 CA 验证客户端证书，概念 3 说的就是它 |

再找找我们在配置文件里加的那几项，它们都变成了命令行参数：

```bash
grep -h -- '--bind-address\|--listen-metrics-urls' /etc/kubernetes/manifests/*.yaml
grep -l 'hostNetwork: true' /etc/kubernetes/manifests/*.yaml
```

第二条说明：**4 个控制面 Pod 都是 `hostNetwork: true`**，直接用宿主机的网络，所以它们的 IP 就是 10.0.10.11。这解开了步骤 6 的疑点 3。

kubelet 怎么知道这些容器还健康？每个 manifest 里都写了探针（probe），kubelet 定期去访问：

```bash
grep -n 'host:' /etc/kubernetes/manifests/*.yaml
```

| 组件 | 探测地址 | 说明 |
|---|---|---|
| kube-apiserver | `10.0.10.11:6443` | 用 advertise-address |
| etcd | `0.0.0.0:2381` | 用我们设的 `listen-metrics-urls`。在 Linux 上连 0.0.0.0 等于连本机 |
| controller-manager、scheduler | 没写 host | 不写 host 就探测 Pod 的 IP，也就是节点 IP |

现在对比一下两个视角：

```bash
crictl ps                                  # 容器运行时的视角：真实的容器
kubectl -n kube-system get pods            # apiserver 的视角
```

`kubectl` 看到的 `kube-scheduler-ip-10-0-10-11` 是 kubelet 在 apiserver 里登记的 **mirror pod（影子）**。验证一下：

```bash
kubectl -n kube-system get pod kube-scheduler-ip-10-0-10-11 \
  -o jsonpath='{.metadata.annotations.kubernetes\.io/config\.source}{"\n"}'
# 输出 file：这个 Pod 来自本地文件，而不是 apiserver
```

**小实验：删掉影子会怎样？**

```bash
crictl ps --name kube-scheduler -q          # 记下容器 ID
kubectl -n kube-system delete pod kube-scheduler-ip-10-0-10-11
kubectl -n kube-system get pod kube-scheduler-ip-10-0-10-11    # 立刻又出现了，AGE 从 0 开始
crictl ps --name kube-scheduler -q          # 容器 ID 一模一样！
```

`kubectl delete` 只删掉了 apiserver 里的影子，kubelet 马上又登记了一个新的。真正的容器根本没动。**想停掉一个 static pod，唯一的办法是把它的文件移出这个目录**（演练 1 会做）。

### 步骤 10：`[kubelet-start]` 和 `[kubelet-finalize]`：kubelet 活过来了

第 02 章结束时，kubelet 一直处在"启动 → 找不到配置 → 退出"的循环里。现在：

🖥️ **cp-1（root）：**

```bash
systemctl status kubelet --no-pager | head -5        # Active: active (running)
```

还记得第 02 章深入原理 1 的那张表吗？kubelet 的启动命令由 4 组参数拼成。现在它们都有来源了：

```bash
cat /var/lib/kubelet/kubeadm-flags.env               # KUBELET_KUBEADM_ARGS=""   空的！
cat /var/lib/kubelet/instance-config.yaml            # containerRuntimeEndpoint: "unix:///var/run/containerd/containerd.sock"
cat /etc/default/kubelet                             # 第 02 章写的凭证插件参数
```

| 变量 | 来自哪里 | 现在 |
|---|---|---|
| `KUBELET_KUBECONFIG_ARGS` | drop-in 里写死的 | `kubelet.conf` 已经存在 ✅ |
| `KUBELET_CONFIG_ARGS` | drop-in 里写死的 | `config.yaml` 已经存在 ✅ |
| `KUBELET_KUBEADM_ARGS` | `kubeadm-flags.env` | 文件存在，但**内容是空的** |
| `KUBELET_EXTRA_ARGS` | `/etc/default/kubelet` | 凭证插件参数 ✅ |

`kubeadm-flags.env` 为什么是空的？以前的 kubeadm 会把"连哪个 CRI socket"这类**每台节点自己的**设置写成命令行参数放在这里。新版本改成写进 `instance-config.yaml`，再合并进 `config.yaml`（init 输出里那行 `[patches]` 就是在做这个合并）。命令行参数这条路就空出来了。

看看 kubelet 的主配置文件：

```bash
grep -E '^(cgroupDriver|containerRuntimeEndpoint|rotateCertificates|serverTLSBootstrap|staticPodPath):' \
  /var/lib/kubelet/config.yaml
```

`serverTLSBootstrap: true` 是我们写的；`rotateCertificates: true` 让 kubelet 自动轮换客户端证书；`staticPodPath` 是步骤 9 看到的 static pod 目录；`containerRuntimeEndpoint` 是从 instance-config.yaml 合并进来的。

里面有一行 `cgroupDriver: systemd`。我们没写，是 kubeadm 填的。但它其实**不起决定作用**：

```bash
journalctl -u kubelet --no-pager | grep 'cgroup driver' | tail -1
```

```
"Using cgroup driver setting received from the CRI runtime" cgroupDriver="systemd"
```

kubelet 问了 containerd，containerd 回答 `systemd`，kubelet 就用 `systemd`。这正是第 02 章概念 3 和深入原理 2 讲的："真正起决定作用的是 containerd 的那一行 `SystemdCgroup = true`"。现在你亲眼看到了。

### 步骤 11：`[wait-control-plane]`：健康检查接口

init 时，kubeadm 是靠访问各组件的健康检查接口，来判断控制面有没有起来。我们也来访问一下：

🖥️ **cp-1（root）：**

```bash
curl -s http://127.0.0.1:10248/healthz; echo           # kubelet：ok
curl -sk https://127.0.0.1:10257/healthz; echo         # controller-manager：ok
curl -sk https://127.0.0.1:10259/healthz; echo         # scheduler：ok
curl -sk 'https://127.0.0.1:6443/readyz?verbose' | tail -4
```

`readyz?verbose` 会列出 apiserver 的每一项内部检查，最后一行是 `readyz check passed`。

（`-k` 让 curl 不验证服务端证书，因为我们没告诉它信任哪个 CA。这只是为了演示，平时不要这么用。）

**注意：我们根本没带任何证书，却拿到了结果。** 这是因为 apiserver 允许**匿名用户**访问少数几个"公开信息"接口（健康检查、`/version`）。真正的数据就不行了：

```bash
curl -sk https://127.0.0.1:6443/version | head -4                  # 可以
curl -sk https://127.0.0.1:6443/api/v1/namespaces | grep message   # 不行
```

```
  "message": "namespaces is forbidden: User \"system:anonymous\" cannot list resource \"namespaces\" ...",
```

没带证书，你就是 `system:anonymous`，几乎什么都不能看。

### 步骤 12：etcd 一瞥

集群的全部状态都存在 etcd 里。etcd 的镜像里自带了命令行客户端 `etcdctl`，用 `crictl exec` 在 etcd 容器里执行它。先定义一个小函数，省得每次都敲一长串证书参数：

🖥️ **cp-1（root）：**

```bash
ETCD=$(crictl ps --name etcd -q)
etcdctl() {
  crictl exec "$ETCD" etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
    --key=/etc/kubernetes/pki/etcd/healthcheck-client.key "$@"
}

etcdctl member list -w table           # 现在只有 1 个成员，第 11 章会变成 3 个
```

K8s 把所有对象都存在 `/registry/` 下面。数一数，再按类型分组看看：

```bash
etcdctl get /registry --prefix --keys-only | grep -c .
etcdctl get /registry --prefix --keys-only | grep . | awk -F/ '{print $3}' | sort | uniq -c | sort -rn | head -15
etcdctl get /registry --prefix --keys-only | grep '/registry/pods/'
```

一个刚建好、什么应用都没有的集群，etcd 里已经有三百个左右的 key：各种角色和权限规则（clusterroles、rolebindings）、ConfigMap、Pod……

试着读一个值：

```bash
etcdctl get /registry/namespaces/kube-system | head -c 200 | cat -v; echo
```

是一堆乱码：K8s 用二进制的 protobuf 格式存储对象，不是给人直接看的。正常情况下应该通过 apiserver 读数据，第 06 章会再回到这里。

> 🔑 注意刚才用的证书：`healthcheck-client`，一个"做健康检查用"的证书，却能读出 etcd 里的**所有数据**。kubeadm 搭的 etcd 不做细粒度授权，**只要证书是 etcd CA 签的，就能读写一切**，包括所有 Secret。所以 `/etc/kubernetes/pki/etcd/` 是整个集群最需要保护的目录，这也是"只有 apiserver 能碰 etcd"这条规则存在的原因。

### 步骤 13：集群级的产物

前面看的都是节点上的文件。init 的后几个阶段是在**集群里**创建对象：

🖥️ **cp-1（root）：**

```bash
# [upload-config]：把这次 init 用的配置存进集群
kubectl -n kube-system get configmap
kubectl -n kube-system get configmap kubeadm-config -o yaml | head -30
```

`kubeadm-config` 里就是你写的 ClusterConfiguration（补上了默认值）；`kubelet-config` 里是 KubeletConfiguration。第 05 章 worker 执行 `kubeadm join` 时，会从这里读取配置，所以 worker 不需要你再写一遍；第 18 章升级时也会读它。

`[upload-certs] Skipping phase` 被跳过了：它负责把证书加密后存进集群，给新加入的 control plane 用，第 11 章才需要。

```bash
# [mark-control-plane]：给节点贴的 label 和 taint
kubectl get node ip-10-0-10-11 --show-labels | tr ',' '\n' | grep node-role
kubectl describe node ip-10-0-10-11 | grep -A2 Taints
```

`node-role.kubernetes.io/control-plane:NoSchedule` 这个 taint（"禁止入内"牌子）的意思是：**普通 Pod 不要调度到 control plane 上**，把控制面的资源留给控制面自己。

```bash
# [bootstrap-token]：给 worker 加入集群用的临时 token
kubeadm token list

# 以及一份"公开的"集群信息：没带证书（匿名）也能读
curl -sk https://127.0.0.1:6443/api/v1/namespaces/kube-public/configmaps/cluster-info | grep -o 'server: [^\\]*'
```

输出 `server: https://api.k8s.internal:6443`。这份 ConfigMap 里还有集群的 CA 证书。

新机器加入集群时手里什么证书都没有，所以 kubeadm 把"集群地址 + CA 证书"放在 `kube-public` 命名空间的 `cluster-info` 里，任何人都能读。新机器读到它，再用 token 证明自己有资格加入。这个巧妙的过程是第 05 章的主角。

```bash
# [addons]：CoreDNS 是一个 Deployment，kube-proxy 是一个 DaemonSet
kubectl -n kube-system get deployment,daemonset
```

最后顺带看一个字段：

```bash
kubectl get node ip-10-0-10-11 -o jsonpath='{.spec.podCIDR}{"\n"}'     # 192.168.0.0/24
```

controller-manager 从 podSubnet 里给每个节点切了一小段（/24）。不过我们第 04 章要装的 Calico **不使用这个字段**，它有自己的 IP 分配方式。先知道有这么回事，到时候就不会困惑了。

---

## 🛠 动手 D：两个"为什么"

### 步骤 14：为什么 NotReady？为什么 CoreDNS 是 Pending？

🖥️ **cp-1（root）：**

```bash
kubectl describe node ip-10-0-10-11 | grep -A8 Conditions
```

看 `Ready` 那一行：

```
Ready   False   ...   KubeletNotReady   container runtime network not ready: NetworkReady=false
                                        reason:NetworkPluginNotReady message:Network plugin returns error: cni plugin not initialized
```

**还没有网络插件（CNI）。** 和第 02 章步骤 9 里 `crictl info` 报的 `NetworkReady: false` 是同一件事。kubelet 判断：没有网络插件，就没法给新 Pod 分配 IP，所以这个节点还不能接收普通 Pod。第 04 章装上 Calico 就好了。

那 CoreDNS 为什么 Pending？看调度器留下的事件：

```bash
kubectl -n kube-system get events --field-selector reason=FailedScheduling
```

```
0/1 nodes are available: 1 node(s) had untolerated taint(s). ...
```

"节点身上有它不能容忍的 taint"，但没说是哪个。自己对比一下节点的 taint 和 CoreDNS 的 toleration：

```bash
kubectl describe node ip-10-0-10-11 | grep -A2 Taints
kubectl -n kube-system describe pod -l k8s-app=kube-dns | grep -m1 -A4 Tolerations
```

| 节点身上的 taint | CoreDNS 能容忍吗 |
|---|---|
| `node-role.kubernetes.io/control-plane:NoSchedule` | ✅ 有对应的 toleration |
| `node.kubernetes.io/not-ready:NoSchedule` | ❌ 它只容忍 `not-ready` 的 **NoExecute**，没有容忍 **NoSchedule** |

节点 NotReady 时，K8s 会自动给它贴上 `not-ready` 的牌子，CoreDNS 就过不去了。

那为什么 kube-proxy 和控制面的 Pod 能 Running？因为它们都是 **`hostNetwork: true`**：直接用宿主机的网络，**不需要 CNI 分配 IP**（步骤 9 看到过）。而且它们也都容忍了这些 taint。CoreDNS 是普通 Pod，需要自己的 IP，只能等 CNI。

三个疑点全部解开：

| 疑点 | 答案 |
|---|---|
| 节点 NotReady | 没有 CNI 网络插件 |
| CoreDNS Pending | 节点 NotReady → 被贴上 not-ready taint → CoreDNS 不能容忍 |
| Running 的 Pod 用节点 IP | 都是 hostNetwork，不需要 CNI |

### 步骤 15：kubelet 的第二张证书，服务端证书

试着看看 apiserver 的日志：

🖥️ **cp-1（root）：**

```bash
kubectl -n kube-system logs kube-apiserver-ip-10-0-10-11 --tail=5
```

```
Error from server: Get "https://10.0.10.11:10250/containerLogs/kube-system/kube-apiserver-ip-10-0-10-11/kube-apiserver?tailLines=5": remote error: tls: internal error
```

`kubectl logs` 的路径是：kubectl → apiserver → **节点上 kubelet 的 10250 端口** → 读容器日志。这里是 apiserver 连 kubelet 时 TLS 握手失败了。因为我们设了 `serverTLSBootstrap: true`，kubelet 不再自己给自己签证书，而是向集群申请一张，可这个申请**还没人批准**：

```bash
kubectl get csr
```

```
NAME        AGE   SIGNERNAME                                    REQUESTOR                   CONDITION
csr-xxxxx   20m   kubernetes.io/kube-apiserver-client-kubelet   system:node:ip-10-0-10-11   Approved,Issued
csr-xxxxx   20m   kubernetes.io/kubelet-serving                 system:node:ip-10-0-10-11   Pending
csr-xxxxx   20m   kubernetes.io/kubelet-serving                 system:node:ip-10-0-10-11   Pending
csr-xxxxx   5m    kubernetes.io/kubelet-serving                 system:node:ip-10-0-10-11   Pending
```

- `kube-apiserver-client-kubelet`：kubelet 申请**客户端证书**，已经被自动批准了（就是步骤 8 看到的那张）。
- `kubelet-serving`：kubelet 申请**服务端证书**，Pending。**为什么有好几个？** init 过程中 kubelet 被重启过一次，每次启动都会提交一个申请；而且申请超过 15 分钟没人批，kubelet 会再提交一个新的。你做到这一步时，可能已经有 3~6 个了。

批准之前，先看看它申请的是什么。**签证书之前核对内容，是好习惯**：

```bash
CSR=$(kubectl get csr --field-selector spec.signerName=kubernetes.io/kubelet-serving -o name | head -1)
kubectl get $CSR -o jsonpath='{.spec.request}' | base64 -d > /tmp/kubelet-serving.csr
openssl req -in /tmp/kubelet-serving.csr -noout -subject
openssl req -in /tmp/kubelet-serving.csr -noout -text | grep -A1 'Alternative Name'
```

```
subject=O = system:nodes, CN = system:node:ip-10-0-10-11
                X509v3 Subject Alternative Name:
                    DNS:ip-10-0-10-11, IP Address:10.0.10.11
```

申请的名字和 IP 都是这台机器自己的，没问题。一次全部批准：

```bash
kubectl get csr --field-selector spec.signerName=kubernetes.io/kubelet-serving -o name \
  | xargs kubectl certificate approve
kubectl get csr                                       # 全部 Approved,Issued

ls -l /var/lib/kubelet/pki/                            # 多了 kubelet-server-current.pem
kubectl -n kube-system logs kube-apiserver-ip-10-0-10-11 --tail=5     # 现在可以了
```

**为什么客户端证书自动批准，服务端证书却要人工批准？**

- 客户端证书只是证明"我是节点 X"，而节点 X 的身份在加入集群时已经验证过了。
- 服务端证书上写的是"我的 IP 是 10.0.10.11"。如果自动批准，一个被攻破的节点就可以申请一张写着**别人 IP** 的证书，冒充别的节点。K8s 自己没法验证"这个 IP 真的属于你"，所以默认把这个判断交给人（或者交给你自己写的自动审批程序）。

这么麻烦图什么？第 14 章装 metrics-server 和 Prometheus 时，它们要去访问每个 kubelet。有了集群 CA 签发的证书，它们就能正常验证 kubelet 的身份，而不用加 `--kubelet-insecure-tls` 这种"跳过验证"的参数。

| kubelet 的证书 | 用途 | 谁签发 | 批准方式 |
|---|---|---|---|
| 客户端证书 `kubelet-client-current.pem` | kubelet → apiserver，证明"我是节点 X" | 集群 CA | 自动 |
| 服务端证书 `kubelet-server-current.pem` | apiserver → kubelet，证明"我真的是节点 X" | 集群 CA | **人工**（`serverTLSBootstrap: true`） |

> worker 加入时也会各自申请服务端证书，第 05 章再批。

---

## ✅ 验证

全部打勾，本章就完成了：

- [ ] `kubectl -n kube-system get pods`：etcd、kube-apiserver、kube-controller-manager、kube-scheduler、kube-proxy 都是 Running（RESTARTS 不为 0 也正常，见深入原理 3）
- [ ] `kubectl get nodes`：NotReady，原因是 `cni plugin not initialized`；CoreDNS 是 Pending
- [ ] `kubectl -n kube-system logs kube-apiserver-ip-10-0-10-11 --tail=3` 能看到日志，`/var/lib/kubelet/pki/kubelet-server-current.pem` 存在
- [ ] `kubeadm certs check-expiration`：普通证书剩约 1 年，CA 剩约 10 年
- [ ] `kubectl auth whoami`：组是 `kubeadm:cluster-admins`

> "关机再开机，控制面能不能自己恢复"这一项，我们放到第 04 章开头验证。

---

## 🔍 深入原理

### 1. 证书到期了会怎样？

| 证书 | 有效期 | 到期前怎么办 |
|---|---|---|
| 3 个 CA | 10 年 | 实验环境用不到这么久 |
| apiserver、etcd、admin.conf 等 | 1 年 | `kubeadm upgrade` 时会**自动续期**；也可以手动 `kubeadm certs renew all` |
| kubelet 客户端证书 | 1 年 | kubelet 快到期时**自动**申请新的，自动批准 |
| kubelet 服务端证书 | 1 年 | kubelet 也会自动申请新的，但**又要人工批准一次** |

如果真的过期了：apiserver 的证书过期，所有客户端都会拒绝连接，kubectl 报 `x509: certificate has expired`，整个集群就失联了。这是生产环境里真实发生过很多次的事故，所以每年至少升级一次 K8s（顺带续期证书）是好习惯。第 18 章会做一次完整的检查和续期。

### 2. admin.conf 和 super-admin.conf

| | admin.conf | super-admin.conf |
|---|---|---|
| 组 | `kubeadm:cluster-admins` | `system:masters` |
| 权限从哪来 | 一条 ClusterRoleBinding 把这个组绑到了 `cluster-admin` 角色 | **写死在 apiserver 里**：这个组直接跳过所有权限检查 |
| 能不能收回 | 能：删掉那条绑定，这张证书立刻没用 | **不能**：K8s 没有证书吊销机制，只能等它过期或者换掉整个 CA |

```bash
kubectl get clusterrolebinding kubeadm:cluster-admins -o wide
```

以前 kubeadm 只生成一个 admin.conf，它就属于 `system:masters`，一旦泄露无法挽回。从 1.29 起拆成了两个：平时用可收回的 admin.conf；super-admin.conf 只在"RBAC 被搞坏了、admin 也进不去"时才拿出来用。生产环境里，super-admin.conf 应该离线保存，不留在服务器上。

### 3. RESTARTS 为什么不是 0：leader election

controller-manager 和 scheduler 都是"同一时间只能有一个在干活"的组件：两个 scheduler 同时给一个 Pod 分配节点，就乱套了。所以它们会抢一把锁，抢到的才干活。这把锁是 `kube-system` 里的 **Lease** 对象：

```bash
kubectl -n kube-system get lease
```

`HOLDER` 列就是现在持有锁的那个。持有者要定期续约；如果连不上 apiserver、续约失败，它会**主动退出**，避免出现两个"老大"。kubelet 再把它重新拉起来，RESTARTS 就加 1。

所以 apiserver 重启过（比如做完演练 1、或者机器重启），controller-manager 和 scheduler 的 RESTARTS 增加是**正常的**。第 11 章有 3 个 control plane 时，3 个 controller-manager 里只有 1 个持有锁，另外 2 个待命，这就是它们的高可用方式。

---

## 💥 故意搞坏

### 演练 1：apiserver 的 manifest 不见了

🖥️ **cp-1（root）：**

```bash
mv /etc/kubernetes/manifests/kube-apiserver.yaml /root/

# 等半分钟左右，kubelet 发现文件没了，就会停掉 apiserver
watch -n2 'crictl ps | grep -E "NAME|kube-apiserver|etcd"'       # apiserver 消失后按 Ctrl+C
```

```bash
kubectl get nodes
```

```
The connection to the server api.k8s.internal:6443 was refused - did you specify the right host or port?
```

但是：

```bash
crictl ps                       # etcd、controller-manager、scheduler 都还在
systemctl is-active kubelet     # kubelet 也好好的
```

- **kubectl 完全依赖 apiserver**，apiserver 一停，什么都看不到了。
- **kubelet 不依赖 apiserver** 来运行 static pod，它只看本地文件。所以哪怕 apiserver 挂了，kubelet 也能把它重新拉起来。这正是 static pod 的意义。
- `connection refused`：DNS 解析成功、包也到了 cp-1，但 6443 端口上没有程序在监听（第 01 章讲过 refused 和 timeout 的区别）。

看看 controller-manager 在干什么：

```bash
crictl logs --tail 3 $(crictl ps --name kube-controller-manager -q)
```

它在不停报错：连不上 apiserver，拿不到 Lease 锁（深入原理 3）。

恢复：

```bash
mv /root/kube-apiserver.yaml /etc/kubernetes/manifests/
until kubectl get --raw=/readyz >/dev/null 2>&1; do sleep 2; done; echo "apiserver 回来了"
kubectl -n kube-system get pods
```

controller-manager 和 scheduler 的 RESTARTS 多半加了 1，这是预期之中的。

> ⚠️ **一个真实的坑**：修改 static pod manifest 之前做备份，**千万别把备份放在 `/etc/kubernetes/manifests/` 里**。kubelet 会把目录里的**每一个文件**都当成 Pod 定义（只跳过以 `.` 开头的隐藏文件），`kube-apiserver.yaml.bak` 也不例外。两份定义里的 Pod 同名，kubelet 只会跑其中一份，**而且可能偏偏是备份里那份旧的**：你改的新配置怎么都不生效，排查起来非常困惑。备份要放到别的目录，比如 `/root/`。

### 演练 2（可选）：containerd 停了，第 02 章演练 1 的下半场

第 02 章停掉 containerd 时，kubelet 还没运行，看不到它的反应。现在可以看了：

🖥️ **cp-1（root）：**

```bash
systemctl stop containerd

crictl ps                          # 报错：连不上 containerd.sock
kubectl get nodes                  # 却还能用！
```

**为什么 kubectl 还能用？** apiserver 也是容器，containerd 都停了，它怎么还活着？回忆第 02 章：容器进程的父进程是 **shim**，不是 containerd。containerd 停了，shim 和容器照样运行。所以整个控制面都还在工作。

等 30 秒左右，看看 kubelet 怎么说：

```bash
journalctl -u kubelet --since "-1min" --no-pager | grep -m3 'containerd.sock'
kubectl describe node ip-10-0-10-11 | grep -E '^\s+Ready'
```

kubelet 的日志里全是连不上 `containerd.sock` 的报错；节点的 Ready 条件里多了一条 **`container runtime is down`**。**以后看到这句话，第一反应就是去查 containerd。**

恢复：

```bash
systemctl start containerd
sleep 15
kubectl describe node ip-10-0-10-11 | grep -E '^\s+Ready'     # 只剩 cni plugin not initialized 了
```

> "停掉 kubelet 会怎样"这个演练放到第 05 章：有了 worker 节点，才能看到节点失联后 Pod 被驱逐的完整过程。

做完演练，退出 root：

```bash
exit
```

---

## ❓ 思考题

**1. apiserver 的证书里为什么要有 `10.96.0.1` 这个 IP？我们并没有任何机器用这个 IP。**

<details>
<summary>参考答案</summary>

`10.96.0.1` 是 `default` 命名空间里那个名叫 `kubernetes` 的 Service 的 ClusterIP（Service 网段的第一个地址）。集群里的 Pod 要访问 apiserver（比如第 04 章的 Calico、第 13 章的 cert-manager），用的就是这个地址或者它的域名 `kubernetes.default.svc`。

它确实不是哪台机器的 IP，而是 kube-proxy 在每个节点上设置的一个"虚拟 IP"，发往它的包会被转到真正的 apiserver（10.0.10.11:6443）。但 TLS 验证看的是客户端**连的是哪个地址**，所以这个虚拟 IP 也必须写进证书。
</details>

**2. 为什么规定只有 apiserver 能访问 etcd，其他组件都要经过 apiserver？**

<details>
<summary>参考答案</summary>

- **安全**：步骤 12 看到了，etcd 本身几乎不做权限控制，谁有证书谁就能读写一切。把 etcd 藏在 apiserver 后面，所有访问都要经过 apiserver 的认证、授权、准入检查，还能记审计日志（第 16 章）。
- **一致性**：apiserver 会校验每个对象的格式、填上默认值、检查版本冲突。如果每个组件都直接写 etcd，数据很快就乱了。
- **解耦**：只有 apiserver 知道数据在 etcd 里怎么存。将来换存储格式、升级 etcd，其他组件完全不受影响。
- **watch 机制**：组件们通过 apiserver 订阅变化，而不是各自去 etcd 轮询，减轻了 etcd 的压力。
</details>

**3. kubelet 和 controller-manager 连的是本机 IP，kubectl 和 kube-proxy 连的是 `api.k8s.internal`。到第 11 章，`api.k8s.internal` 背后是 NLB。如果 NLB 坏了，谁还能工作？**

<details>
<summary>参考答案</summary>

- **还能工作**：每个 control plane 上的 kubelet、controller-manager、scheduler。它们只连本机的 apiserver，不经过 NLB。控制面内部照常运转，etcd 也照常同步。
- **受影响**：你的 kubectl、所有 worker 上的 kubelet 和 kube-proxy。它们都走 `api.k8s.internal`。不过 worker 上**已经在跑的 Pod 不会停**：kubelet 连不上 apiserver 只是无法接收新任务、无法汇报状态，不会去杀掉正在运行的容器。

这就是为什么"control plane 上的组件连本机"这个设计很重要：入口出问题时，控制面至少能保住自己。
</details>

**4. 如果当初把 `controlPlaneEndpoint` 写成 `10.0.10.11:6443`，第 11 章扩成 3 个 control plane 时会遇到什么麻烦？**

<details>
<summary>参考答案</summary>

这个地址被写进了很多地方：admin.conf、kube-proxy 的 ConfigMap、`cluster-info`、`kubeadm-config`，以后还有每个 worker 上的 kubelet.conf。另外，apiserver 证书里也不会有 `api.k8s.internal`。

想让它们改成走负载均衡，就要：重新签发 apiserver 证书、修改集群里的几个 ConfigMap、逐台修改 worker 的 kubelet.conf 并重启……任何一处漏了，那个组件就只认 cp-1，cp-1 一挂它就失联。而我们只需要改一条 DNS 记录。
</details>

**5. kube-proxy 也是一个 Pod，为什么它不需要 CNI 就能 Running？如果它也需要 CNI，会出现什么问题？**

<details>
<summary>参考答案</summary>

因为它是 `hostNetwork: true`，直接用节点的网络，不需要 CNI 分配 IP。

如果它也需要 CNI，就会出现"先有鸡还是先有蛋"：很多 CNI 插件（包括 Calico）自己就要通过 `kubernetes` 这个 Service（10.96.0.1）去访问 apiserver，而 Service 的虚拟 IP 正是 kube-proxy 负责实现的。kube-proxy 等 CNI，CNI 等 kube-proxy，谁都起不来。

所以系统级的组件（控制面、kube-proxy、CNI 插件本身）一般都用 hostNetwork，它们是"网络的建设者"，不能依赖网络。
</details>

---

## 🧹 收工

💻 **Mac：**

```bash
cd ~/Desktop/code/K8s-learning
./scripts/lab-down.sh

git add -A
git commit -m "ch03: kubeadm init"
```

把 README 里第 03 章的状态改成 ✅。

**下一章预告**：第 04 章，安装 Calico 网络插件。开头我们先验证一件事：关机再开机，控制面能不能完全靠 kubelet 和 static pod 自己恢复。然后看 CNI 到底是什么、Calico 是怎么给 Pod 分配 IP 的、VXLAN 怎么让不同节点上的 Pod 互相通信，以及节点终于变成 **Ready**、CoreDNS 终于跑起来的那一刻。

---

## 🧯 附录：init 失败了怎么办

**第一步：看日志，找原因。**

```bash
tail -n 30 /root/kubeadm-init.log
journalctl -u kubelet -n 50 --no-pager
```

最常见的几种情况：

| 现象 | 可能的原因 | 怎么查 |
|---|---|---|
| 卡在 `[kubelet-check]`，4 分钟后超时 | kubelet 起不来。init 是 kubelet **第一次真正带着全部参数启动**，第 02 章写的凭证插件参数也是这时才第一次生效 | `journalctl -u kubelet -n 50`，看 `/etc/default/kubelet` 里的路径对不对、插件文件在不在 |
| 卡在 `[control-plane-check]` | 某个控制面容器起不来 | `crictl ps -a` 找到 Exited 的容器，再 `crictl logs <容器ID>` |
| `[preflight]` 就报错 | 环境不满足要求 | 报错信息会直接说明哪一项检查失败 |
| init 中途 SSM 断线 | init 被中断，状态不完整 | 直接按下面的方法重置 |

**第二步：重置，再来一次。**

```bash
kubeadm reset -f
rm -rf /etc/cni/net.d /root/.kube /home/ssm-user/.kube
```

- `kubeadm reset` 会删掉 `/etc/kubernetes/manifests`、`/etc/kubernetes/pki`、所有 kubeconfig 和 `/var/lib/kubelet` 等 init 生成的东西，并停掉控制面容器。
- 它**不会**删掉 `/etc/kubernetes/image-credential-provider`（第 02 章装的凭证插件配置），这正是我们想要的。
- 后面的 `rm` 删掉 reset 不管的东西。特别是 `~/.kube/config`：旧集群的 CA 留在里面，重新 init 之后 kubectl 会报 `x509: certificate signed by unknown authority`。
- `/root/.bashrc` 里那几行可以留着，重新 init 后 admin.conf 的路径不变。

然后回到步骤 4 重新 init。还是不行的话，把 `/root/kubeadm-init.log` 和 `journalctl -u kubelet -n 50` 的输出贴给我（token 那几行可以删掉）。
