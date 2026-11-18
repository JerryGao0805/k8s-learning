# 第 04 章 · 安装 Calico：给 Pod 接上网线

> 📍 **搭建篇**：只管把东西装好、确认能用。每一步做了什么只讲一句，原理留到学习篇（这一章对应 **第 11 章 · Pod 网络**）。

## 🎯 做完是什么样

- 节点从 `NotReady` 变成 **Ready**，CoreDNS 跑起来
- Pod 之间能互相 ping 通，能解析集群内的域名，能访问外网

大约 **1 小时**，全程只在 **cp-1** 上操作。

## 🗺 在整体里的位置

第 03 章建好了控制面，但节点一直是 `NotReady`，原因是缺一个**网络插件（CNI）**：没人给 Pod 分 IP、接"网线"。这一章装上 Calico，集群才真正能跑 Pod。下一章 worker 加入时，Calico 会自动扩展到新节点上，不用再装一遍。

## 🧩 新名词

| 词 | 一句话 |
|---|---|
| **CNI** | 一份约定：网络插件就是一个可执行文件，containerd 每创建一个 Pod，就按约定调用它一次，让它给 Pod 分 IP、接网线 |
| **CRD** | 给 apiserver **注册一种新的资源类型**。注册之后，`kubectl get ippools` 就和 `kubectl get pods` 一样能用 |
| **operator** | 一个第三方写的"对账员"（控制器）。你告诉它"我要什么样的 Calico"，它负责装好，并一直看着 |
| **VXLAN** | 跨节点时，把 Pod 的包装进一个 UDP 包（端口 4789）再发出去。AWS 只认节点 IP，不认 Pod IP，所以要"装信封" |

---

## 🛠 步骤

### 步骤 1：开工自检

第 03 章收工时 cp-1 关机了，刚才又开机。这期间没人手动启动过 apiserver、etcd。先确认它们自己回来了（第 03 章留下的验收项）。

💻 **Mac：**

```bash
cd ~/Desktop/code/K8s-learning
./scripts/lab-up.sh          # 如果机器是停着的
./scripts/ssm.sh cp-1
```

🖥️ **cp-1：**

```bash
sudo -i          # 本章全程用 root。KUBECONFIG 第 03 章已经写进了 /root/.bashrc
```

🖥️ **cp-1（root）：**

```bash
systemctl is-active containerd kubelet       # active active
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

- 控制面全部 **Running**，RESTARTS 比上次多了：开机后 kubelet 按 `/etc/kubernetes/manifests` 里的文件，把它们重新拉了起来（第 03 章的 static pod）。✅ 第 03 章的遗留验收项完成。
- 节点 `NotReady`、CoreDNS `Pending`：还没装网络插件，接下来解决。

> 📖 开机后 kubelet 是怎么一步步把控制面拉起来的，第 12 章细看。

### 步骤 2：安装 CRD

版本固定在 **v3.33.1**。先把下载地址存进变量：

```bash
U=https://raw.githubusercontent.com/projectcalico/calico/v3.33.1/manifests
```

> 💡 变量只在当前会话里有效。SSM 断线重连后，要重新执行上面这一行。

```bash
kubectl create -f $U/v3_projectcalico_org.yaml | tail -3
kubectl get crd | grep -c projectcalico          # 22
```

```
customresourcedefinition.apiextensions.k8s.io/stagednetworkpolicies.projectcalico.org created
customresourcedefinition.apiextensions.k8s.io/tiers.projectcalico.org created
22
```

这一步给 apiserver 注册了 Calico 的资源类型（`IPPool`、`IPAMBlock`……）和给 operator 用的类型（`Installation`……）。

**为什么用 `create` 而不是平常的 `apply`？** `apply` 会把整份内容存进对象的一个 annotation，上限 256KB；`Installation` 这个 CRD 有 1.5MB，塞不进去，会报 `Too long`。官方文档也是用 `create`。

### 步骤 3：安装 operator

```bash
kubectl create -f $U/tigera-operator.yaml
kubectl -n tigera-operator get pods -o wide
```

```
NAME                               READY   STATUS    RESTARTS   AGE   IP           NODE
tigera-operator-85dfd45867-wzl4p   1/1     Running   0          10s   10.0.10.11   ip-10-0-10-11
```

节点还是 NotReady，它却能跑起来，IP 还是节点自己的 `10.0.10.11`：它用的是**宿主机网络**（hostNetwork），不需要 CNI；而且它容忍所有 taint。网络的"建设者"不能依赖网络本身。

现在 operator 在等你告诉它：要装一个什么样的 Calico。

### 步骤 4：写配置并应用

整段粘贴（仓库里的 `manifests/ch04-calico/custom-resources.yaml` 一模一样）：

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
        encapsulation: VXLAN          # 官方默认是 VXLANCrossSubnet，在 AWS 上会出问题（第 11 章演练）
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

和官方默认配置不一样的地方：

| 配置项 | 官方默认 | 我们 | 为什么 |
|---|---|---|---|
| `encapsulation` | `VXLANCrossSubnet` | `VXLAN` | CrossSubnet 在同一子网内不装信封，Pod 的包会被 AWS 的 source/dest check 丢掉 |
| `bgp` | 开启 | `Disabled` | VXLAN 模式下路由由 Calico 自己算，用不到 BGP |
| `nodeAddressAutodetectionV4` | 自动找网卡 | `NodeInternalIP` | 和 `kubectl get nodes -o wide` 里的 INTERNAL-IP 保持一致，不会猜错 |
| Goldmane、Whisker | 装 | 不装 | 流量可视化组件，省点内存 |

`natOutgoing: Enabled` 和官方默认一样，但在 AWS 上**必须开**：Pod 访问外网时，源地址要先换成节点 IP，NAT 实例才认识它。

```bash
kubectl apply -f /root/calico-custom-resources.yaml
```

```
installation.operator.tigera.io/default created
apiserver.operator.tigera.io/default created
```

这份文件很小、以后可能还要改，所以用 `apply`。

### 步骤 5：等它装好

```bash
watch -n3 'kubectl get tigerastatus; echo; kubectl get nodes; echo; kubectl -n calico-system get pods; echo; kubectl -n kube-system get pods -l k8s-app=kube-dns'
```

镜像要经过 NAT 从 quay.io 下载，**大约 1~3 分钟**。顺序大致是：calico-node 先起来，把 CNI 配置写进 `/etc/cni/net.d` → 节点变 **Ready** → CoreDNS 等需要 Pod 网络的 Pod 开始创建。

中途 tigerastatus 可能出现下面这种报错，**不用管，等一会儿自己会好**：

```
apiserver   False   True   True   13s   Error creating / updating resource: ... failed calling webhook
            "tiered-rbac.api.projectcalico.org": ... connect: connection refused
```

（operator 要创建的对象需要先经过 webhook 校验，可 webhook 自己的 Pod 还在等网络。operator 会一直重试。）

最终画面（按 `Ctrl+C` 退出）：

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

tigerastatus 是 **4 行**（官方文档写的是 3 行，新版本多了 `tiers`），全部 `True`。

🎉 **节点 Ready，CoreDNS Running。** 从第 03 章 init 到现在，集群第一次完整了。

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
```

CoreDNS 的 IP 是 `192.168.x.x`：它们第一次拿到了 Pod 网络的 IP。

### 步骤 6：冒烟测试

起两个测试 Pod，确认 Pod 网络真的能用。整段粘贴（和仓库里的 `manifests/ch04-calico/net-test.yaml` 一模一样）：

```bash
cat > /root/net-test.yaml <<'EOF'
# 第 04 章的测试 Pod：两个什么都不干、只是活着的 busybox，用来测试 Pod 网络。
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

这是你第一次写 Pod 的 YAML，看懂这几处就够了：

- `metadata.labels`：标签 `app: net-test`，后面用它一次选中两个 Pod。
- `spec.containers`：跑什么镜像、什么命令。
- `tolerations`：cp-1 挂着 control-plane 的"禁止入内"牌子，普通 Pod 进不去；这是"通行证"。现在只有这一个节点，只能放这里。
- `---`：一个文件里放两个对象。

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

测三样：

```bash
B=$(kubectl get pod net-b -o jsonpath='{.status.podIP}')

# ① Pod 之间：net-a ping net-b
kubectl exec net-a -- ping -c2 $B

# ② 集群 DNS：解析 kubernetes 这个 Service
kubectl exec net-a -- nslookup kubernetes.default.svc.cluster.local

# ③ 访问外网：Pod 里和 cp-1 上各查一次"我在互联网上的 IP"
kubectl exec net-a -- wget -T5 -qO- http://checkip.amazonaws.com
curl -s https://checkip.amazonaws.com
```

预期：

```
64 bytes from 192.168.155.7: seq=0 ttl=63 time=0.073 ms
64 bytes from 192.168.155.7: seq=1 ttl=63 time=0.142 ms
...
Name:	kubernetes.default.svc.cluster.local
Address: 10.96.0.1
...
3.85.xxx.xxx
3.85.xxx.xxx
```

- ① 通了：同一节点上的 Pod 网络正常。
- ② 解析出 `10.96.0.1`：CoreDNS 在工作。
- ③ **两行是同一个 IP**：NAT 实例的公网 IP。Pod 的包先被 Calico 换成节点 IP，再被 NAT 实例换成公网 IP。（第 09 章之前这个公网 IP 每次 lab-up 都会变；第 09 章给 NAT 实例绑上 EIP 之后就固定了。）

**顺手看两个数字**（第 11 章会用到）：

```bash
kubectl exec net-a -- ip addr show eth0 | grep -o 'mtu [0-9]*'   # mtu 8951
ip -br addr | grep 10.0.10.11                                     # 宿主机网卡名：ens5
```

- Pod 的 MTU 是 8951：AWS 网卡是 9001，VXLAN 封装要占 50 字节。
- 宿主机网卡叫 `ens5`，不是 `eth0`（Graviton 实例的命名方式）。

测完删掉：

```bash
kubectl delete -f /root/net-test.yaml
```

---

## ✅ 验收

- [ ] 开工自检：lab-up 之后，控制面 Pod 自己回到 Running
- [ ] `kubectl get nodes`：**Ready**
- [ ] `kubectl get tigerastatus`：4 行全部 `AVAILABLE True`
- [ ] CoreDNS 2 个都 Running，IP 是 `192.168.x.x`
- [ ] 冒烟测试三样都通：ping、nslookup、两个 checkip 结果相同

---

## 🧹 收工

```bash
exit             # 退出 root
exit             # 退出 SSM 会话
```

💻 **Mac：**

```bash
cd ~/Desktop/code/K8s-learning
./scripts/lab-down.sh

git add -A
git commit -m "ch04: Calico（课程改为先搭建、再学习）"
```

这次提交里还包括课程改版的改动（README 目录、`docs/drafts/` 等），一起提交就行。把 README 里第 04 章的状态改成 ✅。

**下一章**：第 05 章，加入 worker-1、worker-2，并在 Mac 上用 kubectl 远程管理集群。

---

## 🧯 出问题时

先看是哪一环：

```bash
kubectl get tigerastatus
kubectl get tigerastatus calico -o jsonpath='{.status.conditions}' ; echo
kubectl -n calico-system get pods
```

| 现象 | 可能的原因 | 怎么查 |
|---|---|---|
| tigerastatus 一直报 `failed calling webhook` | 刚装时出现是正常的；超过 5 分钟还在，说明 calico-webhooks 的 Pod 起不来 | `kubectl -n calico-system describe pod -l k8s-app=calico-webhooks` |
| Pod 一直 `ImagePullBackOff` | 镜像从 quay.io 下载，要经过 NAT 实例 | 在 cp-1 上 `curl -sI https://quay.io` 通不通；Mac 上 `./scripts/status.sh` 看 NAT 是否在运行 |
| calico-node 一直不 Ready | Felix 出错 | `kubectl -n calico-system logs ds/calico-node -c calico-node --tail=30` |
| calico-node 日志里连不上 `10.96.0.1` | Service 的虚拟 IP 由 kube-proxy 负责 | `kubectl -n kube-system get pods -l k8s-app=kube-proxy` 是否 Running |
| `ippools` 是 Degraded | IP 池不在 kubeadm 的 `podSubnet` 里 | 核对配置里的 `cidr` 是不是 `192.168.0.0/16` |
| 冒烟测试 ③ 的 wget 超时 | Pod 出不了外网 | 先看 cp-1 上的 `curl` 通不通（不通是 NAT 实例的问题）；再看 `kubectl get ippools -o wide` 的 NAT 列是不是 `true` |
| CoreDNS 一直 Pending | 节点还没 Ready | 等 calico-node Running；`kubectl describe node` 看 Conditions |

**彻底重来**：顺序很重要。Installation 和 APIServer 上有 finalizer（"删除前必须由 operator 先做完清理"），先删了 operator，它们会永远卡在 Terminating。

```bash
kubectl delete -f /root/calico-custom-resources.yaml
# 等 operator 清理完：直到这条命令报 NotFound
kubectl get ns calico-system

kubectl delete -f $U/tigera-operator.yaml
kubectl delete -f $U/v3_projectcalico_org.yaml

# 只删 Calico 的文件，不要删目录（删掉整个目录会让 containerd 崩溃）
rm -f /etc/cni/net.d/10-calico.conflist /etc/cni/net.d/calico-kubeconfig
```

内核里残留的网卡和 iptables 规则，最省事的办法是重启一次（Mac 上 `lab-down.sh` 再 `lab-up.sh`），然后从步骤 2 重新开始。还是不行，把 `kubectl get tigerastatus -o yaml` 和 calico-node 的日志贴给我。

---

## 📖 学习篇第 11 章（Pod 网络）会深入

- CNI 的调用链：创建一个 Pod 时，谁在什么时候调用了 Calico，它在节点上写了哪些文件
- Pod 里的 `/32` 地址、不存在的网关 `169.254.1.1`、宿主机替它回答的 proxy ARP
- IP 块（IPAM）：每个节点领一块 `/26`，和路由表里的 `blackhole` 路由
- 两层 NAT：Pod → 节点 IP → NAT 实例的公网 IP
- operator 怎么"看管" Calico：为什么直接改 IP 池会被改回去
- 跨节点 VXLAN：抓 UDP 4789 的包，拆开"信封"看；为什么 CrossSubnet 在 AWS 上会丢包
- 演练：删掉 CNI 配置文件、关掉 natOutgoing
