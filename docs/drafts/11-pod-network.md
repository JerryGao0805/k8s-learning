> 📝 **草稿，现在不用看。** 这是第 04 章原来的完整版，课程改为"先搭建、再学习"后，留作学习篇**第 11 章 · Pod 网络**的素材。
> 搭建篇做完后，会按多节点环境（6 个节点）重写：加入跨节点 VXLAN、抓包和 CrossSubnet 演练，演练 1 的现象也会不同。
> 文中的章节号是**旧编号**（例如"第 05 章"指的是 worker 加入之后）。

# 第 04 章 · 安装 Calico：给 Pod 接上网线

## 🎯 本章目标

1. 先补上第 03 章留下的验收项：**关机再开机，控制面能不能完全靠自己恢复**
2. 搞懂 CNI：Pod 的 IP 是谁分配的、"网线"是谁接的、在什么时候接的
3. 用 tigera-operator 装上 Calico（纯 VXLAN、不开 BGP），看着节点变成 **Ready**、CoreDNS 跑起来
4. 在一个节点内把 Pod 网络拆开看：veth、`/32` 地址、神秘的 `169.254.1.1`、IP 块（IPAM）、访问外网时的 NAT
5. 认识 CRD 和 operator：K8s 是怎么被"扩展"出新功能的

大约需要 **3 小时**（标了"选做"的步骤可以跳过），全程只在 **cp-1** 上操作。

现在集群里只有 cp-1 一个节点，所以本章看的都是**同一个节点内**的 Pod 网络。VXLAN 隧道今天会建好，但它真正派上用场（跨节点通信、抓 UDP 4789 的包、CrossSubnet 演练）要等第 05 章 worker 加入之后。

> 开始之前，💻 **Mac：** 如果机器是停着的，先 `./scripts/lab-up.sh`；再用 `./scripts/status.sh` 确认 SSM 全部 `Online`。

---

## 🛠 动手 A：开工自检，控制面能自己"冷启动"吗？

第 03 章收工时你执行了 `lab-down.sh`，cp-1 关机了；刚才 `lab-up.sh` 又把它开了起来。这期间**没有任何人**去启动 apiserver、etcd。先看看它们自己回来了没有。

### 步骤 1：登录，先看机器

💻 **Mac：**

```bash
cd ~/Desktop/code/K8s-learning
./scripts/ssm.sh cp-1
```

🖥️ **cp-1：**

```bash
sudo -i          # 本章全程用 root。第 03 章已经把 KUBECONFIG 写进了 /root/.bashrc
```

🖥️ **cp-1（root）：**

```bash
uptime                                       # 刚开机几分钟
systemctl is-enabled containerd kubelet      # enabled enabled：开机自动启动
systemctl is-active containerd kubelet       # active active
```

`enabled` 是关键：第 02 章装包时，containerd 和 kubelet 都被设成了开机自启。开机后 systemd 先把它们俩拉起来，剩下的事情全靠 kubelet。

### 步骤 2：看控制面

🖥️ **cp-1（root）：**

```bash
kubectl get nodes
kubectl -n kube-system get pods
```

预期（数字以你的为准）：

```
NAME            STATUS     ROLES           AGE   VERSION
ip-10-0-10-11   NotReady   control-plane   1d    v1.36.6

NAME                                    READY   STATUS    RESTARTS        AGE
coredns-589f44dc88-djh7g                0/1     Pending   0               1d
coredns-589f44dc88-kqb4l                0/1     Pending   0               1d
etcd-ip-10-0-10-11                      1/1     Running   2 (3m ago)      1d
kube-apiserver-ip-10-0-10-11            1/1     Running   3 (3m ago)      1d
kube-controller-manager-ip-10-0-10-11   1/1     Running   5 (3m ago)      1d
kube-proxy-v99jw                        1/1     Running   2 (3m ago)      1d
kube-scheduler-ip-10-0-10-11            1/1     Running   5 (3m ago)      1d
```

怎么看：

- **节点还是 NotReady**：正常，还没装网络插件，这正是本章要解决的。
- **RESTARTS 比你第 03 章最后看到的多了**：每个容器都因为关机停过一次，开机后由 kubelet 重新启动。controller-manager 和 scheduler 可能多加了 1~2 次，因为 apiserver 起得比它们慢，它们连不上就主动退出、再被拉起（第 03 章深入原理 3）。
- **AGE 没变**：还是那几个 Pod 对象，只是里面**换了新的容器**。Pod 是"记录"，容器才是真正跑的进程。
- **CoreDNS 的 RESTARTS 还是 0**：它一直是 Pending，从没被启动过，自然谈不上重启。

再从 containerd 这一层看：

```bash
crictl ps -a
```

```
CONTAINER      IMAGE          CREATED          STATE     NAME                      ATTEMPT   POD ID         POD
7eedd82f32fb4  d19341cfc4183  3 minutes ago    Running   kube-proxy                2         3035d4bf94b65  kube-proxy-v99jw
3cdda0959ae1b  a005f28978e93  3 minutes ago    Running   kube-controller-manager   5         d5e77c278fdfa  kube-controller-manager-ip-10-0-10-11
...
d4b9956e550ae  d19341cfc4183  25 hours ago     Exited    kube-proxy                1         ebde8e6d70620  kube-proxy-v99jw
52ff9f047f205  a005f28978e93  25 hours ago     Exited    kube-controller-manager   4         41ffdeb6ac5c7  kube-controller-manager-ip-10-0-10-11
...
```

同一个名字有一个 `Running`（关机后新建的）和一个或几个 `Exited`（关机前的）。`ATTEMPT` 就是"第几次尝试"，和 RESTARTS 对得上。

```bash
crictl pods
```

Pod 的 sandbox 也一样：每个 Pod 有一个新的 `Ready` sandbox 和一个旧的 `NotReady` sandbox。旧的会在之后被 kubelet 的垃圾回收清理掉。

### 步骤 3：看 kubelet 是怎么把它们拉起来的

```bash
journalctl -u kubelet -b --no-pager | grep -m1 'Adding static pod path'
journalctl -u kubelet -b --no-pager | grep -c 'connection refused'
journalctl -u kubelet -b --no-pager | grep -m1 -o 'dial tcp .*connection refused'
```

`-b` 表示"只看这次开机以来的日志"。预期：

```
... kubelet.go:386] "Adding static pod path" path="/etc/kubernetes/manifests"
7
dial tcp 10.0.10.11:6443: connect: connection refused
```

（`connection refused` 的次数以你的为准，个位数到几十都正常。）

把整个开机过程串起来：

```
开机
 └─ systemd
     ├─ containerd.service（enabled）
     └─ kubelet.service（enabled）
          ├─ 读 /var/lib/kubelet/config.yaml，知道 static pod 目录在哪
          ├─ 按 /etc/kubernetes/manifests 里的 4 个文件，启动 etcd、apiserver、
          │  controller-manager、scheduler
          │     这期间 kubelet 一直连不上 apiserver（connection refused），没关系，
          │     它只看本地文件，照样把控制面拉起来
          ├─ apiserver 起来了 → kubelet 连上它，更新节点状态、登记 mirror pod
          └─ 从 apiserver 领到自己该跑的 kube-proxy（DaemonSet）→ 启动
```

**结论：控制面完全能自己"冷启动"。** 这就是第 03 章 static pod 设计的意义：kubelet 不依赖 apiserver，所以能把 apiserver 本身拉起来。✅ 第 03 章的遗留验收项完成。

---

## 🧠 概念 1：先认识几个新词

今天会第一次用到这些东西：

| 词 | 一句话解释 |
|---|---|
| **CRD**（CustomResourceDefinition） | 给 apiserver **注册一种新的资源类型**。K8s 自带 Pod、Service 这些类型；Calico 用 CRD 注册了 `IPPool`、`IPAMBlock` 等十几种。注册之后，`kubectl get ippools` 就和 `kubectl get pods` 一样好用，数据同样存在 etcd 里 |
| **CR**（Custom Resource） | 某种 CRD 类型的一个具体对象。比如名叫 `default-ipv4-ippool` 的那个 IP 池 |
| **operator** | 一个**自定义的控制器**，专门盯着某种 CR，按它的内容去创建、修复一堆普通对象（DaemonSet、Deployment……）。它就是第 03 章概念 1 里那种"对账员"，只不过是第三方写的 |
| **`kubectl create`** | "新建"。对象已经存在就报错 |
| **`kubectl apply`** | "让它变成这样"（声明式）。不存在就建，存在就改。它会把你提交的整份内容存进对象的一个 annotation（`kubectl.kubernetes.io/last-applied-configuration`），下次 apply 时拿来对比，算出要改哪些字段 |
| **`kubectl exec`** | 在 Pod 的容器里执行一条命令，类似 `docker exec` |

今天要装的东西就是这个结构：

```
你写的：  Installation（CR）       "我要一个 VXLAN 模式的 Calico，IP 池是 192.168.0.0/16"
             │
             ▼  tigera-operator 不停地对账
operator 生成：  calico-node DaemonSet、calico-typha Deployment、IPPool……
             │
             ▼  K8s 自己的控制器
最终：     每个节点上跑起来的 Calico 容器
```

---

## 🧠 概念 2：CNI，谁给 Pod 接网线

第 03 章你看到了：没有网络插件，节点就是 NotReady，CoreDNS 也起不来。网络插件到底要干什么？看一个 Pod 被创建时发生的事：

```
scheduler 把 Pod 分到 cp-1 → cp-1 上的 kubelet
   │  CRI 调用：RunPodSandbox
   ▼
containerd
   ├─ ① 新建一个空的 network namespace（只有一个 lo）
   ├─ ② 读 /etc/cni/net.d/ 里按文件名排第一的配置文件
   └─ ③ 照配置执行 /opt/cni/bin/calico，并通过环境变量告诉它要做什么：
           CNI_COMMAND=ADD   CNI_NETNS=/var/run/netns/cni-xxxx   CNI_IFNAME=eth0
           │
           ├─ 调用 calico-ipam：从 IP 池里领一个 IP
           ├─ 建一对 veth（虚拟网线）：一头放进 Pod 的 netns、改名叫 eth0；
           │  另一头留在宿主机上，叫 caliXXXXXXXX
           ├─ 给 eth0 配上 IP 和路由，给宿主机加一条通往这个 Pod 的路由
           └─ 把分到的 IP 交回给 containerd → kubelet → 写进 Pod 的 status.podIP
```

几个要点：

- **CNI（Container Network Interface）只是一份约定**："网络插件是一个可执行文件，配置是一个 JSON 文件，按这些环境变量调用它"。插件每次被调用，干完活就退出，**不是常驻进程**。删除 Pod 时再用 `CNI_COMMAND=DEL` 调用一次，收回 IP、拆掉网线。
- **containerd 只用排序第一的那个配置文件**。所以配置文件名都带数字前缀，比如 `10-calico.conflist`。
- **"网络就绪"（NetworkReady）看的就是这个配置文件在不在**。不在，containerd 就报告 `cni plugin not initialized`，kubelet 就把节点标成 NotReady。
- **Calico 分成两部分**：CNI 插件是一次性的，负责"接网线"；calico-node 里的 **Felix** 是常驻的，负责持续维护路由、iptables 规则、VXLAN 隧道。

---

## 🧠 概念 3：veth pair，以及同一个节点上的包怎么走

**veth pair** 就是一根虚拟网线：两头各是一块网卡，从一头进去的包，会从另一头出来。

Calico 用它把每个 Pod 的 netns 连到宿主机上：

```
 ┌── net-a 的 netns ──────┐                      ┌── net-b 的 netns ──────┐
 │ eth0  192.168.155.8/32  │                      │ eth0  192.168.155.7/32  │
 │ 默认路由 → 169.254.1.1  │                      │ 默认路由 → 169.254.1.1  │
 └───────────┬────────────┘                      └───────────┬────────────┘
             │ veth pair                                     │ veth pair
 ┌───────────┴──────────────── 宿主机 cp-1 ──────────────────┴────────────┐
 │       caliAAAA                                       caliBBBB           │
 │          │                                              ▲               │
 │          └──► 宿主机路由表：192.168.155.7 dev caliBBBB ──┘               │
 └─────────────────────────────────────────────────────────────────────────┘
```

和你想象的"一个局域网、一台交换机"不同：

- Pod 的地址是 **`/32`**，意思是"我这个网段里只有我自己"，没有任何"同网段的邻居"。
- 所以 Pod 发出的**所有**包，都交给默认网关 `169.254.1.1`，也就是交给宿主机。
- 宿主机就是一台**路由器**：它有一张路由表，每个 Pod 一条，按目的 IP 把包从对应的 `cali` 网卡送出去。

`169.254.1.1` 这个网关是怎么回事？动手 C 再揭秘。

---

## 🧠 概念 4：Calico 的组件

| 组件 | 形式 | 用谁的网络 | 干什么 |
|---|---|---|---|
| **tigera-operator** | Deployment（`tigera-operator` 命名空间） | 宿主机 | 安装和看管 Calico：读你写的 Installation，生成下面所有东西 |
| **calico-node** | DaemonSet，每个节点一个 | 宿主机 | 核心组件。里面跑两个进程：**Felix**（写路由、写 iptables、维护 VXLAN 隧道）和 **node-services**（分配隧道 IP、上报状态等）。因为我们关掉了 BGP，负责 BGP 的 BIRD 和 confd **都不运行** |
| **calico-typha** | Deployment，节点少时 1 个副本 | 宿主机 | apiserver 和各节点 Felix 之间的"中转缓存"。集群有几百个节点时，Felix 们不用都去 watch apiserver |
| **calico-kube-controllers** | Deployment | Pod 网络 | 集群级的清理工作，比如节点删除后回收它占用的 IP |
| **calico-webhooks** × 2 | Deployment | Pod 网络 | 由 `APIServer` 这个 CR 部署：在 apiserver 写入 Calico 对象之前做校验（admission webhook） |
| **csi-node-driver** | DaemonSet | Pod 网络 | 给 Calico 的应用层策略（配合 Istio）用的，我们用不到，留着无害 |
| **CNI 插件** | 二进制文件，装在 `/opt/cni/bin` | — | 概念 2 讲的"接网线"的那个 |

"用谁的网络"这一列很重要：用**宿主机网络**（hostNetwork）的组件不需要 CNI 就能启动。它们是"网络的建设者"，不能依赖网络本身（和第 03 章思考题 5 的 kube-proxy 是一个道理）。

---

## 🧠 概念 5：跨节点怎么走？为什么选 VXLAN

同一个节点上靠路由表就够了。不同节点上的 Pod 怎么通信？常见三种办法：

| 办法 | 怎么做 | 在 AWS 上 |
|---|---|---|
| **直接路由**（用 BGP 交换路由） | Pod 的包原样发到对方节点 | ❌ 被 AWS 丢掉（见下） |
| **IPIP** | 把 Pod 的包装进另一个 IP 包里 | ⚠️ 能用，但安全组要额外放行 IP 协议 4（IPIP），我们没开 |
| **VXLAN** | 把 Pod 的包装进一个 UDP 包里（端口 4789） | ✅ 第 01 章安全组已经放行了 UDP 4789 |

**AWS 为什么会丢掉直接路由的包？** EC2 网卡默认开着 **source/dest check**：每块网卡只能收发"源地址或目的地址是我自己"的包。Pod 的地址 `192.168.x.x` 不是 AWS 分配的，裸着发出去会被直接丢掉。

VXLAN 的做法是"装信封"：

```
原始的包：  [ IP 192.168.155.8 → 192.168.20.5 | 数据 ]
装进信封：  [ IP 10.0.10.11 → 10.0.10.21 | UDP 4789 | VXLAN 头 | 原始的包 ]
             └─ AWS 只看得到外层，源和目的都是节点自己的 IP，放行 ✓
```

**为什么不用官方默认的 `VXLANCrossSubnet`？** 它的意思是"跨子网才装信封，同子网直接发"，在自建机房里能省一点封装开销。但在 AWS 上，"直接发"就会被 source/dest check 丢掉。我们的 cp-1（10.0.10.11）和 worker-1（10.0.10.21）恰好在同一个子网，第 05 章你会亲眼看到这个坑。

**为什么关掉 BGP？** BGP 是给"直接路由"模式在节点之间交换路由用的。VXLAN 模式下，每个节点领了哪些 IP 块都记在 K8s 里，Felix 自己就能算出"去哪个块，该把信封寄给哪个节点"，不需要 BGP。关掉它，节点上就少跑一个 BIRD 进程。

**IP 是怎么分的（IPAM）？** IP 池 `192.168.0.0/16` 被切成一个个 `/26` 的小块（每块 64 个 IP），节点按需"领块"，再从自己的块里给 Pod 分 IP。第 03 章步骤 13 看到 kubeadm 给节点分了 `podCIDR: 192.168.0.0/24`，Calico **不用它**。动手 C 会亲眼看到块和路由的对应关系。

---

## 🛠 动手 B：安装 Calico

### 步骤 4：装之前，先看现场

🖥️ **cp-1（root）：**

```bash
ls -la /etc/cni/net.d
ls /opt/cni/bin
```

预计：

```
total 8
drwxr-xr-x 2 root root 4096 ... .
drwxr-xr-x 3 root root 4096 ... ..
-rw-r--r-- 1 root root    0 ... .kubernetes-cni-keep

LICENSE  README.md  bandwidth  bridge  dhcp  dummy  firewall  host-device  host-local  ipvlan
loopback  macvlan  portmap  ptp  sbr  static  tap  tuning  vlan  vrf
```

咦，插件目录里已经有一堆东西了？查查它们是哪来的：

```bash
dpkg -S /opt/cni/bin/bridge
```

```
kubernetes-cni: /opt/cni/bin/bridge
```

第 02 章装 kubelet 时，apt 顺带装了它的依赖 `kubernetes-cni`：一套 CNI 官方的**参考插件**（bridge、host-local、portmap……）。配置目录里只有一个空的占位文件 `.kubernetes-cni-keep`（以点开头，containerd 会忽略它）。

再问 containerd 网络好了没有：

```bash
crictl info -o go-template --template '{{range .status.conditions}}{{.type}}={{.status}} {{.message}}{{"\n"}}{{end}}'
```

```
RuntimeReady=true
NetworkReady=false Network plugin returns error: cni plugin not initialized
ContainerdHasNoDeprecationWarnings=true
```

**插件有了，配置没有，NetworkReady 就是 false。** 再次印证概念 2：containerd 看的是配置文件。Calico 会补上配置，还会带来它自己的插件。

最后花 10 秒确认没有主机防火墙挡路：

```bash
ufw status                    # Status: inactive
```

### 步骤 5：安装 CRD

先把下载地址存进一个变量，版本固定在 **v3.33.1**：

```bash
U=https://raw.githubusercontent.com/projectcalico/calico/v3.33.1/manifests
```

> 💡 变量只在当前会话里有效。SSM 断线重连后，要重新执行上面这一行。

装之前先做个小实验：如果用平常的 `apply` 会怎样？

```bash
kubectl apply --dry-run=server -f $U/v3_projectcalico_org.yaml 2>&1 | grep 'Too long'
```

`--dry-run=server` 表示"发给 apiserver 走完全部检查，但不真的保存"，不会留下任何东西。预期：

```
The CustomResourceDefinition "installations.operator.tigera.io" is invalid: metadata.annotations: Too long: may not be more than 262144 bytes
```

原因就在概念 1 的表里：`apply` 要把整份内容存进 annotation，而 annotation 总共不能超过 256KB。`Installation` 这个 CRD 的定义有 **1.5MB**（它几乎内嵌了整套 Pod 的字段说明），怎么也塞不进去。所以官方让我们用 `create`：

```bash
kubectl create -f $U/v3_projectcalico_org.yaml | tail -3
```

```
customresourcedefinition.apiextensions.k8s.io/stagednetworkpolicies.projectcalico.org created
customresourcedefinition.apiextensions.k8s.io/tiers.projectcalico.org created
```

（只显示了最后 3 行，前面还有几十行 `created`。）数一数装了什么：

```bash
kubectl get crd | grep -c projectcalico          # 22：Calico 自己的资源类型
kubectl get crd | grep -c operator.tigera        # 9：给 operator 用的，比如 Installation
kubectl api-resources --api-group=projectcalico.org | head -5
```

```
NAME                  SHORTNAMES             APIVERSION             NAMESPACED   KIND
bgpconfigurations     bgpconfig,bgpconfigs   projectcalico.org/v3   false        BGPConfiguration
bgpfilters                                   projectcalico.org/v3   false        BGPFilter
bgppeers                                     projectcalico.org/v3   false        BGPPeer
blockaffinities       affinity,affinities    projectcalico.org/v3   false        BlockAffinity
```

现在 apiserver 已经"认识"这些新类型了，只是里面还没有任何对象。

这个文件里除了 CRD，还有几个 `MutatingAdmissionPolicy`：apiserver 在保存 Calico 对象之前，用它们自动填上默认值。这个功能在 K8s 1.36 才正式可用（GA），所以官方文档特别注明：这个文件**要求 1.36 及以上**，1.34、1.35 要用另一个文件。

> 💡 另一种做法是 `kubectl apply --server-side`：由 apiserver 记录字段归属，不再塞 annotation，也就没有大小问题。官方的迁移文档就是这么用的。初次安装用 `create` 最简单。

### 步骤 6：安装 operator

```bash
kubectl create -f $U/tigera-operator.yaml
kubectl -n tigera-operator get pods -o wide
```

```
namespace/tigera-operator created
serviceaccount/tigera-operator created
...
deployment.apps/tigera-operator created

NAME                               READY   STATUS    RESTARTS   AGE   IP           NODE
tigera-operator-85dfd45867-wzl4p   1/1     Running   0          10s   10.0.10.11   ip-10-0-10-11
```

注意：节点明明是 **NotReady**，这个 Pod 却跑起来了，而且 IP 是节点自己的 `10.0.10.11`。为什么？

```bash
kubectl -n tigera-operator get deploy tigera-operator \
  -o jsonpath='{.spec.template.spec.hostNetwork} {.spec.template.spec.tolerations}{"\n"}'
```

```
true [{"effect":"NoExecute","operator":"Exists"},{"effect":"NoSchedule","operator":"Exists"}]
```

- `hostNetwork: true`：用宿主机的网络，不需要 CNI 分配 IP。
- 两条 `operator: Exists` 的 toleration，没写 `key`：意思是"**任何** taint 我都容忍"。所以 control-plane 和 not-ready 这两块"禁止入内"的牌子都拦不住它（第 03 章步骤 14）。

operator 启动后会自己再补装一个 CRD（`clusternetworkpolicies.policy.networking.k8s.io`），所以 `kubectl get crd --no-headers | wc -l` 会从 31 变成 32，不用奇怪。

现在 operator 只是在等：你还没告诉它要装一个什么样的 Calico。

### 步骤 7：写 Calico 的配置

把下面整段粘贴进去（仓库里也有一份一模一样的：`manifests/ch04-calico/custom-resources.yaml`）：

```bash
cat > /root/calico-custom-resources.yaml <<'EOF'
# Calico 配置（第 04 章）。交给 tigera-operator，由它负责装好、看好 Calico。
# 基于官方 v3.33.1 的 custom-resources.yaml 修改，只保留 Installation 和 APIServer。
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    linuxDataplane: Iptables          # 和 kube-proxy 一样用 iptables（默认值，写出来固定住）
    bgp: Disabled                     # 纯 VXLAN 用不到 BGP，节点上就不跑 BIRD
    nodeAddressAutodetectionV4:
      kubernetes: NodeInternalIP      # 节点 IP 直接用 K8s 记录的 InternalIP，不让 Calico 去猜
    ipPools:
      - name: default-ipv4-ippool
        cidr: 192.168.0.0/16          # 必须和 kubeadm 的 podSubnet 一致
        blockSize: 26                 # 每个节点按 /26（64 个 IP）一块一块地领
        encapsulation: VXLAN          # 官方默认是 VXLANCrossSubnet，在 AWS 上会出问题（第 05 章演练）
        natOutgoing: Enabled          # Pod 访问集群外时，源地址换成节点 IP
        nodeSelector: all()
---
# 名字叫 APIServer，在 v3 CRD 模式下实际部署的是 admission webhook（calico-webhooks）
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
```

和官方默认的 `custom-resources.yaml` 逐项对比：

| 配置项 | 官方默认 | 我们 | 为什么 |
|---|---|---|---|
| `encapsulation` | `VXLANCrossSubnet` | `VXLAN` | 同子网也要装信封，否则被 AWS 丢包（概念 5） |
| `bgp` | 不写（等于开启） | `Disabled` | VXLAN 用不到 BGP（概念 5） |
| `nodeAddressAutodetectionV4` | 不写（找第一块像样的网卡） | `NodeInternalIP` | 和 `kubectl get nodes -o wide` 里的 INTERNAL-IP 保持一致。节点上将来多出别的网卡时，不会猜错 |
| `linuxDataplane` | 不写（等于 `Iptables`） | `Iptables` | 固定住。另外可选 nftables 和 eBPF。第 08 章要看 iptables 规则 |
| `cidr` | `192.168.0.0/16` | 同 | 必须和 kubeadm 的 `podSubnet` 一致。operator 第一次安装时会读 kubeadm 的配置来检查 |
| `blockSize` | `26` | 同 | |
| `natOutgoing` | `Enabled` | 同 | 在 AWS 上必须开，动手 C 和演练 2 会看到为什么 |
| `Goldmane`、`Whisker` | 装 | **不装** | 流量可视化组件，有一个网页界面。省点内存，第 16 章讲 NetworkPolicy 时再考虑 |
| `APIServer` | 装 | 装 | 实际部署的是 webhook（概念 4） |

应用它。这里用 `apply`：文件很小，以后还要改（第 16 章可能加组件），`apply` 正合适。

```bash
kubectl apply -f /root/calico-custom-resources.yaml
```

```
installation.operator.tigera.io/default created
apiserver.operator.tigera.io/default created
```

### 步骤 8：看着它装

```bash
watch -n3 'kubectl get tigerastatus; echo; kubectl get nodes; echo; kubectl -n calico-system get pods; echo; kubectl -n kube-system get pods -l k8s-app=kube-dns'
```

镜像要经过 NAT 从 quay.io 下载，**大约 1~3 分钟**。你会看到大致这样的顺序：

1. operator 建好 `calico-system` 命名空间，先启动用宿主机网络的 **calico-typha** 和 **calico-node**。
2. calico-node 的几个 init 容器依次运行，其中 `install-cni` 把 Calico 的插件和**配置文件**写进 `/opt/cni/bin` 和 `/etc/cni/net.d`。
3. 配置文件一出现，containerd 报告 NetworkReady，**节点变成 Ready**，not-ready 的 taint 被摘掉。
4. 需要 Pod 网络的那些 Pod（**CoreDNS**、calico-kube-controllers、calico-webhooks、csi-node-driver）终于可以创建了：`ContainerCreating` → `Running`。

中途 tigerastatus 可能出现这样的报错，**不用管，等一会儿它自己会好**：

```
apiserver   False   True   True   13s   Error creating / updating resource: ... failed calling webhook
            "tiered-rbac.api.projectcalico.org": ... connect: connection refused
```

operator 要创建的某些对象，需要先经过 calico-webhooks 校验，可那时 webhook 的 Pod 自己还没起来（它也在等网络）。又一个"鸡生蛋"，operator 会不停重试，等 webhook 就绪就过去了。

最终画面（按 `Ctrl+C` 退出 watch）：

```
NAME        AVAILABLE   PROGRESSING   DEGRADED   SINCE
apiserver   True        False         False      30s
calico      True        False         False      35s
ippools     True        False         False      50s
tiers       True        False         False      50s

NAME            STATUS   ROLES           AGE   VERSION
ip-10-0-10-11   Ready    control-plane   1d    v1.36.6

NAME                                       READY   STATUS    RESTARTS   AGE
calico-kube-controllers-5885c74695-f9zgc   1/1     Running   0          50s
calico-node-bzrqt                          1/1     Running   0          50s
calico-typha-6bc8bb6c79-nlnss              1/1     Running   0          50s
calico-webhooks-7bddfb755-k289f            1/1     Running   0          50s
calico-webhooks-7bddfb755-rjwhv            1/1     Running   0          50s
csi-node-driver-ltbfd                      2/2     Running   0          50s

NAME                       READY   STATUS    RESTARTS   AGE
coredns-589f44dc88-djh7g   1/1     Running   0          1d
coredns-589f44dc88-kqb4l   1/1     Running   0          1d
```

🎉 **节点 Ready，CoreDNS Running。** 从第 03 章 init 到现在，集群第一次完整了。

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
```

CoreDNS 的 IP 是 `192.168.x.x`：这是它们第一次拿到 Pod 网络的 IP。第三段数字（这里是 155）是随机领到的块，你的会不一样。

### 步骤 9：Calico 在节点上留下了什么

**配置文件：**

```bash
ls -la /etc/cni/net.d
```

```
-rw-r--r-- 1 root root    0 ... .kubernetes-cni-keep
-rw------- 1 root root  755 ... 10-calico.conflist
-rw------- 1 root root 2801 ... calico-kubeconfig
```

```bash
python3 -m json.tool /etc/cni/net.d/10-calico.conflist
```

（原文件挤在一行里，`json.tool` 把它排版得好读一些。）挑重点看：

```
{
    "name": "k8s-pod-network",
    "cniVersion": "1.0.0",
    "plugins": [
        {
            ...
            "ipam": {
                "type": "calico-ipam"                   ← 分 IP 的插件
            },
            "kubernetes": {
                "k8s_api_root": "https://10.96.0.1:443",
                "kubeconfig": "/etc/cni/net.d/calico-kubeconfig"   ← 插件访问 apiserver 用的身份
            },
            "log_file_path": "/var/log/calico/cni/cni.log",        ← 插件的日志，步骤 12 会看
            "mtu": 0,                                   ← 0 = 自动探测
            "type": "calico"                            ← 执行 /opt/cni/bin/calico
        },
        {
            "capabilities": { "portMappings": true },
            "type": "portmap"                           ← 第二个插件：支持 Pod 的 hostPort
        }
    ]
}
```

`.conflist` 里可以串好几个插件，containerd 按顺序依次调用。

**CNI 插件的身份。** 插件要访问 apiserver（领 IP、登记 Pod 的网络信息），用的就是 `calico-kubeconfig`。它是谁？

```bash
kubectl auth whoami --kubeconfig /etc/cni/net.d/calico-kubeconfig
```

```
ATTRIBUTE   VALUE
Username    system:serviceaccount:calico-system:calico-cni-plugin
Groups      [system:serviceaccounts system:serviceaccounts:calico-system system:authenticated]
```

不是证书，而是一个 **ServiceAccount**（Pod 用的身份）的 token。还记得第 03 章概念 3 的表格吗？最后一行 `sa.key`"给 ServiceAccount 签发 token"，签的就是这种东西。这个 token 24 小时过期，calico-node 会定期换新的写进来。

**插件二进制：**

```bash
ls /opt/cni/bin
cmp /opt/cni/bin/calico /opt/cni/bin/calico-ipam && echo "是同一个文件"
ls -lh /opt/cni/bin/calico
```

多了 `calico`、`calico-ipam`、`flannel` 三个。`calico` 和 `calico-ipam` 其实**是同一个程序**，它看自己被叫作什么名字来决定干哪份活。文件有一百多 MB：从 v3.33 起，Calico 几乎所有组件都编进了这一个程序。（`flannel` 是给另一种安装方式准备的，我们用不到。）

**MTU：**

```bash
cat /var/lib/calico/mtu
```

预计是 **`8951`**：AWS VPC 内部的网卡 MTU 是 9001（"巨型帧"），减去 VXLAN 信封占的 50 字节。配置文件里写 `mtu: 0`，意思就是"用这个探测出来的值"。

**节点的状态：**

```bash
crictl info -o go-template --template '{{range .status.conditions}}{{.type}}={{.status}} {{.message}}{{"\n"}}{{end}}'
kubectl describe node ip-10-0-10-11 | grep -E 'Taints|NetworkUnavailable|^\s+Ready'
```

```
RuntimeReady=true
NetworkReady=true
ContainerdHasNoDeprecationWarnings=true

Taints:             node-role.kubernetes.io/control-plane:NoSchedule
  NetworkUnavailable   False   ...   CalicoIsUp     Calico is running on this node
  Ready                True    ...   KubeletReady   kubelet is posting ready status
```

`not-ready` 的 taint 没了，只剩 control-plane 那一个。`NetworkUnavailable` 是 Calico 自己写到节点上的一个状态，原因 `CalicoIsUp`。

**节点上的 Calico 标记：**

```bash
kubectl get node ip-10-0-10-11 -o yaml | grep 'projectcalico.org/IPv4'
```

```
    projectcalico.org/IPv4Address: 10.0.10.11/24
    projectcalico.org/IPv4VXLANTunnelAddr: 192.168.155.0
```

第一行是 Calico 认定的节点地址（来自 `NodeInternalIP`）；第二行是这个节点 VXLAN 隧道的地址，步骤 19 会用到。

### 步骤 10：calico-system 一览

```bash
kubectl -n calico-system get pods -o wide
```

```
NAME                                       READY   STATUS    IP              NODE
calico-kube-controllers-5885c74695-f9zgc   1/1     Running   192.168.155.2   ip-10-0-10-11
calico-node-bzrqt                          1/1     Running   10.0.10.11      ip-10-0-10-11
calico-typha-6bc8bb6c79-nlnss              1/1     Running   10.0.10.11      ip-10-0-10-11
calico-webhooks-7bddfb755-k289f            1/1     Running   192.168.155.5   ip-10-0-10-11
calico-webhooks-7bddfb755-rjwhv            1/1     Running   192.168.155.6   ip-10-0-10-11
csi-node-driver-ltbfd                      2/2     Running   192.168.155.1   ip-10-0-10-11
```

对照概念 4 的表格：IP 是 `10.0.10.11` 的，就是用宿主机网络的那几个。

calico-node 里到底跑了哪些进程？

```bash
kubectl -n calico-system exec ds/calico-node -c calico-node -- ls /etc/service/enabled
```

```
felix
node-services
```

只有两个。没有 `bird`、没有 `confd`，因为 BGP 关掉了。

再看 operator 按你的 Installation 生成的 IP 池：

```bash
kubectl get ippools -o wide
```

```
NAME                  CIDR             VXLAN    IPIP    NAT    ALLOCATABLE   AGE
default-ipv4-ippool   192.168.0.0/16   Always   Never   true   True          2m
```

`VXLAN Always`（任何时候都装信封）、`IPIP Never`、`NAT true`，和你写的配置一一对应。

**（选做）** Felix 的全局配置：

```bash
kubectl get felixconfiguration default -o yaml | sed -n '/^spec:/,$p'
```

能看到 `vxlanPort: 4789`、`vxlanVNI: 4096`（VXLAN 网络的编号）、`bpfEnabled: false`、`nftablesMode: Disabled` 等。operator 帮你填好了，平时不用碰。

---

## 🛠 动手 C：拆开一个节点上的 Pod 网络

### 步骤 11：起两个测试 Pod

这是你第一次自己写 Pod 的 YAML。把下面整段粘贴进去（仓库里的 `manifests/ch04-calico/net-test.yaml` 一模一样）：

```bash
cat > /root/net-test.yaml <<'EOF'
# 第 04 章的测试 Pod：两个什么都不干、只是活着的 busybox，用来拆解 Pod 网络。
apiVersion: v1
kind: Pod
metadata:
  name: net-a
  labels:
    app: net-test
spec:
  containers:
    - name: box
      image: public.ecr.aws/docker/library/busybox:1.37   # 和第 02 章同一个镜像，ECR 公共仓库不限速
      command: ["sleep", "86400"]                          # 睡一天，保持 Pod 一直在线
  tolerations:                                             # 允许调度到 control plane 上（第 03 章步骤 14）
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
  terminationGracePeriodSeconds: 2                         # sleep 不理 SIGTERM（第 02 章），删除时少等一会儿
---
apiVersion: v1
kind: Pod
metadata:
  name: net-b
  labels:
    app: net-test
spec:
  containers:
    - name: box
      image: public.ecr.aws/docker/library/busybox:1.37
      command: ["sleep", "86400"]
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
  terminationGracePeriodSeconds: 2
EOF
```

逐段看一个 Pod 的结构：

| 部分 | 意思 |
|---|---|
| `apiVersion: v1`、`kind: Pod` | 这是什么类型的对象。每个 K8s 对象都有这两行 |
| `metadata` | 名字、标签。`app: net-test` 这个标签让我们以后可以一次选中这两个 Pod |
| `spec.containers` | Pod 里跑哪些容器：名字、镜像、启动命令 |
| `tolerations` | "通行证"。cp-1 挂着 control-plane 的"禁止入内"牌子，不带通行证的普通 Pod 进不去，而我们现在只有这一个节点 |
| `terminationGracePeriodSeconds` | 删除时，先发 SIGTERM，等这么多秒再强杀。默认 30 秒。`sleep` 作为 PID 1 不理 SIGTERM（第 02 章 ctr 实验），所以设短一点 |
| `---` | 一个文件里放两个对象 |

> 💡 用 toleration 而不是"把 control-plane 的 taint 摘掉"：后者虽然也能让 Pod 调度上来，但会留下一个"以后要记得恢复"的状态。

```bash
kubectl apply -f /root/net-test.yaml
kubectl wait --for=condition=Ready pod -l app=net-test --timeout=120s
kubectl get pods -o wide
```

```
NAME    READY   STATUS    RESTARTS   AGE   IP              NODE            NOMINATED NODE   READINESS GATES
net-a   1/1     Running   0          5s    192.168.155.8   ip-10-0-10-11   <none>           <none>
net-b   1/1     Running   0          5s    192.168.155.7   ip-10-0-10-11   <none>           <none>
```

`kubectl wait` 会一直等到两个 Pod 都 Ready 才返回，比反复 `get` 省事。把两个 IP 存进变量，后面要用很多次：

```bash
A=$(kubectl get pod net-a -o jsonpath='{.status.podIP}')
B=$(kubectl get pod net-b -o jsonpath='{.status.podIP}')
echo "net-a=$A  net-b=$B"
```

看看 Pod 身上被贴了什么：

```bash
kubectl get pod net-a -o yaml | sed -n '/^  annotations:/,/^  creationTimestamp/p' | cut -c1-100
```

```
  annotations:
    cni.projectcalico.org/containerID: d681c506072e4b7106b7ca916a9926ebfa00aa96e71b6132bd94108024858
    cni.projectcalico.org/podIP: 192.168.155.8/32
    cni.projectcalico.org/podIPs: 192.168.155.8/32
    kubectl.kubernetes.io/last-applied-configuration: |
      {"apiVersion":"v1","kind":"Pod","metadata":{"annotations":{},"labels":{"app":"net-test"},"name
```

- 前三行是 CNI 插件写的：它给哪个容器（sandbox）分了哪个 IP。
- 最后一行就是概念 1 说的 `apply` 存下来的那份"上次提交的内容"。步骤 5 里 CRD 塞不进去的，就是这个 annotation。

### 步骤 12：CNI 插件的工作记录

概念 2 说 containerd 调用了 CNI 插件。插件的日志能证明这一点：

```bash
ID=$(kubectl get pod net-a -o jsonpath='{.metadata.annotations.cni\.projectcalico\.org/containerID}')
grep "$ID" /var/log/calico/cni/cni.log | grep -E 'CmdAddK8s|IPAM assigned|host side' | sed -E 's/ (ContainerID|HandleID)=.*//'
```

```
2026-11-17 23:27:50.135 [INFO][3609] cni-plugin/k8s.go 75: Extracted identifiers for CmdAddK8s
2026-11-17 23:27:50.248 [INFO][3609] cni-plugin/ipam_plugin.go 453: Calico CNI IPAM assigned addresses IPv4=[192.168.155.8/26] IPv6=[]
2026-11-17 23:27:50.248 [INFO][3609] cni-plugin/dataplane_linux.go 81: Setting the host side interface name to califf9370bf9a9
```

正好是概念 2 图里的三步：收到 **ADD** 命令 → 调 IPAM **领到 IP** → 建 veth，**宿主机那头**命名为 `califf9370bf9a9`。整个过程大约 0.1 秒。

### 步骤 13：从 Pod 里面看

```bash
kubectl exec net-a -- ip addr show eth0
kubectl exec net-a -- ip route
```

```
11: eth0@if22: <BROADCAST,MULTICAST,UP,LOWER_UP,M-DOWN> mtu 8951 qdisc noqueue qlen 1000
    link/ether 3e:1c:17:d6:07:5c brd ff:ff:ff:ff:ff:ff
    inet 192.168.155.8/32 scope global eth0

default via 169.254.1.1 dev eth0
169.254.1.1 dev eth0 scope link
```

- 地址是 **`/32`**：没有"同网段的邻居"（概念 3）。
- MTU 预计是 `8951`，和步骤 9 看到的一样。
- 默认路由指向 **`169.254.1.1`**。这是一个"链路本地"地址，**节点上根本没有任何网卡用这个 IP**。

去 ping 一下 net-b，然后看看 Pod 的"邻居表"（ARP 表）：

```bash
kubectl exec net-a -- ping -c2 $B
kubectl exec net-a -- ip neigh
```

```
64 bytes from 192.168.155.7: seq=0 ttl=63 time=0.073 ms
64 bytes from 192.168.155.7: seq=1 ttl=63 time=0.142 ms

169.254.1.1 dev eth0 lladdr ee:ee:ee:ee:ee:ee ref 1 used 0/0/0 probes 4 REACHABLE
```

两个线索：

- **`ttl=63`**：包每经过一台路由器，TTL 减 1。busybox 发出时是 64，到达 net-b 时是 63，说明中间**经过了一次路由**，就是宿主机。
- **`169.254.1.1` 的 MAC 是 `ee:ee:ee:ee:ee:ee`**：一个明显是人为设定的地址。Pod 问"谁是 169.254.1.1？"，有人用这个 MAC 回答了。是谁？去宿主机上找。

先记下 eth0 的"另一头"在宿主机上的编号：

```bash
kubectl exec net-a -- cat /sys/class/net/eth0/iflink        # 例如 22
```

### 步骤 14：从宿主机看

```bash
IFL=$(kubectl exec net-a -- cat /sys/class/net/eth0/iflink)
ip link | grep -A1 "^$IFL:"
```

```
22: califf9370bf9a9@if11: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 8951 qdisc noqueue state UP mode DEFAULT group default
    link/ether ee:ee:ee:ee:ee:ee brd ff:ff:ff:ff:ff:ff link-netns cni-db34ed7b-8aab-56b5-b24c-52493bcece11
```

- 名字 `califf9370bf9a9`，和步骤 12 日志里的一模一样。
- **MAC 就是 `ee:ee:ee:ee:ee:ee`**。所有 `cali` 网卡都用这个 MAC。
- `link-netns cni-db34...`：这根网线的另一头在这个 network namespace 里，也就是 net-a。

再看宿主机的路由表：

```bash
ip route
```

```
default via 10.0.10.1 dev ens5 proto dhcp src 10.0.10.11 metric 100
10.0.10.0/24 dev ens5 proto kernel scope link src 10.0.10.11 metric 100
...
blackhole 192.168.155.0/26 proto 80
192.168.155.1 dev cali636d72b997d scope link metric 1024
192.168.155.2 dev cali5b75d23eeb8 scope link metric 1024
...
192.168.155.7 dev caliddf56ddca0d scope link metric 1024
192.168.155.8 dev califf9370bf9a9 scope link metric 1024
```

**每个 Pod 一条 `/32` 路由**，指向它的 `cali` 网卡。`blackhole` 那一行步骤 15 再说。（你的路由表里可能还有几行 AWS 自己的，比如 `169.254.169.253` 等，不用管。）

最后一块拼图：

```bash
CALI_A=$(ip route | awk -v ip=$A '$1==ip {print $3}')
echo $CALI_A
cat /proc/sys/net/ipv4/conf/$CALI_A/proxy_arp        # 1
```

**`proxy_arp = 1`**：这块网卡会替别人回答 ARP。Pod 问"谁是 169.254.1.1？"，宿主机这头的 `cali` 网卡说"是我"，报上自己的 MAC `ee:ee:ee:ee:ee:ee`。

现在 net-a ping net-b 的完整路径清楚了：

```
net-a 想发给 192.168.155.7
  ① 查自己的路由表：/32 没有邻居 → 交给默认网关 169.254.1.1
  ② ARP 问 169.254.1.1 的 MAC → califf93... 代答 ee:ee:ee:ee:ee:ee
  ③ 包从 eth0 发出，从宿主机的 califf93... 冒出来
  ④ 宿主机查路由表：192.168.155.7 dev caliddf5... → 从那块网卡送出（TTL 64→63）
  ⑤ 包从 net-b 的 eth0 冒出来
```

这就是"纯三层"：没有网桥、没有交换机，全靠宿主机的路由表。

### 步骤 15：IPAM，IP 是从哪来的

```bash
kubectl get ipamblocks
kubectl get blockaffinities
```

```
NAME               CIDR               AFFINITY             CLAIMTIME
192-168-155-0-26   192.168.155.0/26   host:ip-10-0-10-11   10m

NAME                             CIDR               NODE            TYPE
ip-10-0-10-11-192-168-155-0-26   192.168.155.0/26   ip-10-0-10-11   host
```

cp-1 从 `192.168.0.0/16` 这个池子里领了一个 `/26` 的块 `192.168.155.0/26`（64 个地址：.0 ~ .63）。这台机器上所有 Pod 的 IP 都从这里分：

- `.0` 给了 VXLAN 隧道（步骤 9 节点上那个 `IPv4VXLANTunnelAddr`）
- `.1` ~ `.6` 给了 csi-node-driver、calico-kube-controllers、两个 CoreDNS、两个 calico-webhooks
- `.7`、`.8` 是你的 net-b、net-a

（具体哪个 Pod 拿到哪个数字，取决于创建的先后，你的顺序可能不同。）

再看步骤 14 路由表里那一行：

```
blackhole 192.168.155.0/26 proto 80
```

**这个块和这条 blackhole 路由说的是同一件事**："`192.168.155.0/26` 归我管。块里已经分出去的地址，各有一条更精确的 `/32` 路由；**没分出去的，一律丢弃**"。如果没有它，发往一个空地址的包会顺着默认路由跑去 NAT 实例，在网络里白白绕圈。

最后对比一下 kubeadm 给的那个网段：

```bash
kubectl get node ip-10-0-10-11 -o jsonpath='{.spec.podCIDR}{"\n"}'      # 192.168.0.0/24
```

`192.168.0.0/24` 和 Calico 实际用的 `192.168.155.0/26` 毫无关系：Calico 有自己的 IPAM，**不用** `podCIDR`（第 03 章步骤 13 预告过）。

### 步骤 16（选做）：Pod 就是一个 network namespace

第 02 章你用 `unshare` 亲手造过一个 network namespace。现在看看 containerd 替 Pod 造的那个：

```bash
P=$(crictl pods --name net-a -q)
PID=$(crictl inspectp -o go-template --template '{{.info.pid}}' $P)
ps -o pid,comm -p $PID                   # pause：Pod 里第一个进程，专门"占住"这些 namespace
nsenter -t $PID -n ip -br addr           # 钻进它的 netns 看网卡
```

```
    PID COMMAND
   3743 pause

lo               UNKNOWN        127.0.0.1/8 ::1/128
eth0@if22        UP             192.168.155.8/32 fe80::3c1c:17ff:fed6:75c/64
```

（如果还看到 `tunl0`、`gre0` 之类状态是 DOWN 的设备，是内核加载了隧道模块后每个 netns 自带的，忽略即可。）

`nsenter -t PID -n` 的意思是"进入这个进程的 network namespace，再执行后面的命令"。效果和 `kubectl exec net-a -- ip addr` 一样，但完全不经过 K8s，排查问题时很有用（比如 Pod 里没有 `ip` 命令）。

```bash
ip netns list | head -3
```

每个用 Pod 网络的 Pod 都有一个 `cni-xxxx`，其中一个就是步骤 14 里 `link-netns` 后面那个名字。

### 步骤 17（选做）：抓包看一眼

```bash
command -v tcpdump || apt-get install -y tcpdump

CALI_B=$(ip route | awk -v ip=$B '$1==ip {print $3}')
timeout 10 tcpdump -ni $CALI_B -c 4 icmp & sleep 1; kubectl exec net-a -- ping -c2 $B >/dev/null; wait
```

这一行先在后台开始抓 net-b 那块 `cali` 网卡的包（最多抓 4 个、最多 10 秒），1 秒后再 ping，最后 `wait` 等抓包结束。只有一个 SSM 窗口也能做。

```
listening on caliddf56ddca0d, link-type EN10MB (Ethernet), snapshot length 262144 bytes
23:28:32.244364 IP 192.168.155.8 > 192.168.155.7: ICMP echo request, id 41, seq 0, length 64
23:28:32.244738 IP 192.168.155.7 > 192.168.155.8: ICMP echo reply, id 41, seq 0, length 64
...
```

源和目的都是 Pod 的真实 IP，没有任何 NAT，也没有封装。同一个节点内就是这么直接。

### 步骤 18：访问外网，以及两层 NAT

```bash
kubectl exec net-a -- wget -T5 -qO- http://checkip.amazonaws.com
curl -s https://checkip.amazonaws.com
```

`checkip.amazonaws.com` 会告诉你"你在互联网上看起来是哪个 IP"。两条命令输出**同一个 IP**：NAT 实例的公网 IP。（它不是固定 IP，每次 lab-up 都会变，第 01 章讲过。）

Pod 的 `192.168.155.8` 是怎么变成这个 IP 的？经过了**两次** MASQUERADE：

```
net-a  源 192.168.155.8
  │
  ▼  ① cp-1：Calico 的 natOutgoing 规则，源换成 10.0.10.11
cp-1   源 10.0.10.11
  │
  ▼  ② NAT 实例：第 01 章那条 MASQUERADE 规则，源换成 NAT 的公网 IP
互联网
```

第 ① 步的规则：

```bash
iptables -t nat -S cali-nat-outgoing
```

```
-N cali-nat-outgoing
-A cali-nat-outgoing -m comment --comment "cali:W_qq_N2KSTWyCvrX" -m set --match-set cali40masq-ipam-pools src -m set ! --match-set cali40network-ip-pools dst -j MASQUERADE --random-fully
```

读法：源地址在 `cali40masq-ipam-pools` 这个集合里、**并且**目的地址**不在** `cali40network-ip-pools` 里，就做 MASQUERADE。这两个集合（ipset）里装的就是 IP 池：

```bash
kubectl -n calico-system exec ds/calico-node -c calico-node -- ipset list cali40masq-ipam-pools | tail -2
```

```
Members:
192.168.0.0/16
```

翻译成人话：**Pod 访问 Pod 不改地址；Pod 访问集群外，把源地址换成节点 IP。**

在 AWS 上，第 ① 步**必不可少**，原因有三层：

1. 节点网卡开着 source/dest check：源地址是 `192.168.x.x` 的包出不了 cp-1 的网卡（概念 5）。
2. 就算出去了，NAT 实例的规则只处理 `-s 10.0.0.0/16`（第 01 章），不认识 `192.168.x.x`。
3. 就算发出去了，回程的包要回到 `192.168.x.x`，VPC 的路由表里也没有这条路。

演练 2 会亲手关掉它看看。

> 💡 `iptables -V` 显示 `(nf_tables)`：Ubuntu 24.04 上的 iptables 命令底层其实写的是 nftables，Calico 会自动探测并跟着用。规则的写法和读法都不变。

**DNS 也通了：**

```bash
kubectl exec net-a -- cat /etc/resolv.conf
kubectl exec net-a -- nslookup kubernetes.default.svc.cluster.local
```

```
search default.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5

Server:		10.96.0.10
Address:	10.96.0.10:53

Name:	kubernetes.default.svc.cluster.local
Address: 10.96.0.1
```

`10.96.0.10` 是 CoreDNS 的 Service 地址。它刚刚才跑起来，现在整个集群的"通讯录"开始工作了。（`nslookup` 用全名，是为了避免 busybox 把搜索域逐个试一遍、打印一堆 NXDOMAIN 的干扰。DNS 的细节第 08 章讲。）

### 步骤 19：VXLAN 隧道，先看一眼

```bash
ip -d link show vxlan.calico | head -3
ip -br addr show vxlan.calico
```

预计：

```
12: vxlan.calico: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 8951 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 66:46:0e:62:cc:e0 brd ff:ff:ff:ff:ff:ff promiscuity 0 allmulti 0 minmtu 68 maxmtu 65535
    vxlan id 4096 local 10.0.10.11 dev ens5 srcport 0 0 dstport 4789 ttl auto ageing 300 nolearning ...

vxlan.calico     UNKNOWN        192.168.155.0/32 fe80::6446:eff:fe62:cce0/64
```

- `vxlan id 4096`、`dstport 4789`：和步骤 10 的 felixconfiguration 一致。
- `local 10.0.10.11 dev ens5`：信封上的"寄件地址"就是节点 IP，从 ens5 网卡发出。
- 地址 `192.168.155.0`：就是块里的 `.0`，也就是节点上那个 `IPv4VXLANTunnelAddr`。
- MTU 8951：这块"虚拟网卡"自己就要扣掉信封的 50 字节。

隧道建好了，但现在有路由用它吗？

```bash
ip route | grep vxlan.calico          # 什么都没有
```

**还没有**：集群里没有别的节点，没有别的块可去。第 05 章 worker 加入后，这里会出现形如 `192.168.x.0/26 via 192.168.x.0 dev vxlan.calico onlink` 的路由，每个远端块一条。到时候我们抓 UDP 4789 的包，看信封里装的是什么。

---

## ✅ 验证

全部打勾，本章就完成了：

- [ ] 开工自检：lab-up 之后，控制面 Pod 全部自己回到 Running（动手 A）
- [ ] `kubectl get nodes`：**Ready**；`crictl info` 里 `NetworkReady=true`
- [ ] `kubectl get tigerastatus`：4 行全部 `AVAILABLE True`
- [ ] `kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide`：2 个 CoreDNS 都 Running，IP 是 `192.168.x.x`
- [ ] `kubectl exec net-a -- ping -c2 $B` 通；`nslookup kubernetes.default.svc.cluster.local` 能解析
- [ ] Pod 里 `wget checkip` 的结果和 cp-1 上 `curl checkip` 的结果相同
- [ ] `kubectl get blockaffinities` 里有 cp-1 的块，和 `ip route` 里的 `blackhole` 那一行对得上

---

## 🔍 深入原理

### 1. 为什么不用网桥：169.254.1.1 和 proxy ARP

很多网络方案（Docker 默认的 `docker0`、flannel 的 `cni0`）用的是**网桥**：同一台机器上的容器在一个二层网段里，互相直接 ARP、直接通信，网桥就像一台虚拟交换机。第 02 章深入原理里的 `br_netfilter` 就是为这种方案准备的：没有它，iptables 看不到网桥内部转发的包。

Calico 选择了**纯三层**：

- **每个包都经过宿主机的路由**，iptables 天然能看到所有流量。这是 Calico 实现 NetworkPolicy（第 16 章）的基础，也不需要 `br_netfilter`。
- **没有广播域**，没有 ARP 广播风暴，一个节点上有几百个 Pod 也不怕。
- **本机和远端是同一个模型**：去本机的 Pod 是一条 `/32 dev caliX` 路由，去远端的 Pod 是一条 `/26 via vxlan.calico` 路由。都是"查路由表"，没有特殊情况。

`169.254.1.1` 只是一个"占位网关"：Pod 总得有个默认网关，而有了 proxy ARP，网关写成什么地址宿主机都会代答。选 `169.254.x.x` 这个链路本地网段，是因为它永远不会和真实网络里的地址冲突。所有 `cali` 网卡共用 MAC `ee:ee:ee:ee:ee:ee`，这样 veth 重建后 Pod 里缓存的 MAC 也依然有效。

### 2. IP 块：为什么是 /26，用完了怎么办

- **为什么要分块**：如果按 Pod 一个个分 IP，跨节点时每个远端 Pod 都需要一条路由。按块分，每个远端**块**只要一条路由，路由表小得多。
- **为什么是 /26**：64 个地址，对大多数节点够用，又不会太浪费。256 个节点也只用掉 `/16` 池子的四分之一。
- **块用完了**：节点会再领一个新块（每个节点上的 Pod 数默认最多 110，所以一个繁忙的节点常有 2 个块）。如果池子里的空块都领完了，节点会从别的节点的块里"借"单个 IP，这时就会出现跨节点的 `/32` 路由。
- **为什么还要 podSubnet 和池子一致**：Calico 不用 podCIDR，但 kube-proxy 用。kubeadm 把 `podSubnet` 写进了 kube-proxy 的 `clusterCIDR`（`kubectl -n kube-system get cm kube-proxy -o yaml | grep clusterCIDR`），kube-proxy 靠它判断"这个流量是不是来自集群内部"。见思考题 3。

### 3. MTU：9001 − 50 = 8951

AWS VPC 内部支持 9001 字节的"巨型帧"。VXLAN 给每个包加了 50 字节的信封（外层 IP 20 + UDP 8 + VXLAN 头 8 + 内层以太网头 14），所以 Pod 的 MTU 必须再小 50，否则装进信封后就超过了 9001。Calico 探测到宿主机网卡的 MTU，算出 8951，写进 `/var/lib/calico/mtu`。

但去互联网的路径上 MTU 只有 1500，Pod 发大包会不会出问题？对 TCP 来说基本不会：建立连接时双方会交换 MSS（"我最多能收多大的数据段"），对方会报一个按 1500 算出的值，大家按小的来。万一中途还有更小的链路，靠 ICMP "需要分片"消息来调整，第 01 章安全组已经放行了 ICMP。

### 4. operator：谁说了算

```
Installation（你改这里）
   │ operator 渲染、对账
   ▼
DaemonSet / Deployment / IPPool（operator 管，你别直接改）
   │ K8s 的控制器
   ▼
Pod
```

operator 生成的对象身上都带着标签 `app.kubernetes.io/managed-by: tigera-operator`：

```bash
kubectl get ippool default-ipv4-ippool -o jsonpath='{.metadata.labels}{"\n"}'
```

你直接改下层对象，operator 下一轮对账时会发现"和 Installation 说的不一样"，然后改回去。演练 2 会亲手验证这一点。这和第 07 章 Deployment → ReplicaSet → Pod 的关系是同一个模式：**永远改最上层**。

另外，本章装的是 Calico 的"v3 CRD"模式：`IPPool` 这些资源直接就是 K8s 的 CRD，`kubectl` 能直接读写。早期版本的 Calico 要么必须用它自己的命令行工具 `calicoctl`，要么要额外跑一个 Calico API server。很多网上的老教程里还能看到 `calicoctl get ippool`，现在用 `kubectl get ippools` 就行。

---

## 💥 故意搞坏

### 演练 1：CNI 的配置文件没了

先备份，再删掉配置文件：

🖥️ **cp-1（root）：**

```bash
cp /etc/cni/net.d/10-calico.conflist /root/10-calico.conflist.bak
rm /etc/cni/net.d/10-calico.conflist
```

> ⚠️ **只删这一个文件，千万不要删整个 `/etc/cni/net.d` 目录。** containerd 一直盯着这个目录，目录本身消失会让它直接崩溃退出。

等几秒：

```bash
kubectl get nodes
crictl info -o go-template --template '{{range .status.conditions}}{{.type}}={{.status}} {{.message}}{{"\n"}}{{end}}'
kubectl describe node ip-10-0-10-11 | grep -A1 Taints
```

```
NAME            STATUS     ROLES           AGE   VERSION
ip-10-0-10-11   NotReady   control-plane   1d    v1.36.6

RuntimeReady=true
NetworkReady=false Network plugin returns error: cni plugin not initialized
...

Taints:             node-role.kubernetes.io/control-plane:NoSchedule
                    node.kubernetes.io/not-ready:NoSchedule
```

5 秒左右节点就变回 NotReady，not-ready 的 taint 也回来了。和第 03 章一模一样，**只因为少了一个文件**。

已经在跑的 Pod 呢？

```bash
kubectl exec net-a -- ping -c2 $B
```

**照样通。** veth、路由、iptables 规则都已经在内核里了，不会因为配置文件消失而被拆掉。配置文件只影响"以后新建的 Pod"。

那就新建一个试试。用 `sed` 从测试文件里截出 net-a 那一段，改名成 net-c：

```bash
sed -n '1,/^---/p' /root/net-test.yaml | sed 's/net-a/net-c/' | kubectl apply -f -
sleep 5
kubectl get pod net-c
kubectl get events --field-selector involvedObject.name=net-c | tail -1
```

```
NAME    READY   STATUS    RESTARTS   AGE
net-c   0/1     Pending   0          5s

LAST SEEN   TYPE      REASON             OBJECT      MESSAGE
5s          Warning   FailedScheduling   pod/net-c   0/1 nodes are available: 1 node(s) had untolerated taint(s). ...
```

net-c 只带了 control-plane 的通行证，没带 not-ready 的，所以 scheduler 根本不让它上这个节点，停在 **Pending**。

> 💡 节点 NotReady 好几分钟，上面的 net-a、net-b 会不会被赶走？**单节点集群里不会**：当所有节点都不健康时，K8s 认为"多半是网络或控制面自己出了问题，而不是节点真坏了"，会停止一切驱逐。第 05 章有了多个节点，停掉一台的 kubelet，你会看到完全不同的行为。

> ⚠️ 演练期间不要删测试 Pod：拆掉 Pod 的网络也需要调用 CNI 插件，配置文件没了，Pod 可能卡在 Terminating。

**恢复。** 配置文件是谁写的？概念 4 说过，是 calico-node 的 init 容器 `install-cni`。init 容器只在 Pod 启动时运行，所以把 calico-node 的 Pod 删掉，让 DaemonSet 重建一个：

```bash
kubectl -n calico-system delete pod -l k8s-app=calico-node
kubectl get nodes -w                  # 大约 15 秒后变 Ready，按 Ctrl+C 退出
```

```bash
cmp /etc/cni/net.d/10-calico.conflist /root/10-calico.conflist.bak && echo "和原来一模一样"
kubectl get pod net-c -o wide         # 节点一 Ready，它就被调度上来，Running
```

清理：

```bash
kubectl delete pod net-c
rm /root/10-calico.conflist.bak
```

> 💡 如果要手工把备份放回去，**用 `cp`，不要用 `mv`**。containerd 只对目录里的"文件被写入"作出反应；`mv` 进来的文件只产生一个"新文件出现"的事件，containerd 会忽略它，NetworkReady 一直是 false，非常迷惑。

### 演练 2：IP 池听谁的？natOutgoing 有多重要？

**a. 直接改 IPPool。** 试着把 IP 池的 natOutgoing 关掉：

```bash
kubectl patch ippool default-ipv4-ippool --type=merge -p '{"spec":{"natOutgoing":false}}' \
  -o jsonpath='改完那一刻：natOutgoing={.spec.natOutgoing}{"\n"}'
kubectl get ippools -o wide
```

```
改完那一刻：natOutgoing=false

NAME                  CIDR             VXLAN    IPIP    NAT    ALLOCATABLE   AGE
default-ipv4-ippool   192.168.0.0/16   Always   Never   true   True          30m
```

修改**确实成功了**（返回的是 false），但你再看的时候它已经变回了 `true`：不到一秒，operator 就发现 IPPool 和 Installation 不一致，把它改了回去（深入原理 4）。

**b. 正确的做法：改 Installation。**

```bash
kubectl patch installation default --type=json \
  -p '[{"op":"replace","path":"/spec/calicoNetwork/ipPools/0/natOutgoing","value":"Disabled"}]'
sleep 3
kubectl get ippools -o wide                     # NAT 那一列变成空的了
iptables -t nat -S cali-nat-outgoing            # 只剩 -N 一行，MASQUERADE 规则没了
```

这里用的是 **JSON patch**（`--type=json`）：`/spec/calicoNetwork/ipPools/0/natOutgoing` 精确指向"第 0 个 IP 池的 natOutgoing 字段"。如果用平常的 merge patch，它会把整个 `ipPools` 列表**替换**成你给的那一小段，等于把其他字段全删了。

> ⚠️ **只改 natOutgoing，绝对不要改 `cidr`。** operator 会删掉"Installation 里没有的"IP 池；池子一删，所有 Pod 的 IP 都成了无主地址。

现在从 Pod 里访问外网：

```bash
kubectl exec net-a -- ping -c3 -W2 1.1.1.1
kubectl exec net-a -- nslookup amazon.com
kubectl exec net-a -- nslookup kubernetes.default.svc.cluster.local
```

预计：

- **ping 1.1.1.1 不通**（100% packet loss）：包的源地址是 `192.168.155.8`，出 cp-1 网卡时就被 AWS 的 source/dest check 丢掉了（步骤 18 的三层原因之一就够了）。
- **`nslookup amazon.com` 失败**：CoreDNS 要去问 VPC 的 DNS 服务器，可 CoreDNS 自己也是 Pod，它发出的查询同样被丢掉。（如果碰巧几十秒内查过这个域名，CoreDNS 有缓存，可能还会成功。）
- **`kubernetes.default.svc.cluster.local` 正常**：集群内部的名字 CoreDNS 自己就能回答，不需要出集群。

> 这一项的现象是根据 AWS 的规则推出来的，在本地模拟环境里没法完全复现，如果你看到的和上面不一样，把输出贴给我。

**c. 恢复：**

```bash
kubectl patch installation default --type=json \
  -p '[{"op":"replace","path":"/spec/calicoNetwork/ipPools/0/natOutgoing","value":"Enabled"}]'
sleep 3
kubectl get ippools -o wide                     # NAT 变回 true
kubectl exec net-a -- ping -c2 1.1.1.1          # 通了
```

**（选做）operator 的对账有多快：**

```bash
kubectl -n calico-system delete ds calico-node
kubectl -n calico-system get ds,pods -l k8s-app=calico-node
kubectl describe node ip-10-0-10-11 | grep NetworkUnavailable
```

DaemonSet 被删掉后 1 秒左右就被 operator 重建了。删除的那一刻，calico-node 会把节点的 `NetworkUnavailable` 设成 `True`（`CalicoIsDown`），新的 calico-node 起来后改回 `CalicoIsUp`。这期间 `kubectl exec net-a -- ping -c2 $B` 一直是通的，为什么？见思考题 4。

做完演练，删掉测试 Pod（第 05 章会建新的），退出 root：

```bash
kubectl delete -f /root/net-test.yaml
exit
```

---

## ❓ 思考题

**1. tigera-operator、calico-node、kube-proxy 都不需要 CNI 就能 Running，CoreDNS 却必须等 CNI。区别在哪？**

<details>
<summary>参考答案</summary>

前三个都是 `hostNetwork: true`，直接用节点的网络和 IP，不需要 CNI 分配地址、接网线。它们还容忍 not-ready 的 taint，所以节点 NotReady 时也能调度上来。

CoreDNS 用的是 Pod 网络：它需要一个自己的 IP（`192.168.x.x`），必须等 CNI 插件给它接好网线。而且它不容忍 not-ready 的 taint，节点 Ready 之前根本调度不上来（第 03 章步骤 14）。

规律是：**搭建网络的组件，自己不能依赖网络。**
</details>

**2. Pod 的 IP 是 `/32`，没有任何"同网段的邻居"。它是怎么把包发给同一个节点上的另一个 Pod 的？**

<details>
<summary>参考答案</summary>

1. Pod 的路由表里只有一条默认路由：所有包都交给网关 `169.254.1.1`。
2. Pod 用 ARP 问 `169.254.1.1` 的 MAC，宿主机这头的 `cali` 网卡开着 proxy ARP，用自己的 MAC `ee:ee:ee:ee:ee:ee` 回答。
3. 包顺着 veth 到了宿主机，宿主机查路由表，找到目的 Pod 的 `/32 dev caliY` 路由，从那块网卡送出去，进入目的 Pod 的 eth0。

所以从 Pod 的角度看，**任何目的地都"在网关后面"**，哪怕对方就在同一台机器上。ping 里的 `ttl=63` 就是证据。
</details>

**3. 如果 kubeadm 的 `podSubnet` 和 Calico IP 池的 `cidr` 不一致（比如池子是 `172.16.0.0/16`），会出什么问题？**

<details>
<summary>参考答案</summary>

- **装不上**：operator 第一次安装时会读 kubeadm 的配置，发现 IP 池不在 `podSubnet` 里面，就拒绝创建，`tigerastatus` 里 `ippools` 会是 Degraded。
- **就算绕过去装上了**：kube-proxy 的 `clusterCIDR` 还是 `192.168.0.0/16`，它靠这个判断"流量是不是来自集群内部"。Pod 的 IP 不在这个范围里，kube-proxy 就会把 Pod 访问 Service 的流量都当成"外来流量"做 SNAT。后果是后端 Pod 看到的源 IP 变成了节点 IP，按来源 Pod 写的 NetworkPolicy（第 16 章）也会失灵。

所以这两个值必须一致，这也是第 03 章配置里要写明 `podSubnet` 的原因。
</details>

**4. calico-node 被删掉的那几秒里（演练 2 的选做），已经在跑的 Pod 之间为什么还能通信？**

<details>
<summary>参考答案</summary>

因为真正转发数据包的是 **Linux 内核**：veth、路由表、iptables 规则、VXLAN 设备都在内核里。Felix 只是负责**写入和维护**它们，写完之后，内核自己就能工作。Felix 不在的这几秒里，只是"没人更新"：比如新建的 Pod 不会有对应的策略规则、远端节点的变化同步不过来。

这是 K8s 里反复出现的模式：
- kube-proxy 挂了，已有的 Service 规则照样转发（第 08 章）；
- apiserver 挂了，kubelet 不会去杀正在跑的容器（第 03 章思考题 3）；
- containerd 停了，shim 让容器继续运行（第 03 章演练 2）。

**控制面负责"把世界调整到期望的样子"，数据面负责"按调好的样子干活"。控制面短暂离开，数据面照常运转。**
</details>

**5. 第 05 章两台 worker 加入后，cp-1 的 `ip route` 里会多出什么？**

<details>
<summary>参考答案</summary>

每个 worker 会领到自己的 `/26` 块，它们自己的路由表里也会有各自的 `blackhole` 路由。cp-1 上会为**每个远端块**多出一条路由，形如：

```
192.168.20.0/26 via 192.168.20.0 dev vxlan.calico onlink
```

意思是"去这个块的包，交给 `vxlan.calico` 装信封，寄给隧道地址是 `192.168.20.0` 的那个节点"。而 `192.168.20.0` 对应哪个节点的真实 IP、对方的 VXLAN 网卡 MAC 是多少，Felix 也会写进内核的邻居表和转发表里（`ip neigh show dev vxlan.calico`、`bridge fdb show dev vxlan.calico`）。第 05 章我们一个个看。
</details>

---

## 🧹 收工

测试 Pod 在演练结束时已经删掉了。如果你跳过了演练，先在 cp-1 上删掉它们：`sudo -i`，`kubectl delete -f /root/net-test.yaml`，再 `exit`。

💻 **Mac：**

```bash
cd ~/Desktop/code/K8s-learning
./scripts/lab-down.sh

git add -A
git commit -m "ch04: Calico"
```

把 README 里第 04 章的状态改成 ✅。

**下一章预告**：第 05 章，加入两台 worker，并在 Mac 上用 kubectl 远程管理集群。你会看到 bootstrap token 和 TLS bootstrapping 怎么让一台新机器"领到身份证"、批准 worker 的服务端证书；然后让两个不同节点上的 Pod 互相 ping，第一次抓到 UDP 4789 的 VXLAN 包，拆开信封看看里面装的是什么；再把封装改成 CrossSubnet，亲眼看看 AWS 的 source/dest check 是怎么把同子网的 Pod 流量丢掉的；最后停掉一台 worker 的 kubelet，看 K8s 怎么把上面的 Pod 赶走。

---

## 🧯 附录：装不上、想重来

**先看是哪一环出了问题：**

```bash
kubectl get tigerastatus
kubectl get tigerastatus calico -o jsonpath='{.status.conditions}' ; echo
kubectl -n calico-system get pods
```

| 现象 | 可能的原因 | 怎么查 |
|---|---|---|
| tigerastatus 一直报 `failed calling webhook` | 安装过程中出现是正常的；超过 5 分钟还在，说明 calico-webhooks 的 Pod 起不来 | `kubectl -n calico-system describe pod -l k8s-app=calico-webhooks` |
| Pod 一直是 `ImagePullBackOff` | 镜像从 quay.io 下载，要经过 NAT 实例 | 在 cp-1 上 `curl -sI https://quay.io` 能不能通；`./scripts/status.sh` 看 NAT 是否在运行 |
| calico-node 一直不 Ready | Felix 出错 | `kubectl -n calico-system logs ds/calico-node -c calico-node --tail=30` |
| calico-node 日志里连不上 `10.96.0.1` | Service 的虚拟 IP 是 kube-proxy 负责的 | `kubectl -n kube-system get pods -l k8s-app=kube-proxy` 是否 Running |
| `ippools` 是 Degraded | IP 池不在 kubeadm 的 `podSubnet` 里 | `kubectl get tigerastatus ippools -o yaml`，核对 `cidr` 是不是 `192.168.0.0/16` |

**彻底重来：** 顺序很重要。Installation 和 APIServer 上有 **finalizer**（"删除前必须由 operator 先做完清理"的标记），如果先把 operator 删了，它们会永远卡在 Terminating。

```bash
kubectl delete -f /root/calico-custom-resources.yaml
# 等 operator 清理完：直到这条命令报 NotFound
kubectl get ns calico-system

kubectl delete -f $U/tigera-operator.yaml
kubectl delete -f $U/v3_projectcalico_org.yaml

# 只删 Calico 的文件，不要删目录
rm -f /etc/cni/net.d/10-calico.conflist /etc/cni/net.d/calico-kubeconfig
```

内核里残留的 `cali*` 网卡、`vxlan.calico`、iptables 规则，最省事的清理办法是重启一次（Mac 上 `lab-down.sh` 再 `lab-up.sh`）。然后从步骤 5 重新开始。还是不行的话，把 `kubectl get tigerastatus -o yaml` 和 calico-node 的日志贴给我。
