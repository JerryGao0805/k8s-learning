# 第 02 章 · 节点准备：把 Ubuntu 变成 K8s 节点

## 🎯 本章目标

1. 搞懂**容器到底是什么**：只用 Linux 自带的命令，亲手造一个"简陋的容器"
2. 搞懂节点上的软件分层：kubelet → containerd → runc → 容器进程
3. 在 cp-1 上**一步步手动**完成节点准备：内核参数、时间同步、containerd、kubeadm/kubelet/kubectl、ECR 凭证插件
4. 把同样的步骤写成脚本，用 **SSM Run Command** 一次推到 worker-1、worker-2
5. 用检查脚本确认 3 台节点都准备好了

大约需要 **2 小时**，全程机器在运行（约 $0.21/小时）。

> 开始之前，💻 **Mac：** 如果机器是停着的，先 `./scripts/lab-up.sh`；再用 `./scripts/status.sh` 确认 SSM 全部 `Online`。

---

## 🧠 概念 1：容器到底是什么

Linux 内核里**没有"容器"这个东西**，只有进程。所谓容器，就是一个普通进程，外加三样东西：

```
 ┌──────────────────────────── 一个"容器" ────────────────────────────┐
 │                                                                    │
 │  一个普通的 Linux 进程（比如 nginx）                                │
 │                                                                    │
 │  + namespace（隔离：它能"看见"什么）                                 │
 │      pid  → 只看得到自己这一组进程，自己是 1 号进程                   │
 │      net  → 有自己的网卡、IP、路由表、端口                            │
 │      mnt  → 有自己的文件系统挂载视图                                  │
 │      uts  → 有自己的主机名                                           │
 │      ipc / user / cgroup ...                                         │
 │                                                                    │
 │  + cgroup（限制：它能"用"多少）                                      │
 │      最多 512MB 内存、最多 0.5 个 CPU ...                             │
 │                                                                    │
 │  + rootfs（自带的根文件系统，也就是"镜像"解压出来的那些文件）          │
 │      它看到的 /bin /lib /etc 和宿主机的不是同一套                      │
 └────────────────────────────────────────────────────────────────────┘
                 ▲ 所有容器共用宿主机的同一个内核
```

**和虚拟机的本质区别**：虚拟机模拟一整台机器，跑自己的内核；容器只是宿主机内核上一个被"关进小房间"的进程。所以容器启动是毫秒级的，开销也很小。

动手 A 里，你会用 Linux 自带的命令把这张图里的东西一样一样做出来。

---

## 🧠 概念 2：节点上的软件分层

K8s 自己并不"运行容器"。真正干活的是一串程序，一层调一层：

```
                     你：kubectl apply ...
                              │  （经 apiserver，第 03 章再讲）
                              ▼
 ┌──────────────────── 每个节点上都一样 ────────────────────┐
 │                                                          │
 │  kubelet        K8s 在节点上的"代理人"，常驻的 systemd 服务 │
 │     │           从 apiserver 领任务："在这台机器上跑这个 Pod" │
 │     │                                                     │
 │     │  CRI（一套 gRPC 接口，走 unix socket：               │
 │     │       /run/containerd/containerd.sock）              │
 │     ▼                                                     │
 │  containerd     容器运行时：拉镜像、解压成 rootfs、         │
 │     │           管理容器的整个生命周期                        │
 │     ▼                                                     │
 │  containerd-shim-runc-v2   每个 Pod 一个"保姆"进程。        │
 │     │           containerd 重启了，容器也不受影响             │
 │     ▼                                                     │
 │  runc           真正调用内核：建 namespace、设 cgroup、      │
 │     │           切换 rootfs，然后启动你的程序。干完就退出      │
 │     ▼                                                     │
 │  容器进程（nginx ...）                                     │
 └──────────────────────────────────────────────────────────┘
```

本章要装的软件：

| 软件 | 是什么 | 怎么用 |
|---|---|---|
| **containerd** | 容器运行时（上图第 2 层） | systemd 服务，常驻 |
| **runc** | 最底层的运行时，containerd 的依赖 | 自动装上，不直接用 |
| **kubelet** | 节点代理人 | systemd 服务，常驻 |
| **kubeadm** | 建集群、加节点、升级的工具 | 只在 init / join / upgrade 时用一下 |
| **kubectl** | K8s 命令行客户端 | 主要在你的 Mac 上用 |
| **crictl** | 调试工具，**经过 CRI** 和运行时对话，看到的是 K8s 视角的容器和镜像 | 节点上排障用 |
| **ctr** | containerd 自带的底层客户端，**绕过 CRI** 直接操作 containerd | 跟 containerd 一起装好，本章做实验用 |

> 📝 **CRI**（Container Runtime Interface）是 K8s 定的一套接口标准，谁实现都行：containerd、CRI-O……
> 你可能听说过"K8s 1.24 不再支持 Docker"。那指的是 kubelet 不再内置对 Docker 的适配，改为只通过 CRI 和运行时对话。镜像格式（OCI 标准）没变，所以用 `docker build` 构建的镜像照样能在 K8s 上跑。

---

## 🧠 概念 3：cgroup driver，"一个仓库只能有一本账"

上一节说过，容器的资源限制靠 cgroup。cgroup 在系统里是一棵目录树（`/sys/fs/cgroup`），总得有人来管理它。

Ubuntu 上 1 号进程是 **systemd**，它本来就在管理这棵树。这时如果 runc 用 `cgroupfs` 方式，绕过 systemd 直接去改 `/sys/fs/cgroup`，同一棵树就有了**两个管家**，各记各的账。平时相安无事，资源一紧张就可能对不上，节点变得不稳定。

所以 K8s 官方建议：**只让 systemd 一个管家来管**。

- containerd（runc）设置 `SystemdCgroup = true`
- kubelet 使用 `cgroupDriver: systemd`（kubeadm 默认就是这样）

在 K8s 1.36 里，kubelet 会通过 CRI 直接**问 containerd** 用的是哪种 driver，然后跟着它走。所以真正起决定作用的是 containerd 的这一行配置。

---

## 🛠 动手 A：亲手造一个"简陋的容器"（cp-1）

### 步骤 1：用 unshare 造出 namespace

💻 **Mac：**

```bash
cd ~/Desktop/code/K8s-learning
./scripts/ssm.sh cp-1
```

🖥️ **cp-1：**

```bash
# 先记住宿主机的样子
hostname
ps aux | wc -l          # 宿主机上有一百多个进程
ip -br addr             # 有 lo 和 ens5 两块网卡

# 进入一组新的 namespace：独立的主机名(uts)、进程号(pid)、网络(net)、挂载点(mount)
sudo unshare --uts --pid --net --mount --fork --mount-proc bash
```

现在你已经"在容器里"了。继续：

🖥️ **cp-1（unshare 里）：**

```bash
# ① 改主机名，只影响这个 namespace
hostname container-demo
exec bash               # 重新启动一下 shell，提示符就会显示新主机名

# ② 进程：只看得到自己，而且自己是 1 号进程
ps aux

# ③ 网络：只有一块 lo，还是 DOWN 的。这个"容器"现在完全断网
ip -br addr
ping -c 1 -W 1 10.0.10.21      # 失败：Network is unreachable

# ④ 但文件系统还是宿主机的
ls /home                       # 能看到宿主机上的用户目录
```

**先别退出**。在 Mac 上再开一个终端窗口，第二次登录 cp-1，从宿主机这边看看它：

🖥️ **cp-1（第二个窗口）：**

```bash
# 找到 unshare 和它的子进程 bash
ps -ef --forest | grep -A1 '[u]nshare'
```

输出是一棵进程树：`sudo` → `unshare` → `bash`。**缩进最深、命令是 `bash` 的那一行**，就是"容器"里的那个 bash。在容器里它是 1 号进程，在宿主机上它只是一个普通的 PID（第二列）。记下这个 PID：

```bash
sudo lsns -p <PID>
```

`lsns` 列出这个进程所在的每一种 namespace：

- `uts`、`pid`、`net`、`mnt` 这 4 行是新建的 namespace。NPROCS（里面有几个进程）只有 1~2，PID 列是 unshare 或这个 bash，也就是这个 namespace 里最早的进程。
- 其余几行（`cgroup`、`ipc`、`user`、`time`）的 PID 列是 `1`，NPROCS 有一百多。说明这几种 namespace 和宿主机的 systemd 是同一个，没有隔离。

**结论**：所谓"容器"，在宿主机上看就是一个普通进程，只是被关进了几个 namespace。

回到第一个窗口，输入 `exit` 退出 unshare。再执行一次 `hostname`，宿主机的主机名一点没变。第二个窗口也可以 `exit` 关掉了。

> 我们的"简陋容器"还缺两样东西：**cgroup**（它想用多少内存都行）和**自己的 rootfs**（它看到的是宿主机的文件）。containerd + runc 做的事，就是把这几样自动组合好。

### 步骤 2：用 cgroup 限制资源

🖥️ **cp-1：**

```bash
# 这台机器用的是 cgroup v2（新版本的 K8s 已经不再支持老的 cgroup v1）
stat -fc %T /sys/fs/cgroup        # 输出 cgroup2fs

# 在一个"最多只能用 50MB 内存"的 cgroup 里运行命令，读出这个限制
sudo systemd-run --scope -p MemoryMax=50M \
  bash -c 'cat /sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)/memory.max'
```

输出 `52428800`，也就是 50 × 1024 × 1024。`systemd-run` 让 systemd 新建了一个 cgroup，把限制写进了这个 cgroup 目录下的 `memory.max` 文件。

现在在同样的限制下，申请 200MB 内存：

```bash
sudo systemd-run --scope -p MemoryMax=50M python3 -c "b = b'x' * (200 * 1024 * 1024)"
echo "退出码：$?"

# 看看内核日志里记了什么
sudo journalctl -k --since "2 min ago" | grep -i -m2 'out of memory'
```

python 被直接杀掉（`Killed`），退出码 **137** = 128 + 9，9 就是 SIGKILL 信号。内核日志里能看到 `Memory cgroup out of memory: Killed process ... (python3)`。

> 💡 以后你在 Pod 里写 `resources.limits.memory: 512Mi`，最终就是变成了这样一个 `memory.max` 文件。超了，进程就被 OOM kill，Pod 状态里会显示 `OOMKilled`（第 09 章会亲眼看到）。

---

## 🛠 动手 B：在 cp-1 上一步步准备节点

> 🔑 **先切换成 root**：下面几乎每条命令都要 root 权限，所以先 `sudo -i`。
>
> 为什么不在每条命令前面加 `sudo`？因为像 `sudo echo xxx > /etc/某文件` 这样的命令会失败：`sudo` 只提升了 `echo` 的权限，而 `>` 重定向是由你当前这个**普通用户的 shell** 执行的，它没有权限写 `/etc`。常见的绕法是 `echo xxx | sudo tee /etc/某文件`，我们这里直接用 root shell 更省事。
>
> 提示符末尾是 `#` 表示 root，`$` 表示普通用户。做完动手 B 记得 `exit` 回到普通用户。

🖥️ **cp-1：**

```bash
sudo -i
```

### 步骤 3：前置检查

🖥️ **cp-1（root）：**

```bash
# 1. swap 必须是关着的：没有任何输出就对了（EC2 上的 Ubuntu 默认没有 swap）
swapon --show

# 2. cgroup v2
stat -fc %T /sys/fs/cgroup

# 3. 主机名：kubelet 会用它当节点名。加入集群之后就不能再改了
hostname

# 4. 每台机器的 product_uuid 必须不一样（克隆出来的虚拟机偶尔会重复，导致节点身份冲突）
cat /sys/class/dmi/id/product_uuid
```

> 为什么要关 swap？kubelet 是按"内存用完就是用完了"来计算和调度的。如果内存可以悄悄换到磁盘上，节点就会在明明快撑不住的时候变得极慢，而不是干脆利落地报警、驱逐 Pod。所以 kubelet 默认发现开了 swap 就拒绝启动。

### 步骤 4：内核模块与 sysctl

🖥️ **cp-1（root）：**

```bash
# overlay 模块：containerd 用 overlayfs 把镜像的多个层叠成容器的根文件系统
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
EOF
modprobe overlay
lsmod | grep overlay

# ip_forward：允许内核在网卡之间转发 IP 包
cat > /etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
sysctl --system | tail -3
sysctl net.ipv4.ip_forward        # = 1
```

- `/etc/modules-load.d/` 和 `/etc/sysctl.d/` 里的文件**开机时会自动生效**；`modprobe`、`sysctl --system` 则是让它们现在就生效。
- 还记得第 01 章 NAT 实例上的 `ip_forward` 吗？是同一个开关。每个 Pod 有自己的 IP，发往 Pod 的包先到节点，再由节点**转发**给 Pod 的虚拟网卡。所以每个节点都要像一台小路由器一样工作。kubeadm 的预检会检查这一项。

> 📝 网上很多教程这一步还会加载 `br_netfilter` 模块、设置 `net.bridge.bridge-nf-call-iptables = 1`。我们**故意没加**，原因见「深入原理 5」。

### 步骤 5：时间同步

集群里有大量依赖时间的东西：证书的有效期、etcd 的选举超时、日志的先后顺序。节点之间时间不一致，会出现各种莫名其妙的问题。

先看看现状：

🖥️ **cp-1（root）：**

```bash
timedatectl | grep -E 'synchronized|NTP service'
systemctl is-active chrony systemd-timesyncd     # 哪个服务在负责对时
chronyc -n sources                               # 如果报 command not found，说明没装 chrony
grep -rn 169.254.169.123 /etc/chrony/            # 有没有配置 AWS 的时间源
```

`169.254.169.123` 是 **Amazon Time Sync Service**，每台 EC2 都能直接访问的本地时间源。它由宿主机提供，**不经过 NAT**，NAT 挂了也照样能对时。

**如果最后一条 `grep` 有输出**，说明 AWS 时间源已经配好了，直接跳到下面的「确认同步」。

**如果没有输出**，补上配置：

```bash
apt-get update
apt-get install -y chrony                       # 已经装了的话会提示 already the newest version
grep sourcedir /etc/chrony/chrony.conf          # 确认有 sourcedir /etc/chrony/sources.d 这一行
cat > /etc/chrony/sources.d/aws.sources <<'EOF'
server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4
EOF
systemctl restart chrony
```

**确认同步：**

```bash
chronyc waitsync 12 0.1         # 等它同步完成，最多约 2 分钟
chronyc -n sources              # 169.254.169.123 前面是 ^* 表示正在用它
chronyc tracking | grep -E 'Reference ID|Leap status|System time'
```

`Leap status : Normal` 表示已同步，`System time` 那一行是本机时钟和标准时间的偏差，通常只有几微秒。

### 步骤 6：安装和配置 containerd

🖥️ **cp-1（root）：**

```bash
apt-get update
apt-get install -y containerd

# 必须是 2.x（Kubernetes 1.36 已经不支持 containerd 1.x）
dpkg-query -W -f='${Version}\n' containerd       # 2.2.1-0ubuntu1~24.04.x
containerd --version
runc --version
```

> 📝 Ubuntu 24.04 刚发布时带的是 containerd 1.7，2.x 是后来通过 `noble-updates` 源更新进来的。如果这里显示 1.7.x，先停下来告诉我。

Ubuntu 的 containerd 包不带配置文件，连 `/etc/containerd` 目录都没有。先生成一份"全是默认值"的配置：

```bash
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
wc -l /etc/containerd/config.toml

# 找到我们要改的两处
grep -nE 'SystemdCgroup|sandbox =' /etc/containerd/config.toml
```

应该看到类似（行号可能不同）：

```
51:      sandbox = 'registry.k8s.io/pause:3.10.1'
109:            SystemdCgroup = false
```

```bash
# ① 让 runc 通过 systemd 管理 cgroup（原因见概念 3）
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# ② pause 镜像改成 kubeadm v1.36.6 用的 3.10.2（原因见深入原理 3）
sed -i "s|sandbox = 'registry.k8s.io/pause:.*'|sandbox = 'registry.k8s.io/pause:3.10.2'|" /etc/containerd/config.toml

# 再看一眼，确认两处都改对了
grep -nE 'SystemdCgroup|sandbox =' /etc/containerd/config.toml

systemctl restart containerd
systemctl status containerd --no-pager | head -5      # Active: active (running)
```

最后看看 containerd **实际生效**的配置，也就是默认值和你的修改合并之后的结果：

```bash
containerd config dump | grep -E 'SystemdCgroup|sandbox =|bin_dirs|conf_dir'
```

除了你改的两处，还有两行值得记住：`bin_dirs = ['/opt/cni/bin']` 和 `conf_dir = '/etc/cni/net.d'`。第 04 章装 Calico 时，它会把网络插件和配置分别放进这两个目录。

### 步骤 7：用 ctr 跑一个容器，看看它到底是什么

`ctr` 是 containerd 自带的底层命令行，不经过 K8s，也不经过 CRI。用它跑一个最小的容器：

🖥️ **cp-1（root）：**

```bash
ctr images pull public.ecr.aws/docker/library/busybox:1.37
ctr run -d public.ecr.aws/docker/library/busybox:1.37 demo sleep 3600
ctr tasks ls                     # demo 正在运行，第二列是它在宿主机上的 PID

PID=$(ctr tasks ls | awk '$1=="demo" {print $2}')
echo $PID
```

> 镜像用的是 AWS 公共镜像库（public.ecr.aws）里 Docker 官方镜像的副本，内容和 Docker Hub 上的一样，但不受 Docker Hub 匿名拉取次数的限制。

现在对照"概念 1"的那张图，一样一样看：

```bash
# ① 它就是宿主机上的一个普通进程
ps -o pid,ppid,args -p $PID
# 它的父进程是 containerd-shim-runc-v2，shim 的父进程则是 1 号进程 systemd
ps -o pid,ppid,args -p $(ps -o ppid= -p $PID)

# ② namespace：和宿主机不一样（对比方括号里的编号）
ls -l /proc/$PID/ns
ls -l /proc/self/ns
lsns -p $PID

# ③ rootfs：它的根目录是镜像里的文件，不是宿主机的
ls /proc/$PID/root/
ls /proc/$PID/root/bin | head

# ④ cgroup：它被放在哪个 cgroup 里
cat /proc/$PID/cgroup
```

几个值得注意的地方：

- **shim 的父进程是 1 号进程，不是 containerd**。shim 启动后会"脱离"containerd 独立运行，所以 containerd 重启、升级时，正在跑的容器不受影响。「💥 演练 1」会亲手验证。
- **cgroup 是 `/default/demo`**。`ctr` 不经过 CRI，所以刚才在 CRI 插件里设的 `SystemdCgroup` 对它不起作用。kubelet 创建的 Pod 会出现在 `/kubepods.slice/...` 下面，第 06 章再看。

清理掉这个容器：

```bash
ctr tasks kill demo              # 默认发 SIGTERM，"请你退出"
sleep 2; ctr tasks ls            # 咦，还是 RUNNING！
```

**SIGTERM 杀不掉它。** 在 PID namespace 里，1 号进程有特殊待遇：内核不会替它执行信号的默认动作，它没写处理函数的信号会被直接忽略。`sleep` 正好没处理 SIGTERM。只有 SIGKILL 是强制的：

```bash
ctr tasks kill -s SIGKILL demo
sleep 1; ctr tasks ls            # STOPPED
ctr tasks rm demo
ctr containers rm demo
```

> 💡 这就是为什么 `docker stop` 有时要等 10 秒，删除 K8s Pod 有时要等 30 秒：先发 SIGTERM，等一个宽限期，进程还不退出才发 SIGKILL。写应用时要正确处理 SIGTERM，才能"优雅退出"。

### 步骤 8：安装 kubelet、kubeadm、kubectl

🖥️ **cp-1（root）：**

```bash
# 1. 添加 Kubernetes 官方 apt 源。源按小版本划分：v1.36 的源里只有 1.36.x
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update

# 2. 看看源里有哪些版本
apt-cache madison kubeadm | head -5

# 3. 安装指定版本。cri-tools（提供 crictl）要单独写上：从 kubeadm 1.36.1 起，它不再自动带上 cri-tools
apt-get install -y kubelet=1.36.6-1.1 kubeadm=1.36.6-1.1 kubectl=1.36.6-1.1 cri-tools=1.36.0-1.1

# 4. 锁定版本，防止被意外升级（原因见深入原理 4）
apt-mark hold kubelet kubeadm kubectl cri-tools containerd
apt-mark showhold

kubeadm version -o short
kubelet --version
kubectl version --client
```

- **`signed-by`**：apt 只接受用这把公钥签名的软件包，防止有人冒充这个源。
- **为什么要写死版本号？** 不写就会装源里最新的 1.36.x。集群里所有节点的版本要我们自己掌控，不能"装的时候恰好是哪个就是哪个"。

启动 kubelet：

```bash
systemctl enable --now kubelet
systemctl status kubelet --no-pager | head -8
```

你会看到 `Active: activating (auto-restart) (Result: exit-code)`：kubelet 启动后立刻退出，systemd 每隔 10 秒把它拉起来一次。看看它为什么退出：

```bash
journalctl -u kubelet -n 30 --no-pager | grep -m1 'config.yaml'
```

报错是读不到 `/var/lib/kubelet/config.yaml`。**这是正常的**：kubelet 的配置文件要等第 03 章 `kubeadm init`（cp-1）或 `kubeadm join`（worker）才会生成。在那之前，它会一直这样循环下去（详见深入原理 1）。

### 步骤 9：配置 crictl，预拉控制面镜像

🖥️ **cp-1（root）：**

```bash
# 1. 告诉 crictl 去哪里找 CRI socket
#    （第一次执行会提示 Config "/etc/crictl.yaml" does not exist，没关系，它马上就会创建这个文件）
crictl config --set runtime-endpoint=unix:///run/containerd/containerd.sock
cat /etc/crictl.yaml

# 2. 通过 CRI 问 containerd：你状态怎么样？
crictl info | grep -A3 '"RuntimeReady"'
crictl info | grep -A3 '"NetworkReady"'
crictl images                    # 空的
```

- `RuntimeReady` 是 `true`：containerd 一切正常。
- `NetworkReady` 是 `false`，原因是 `cni plugin not initialized`：还没有安装网络插件，第 04 章装 Calico 之后它才会变成 `true`。记住这个，第 03 章你会再次遇到它。

接下来**只在 cp-1 上做**：预先拉好控制面要用的镜像，第 03 章 init 时就不用等下载了。

```bash
kubeadm config images list --kubernetes-version v1.36.6
kubeadm config images pull --kubernetes-version v1.36.6
crictl images
```

列表里有一个 `registry.k8s.io/pause:3.10.2`，这正是步骤 6 要把 containerd 的 `sandbox` 改成 3.10.2 的原因：两边必须一致。

最后对比一下，`ctr` 和 `crictl` 看到的镜像为什么不一样：

```bash
ctr namespaces ls
ctr images ls -q                 # default 命名空间：只有刚才的 busybox
ctr -n k8s.io images ls -q       # k8s.io 命名空间：kubeadm 拉的镜像都在这里
ctr images rm public.ecr.aws/docker/library/busybox:1.37    # 清理实验用的镜像
```

> 📝 **同一个词，两个意思**：这里的"命名空间"是 **containerd 自己的概念**，用来把不同用户的容器和镜像分开存放。它跟 Linux 内核的 namespace（隔离进程的那个）毫无关系。K8s 通过 CRI 创建的东西都在 `k8s.io` 里，`crictl` 也只看 `k8s.io`；`ctr` 默认看 `default`。

### 步骤 10：安装 ECR 凭证插件（第 12 章才用到）

第 12 章，我们会把自己写的应用镜像推到 **ECR**（AWS 的私有镜像仓库）。kubelet 从私有仓库拉镜像需要密码，而 **ecr-credential-provider** 会用节点的 IAM 角色，向 ECR 换一个 12 小时有效的临时密码交给 kubelet。现在先装好，从第 03 章起，kubelet 一启动就带着它。

🖥️ **cp-1（root）：**

```bash
VER=v1.36.2
BIN_DIR=/usr/local/libexec/kubernetes/image-credential-provider

curl -fsSLo /tmp/ecr-credential-provider \
  https://artifacts.k8s.io/binaries/cloud-provider-aws/$VER/linux/arm64/ecr-credential-provider-linux-arm64

# 校验文件指纹（sha256）：下载的文件必须和官方发布的一模一样
# 指纹从哪来？官方在同一个地方发布了 .sha256 文件：
curl -fsSL https://artifacts.k8s.io/binaries/cloud-provider-aws/$VER/linux/arm64/ecr-credential-provider-linux-arm64.sha256; echo
echo "7be106e9dd1e9a6a3dcfef1756661be69ce3d09ae5970c0c3685c58c94c8d3aa  /tmp/ecr-credential-provider" | sha256sum -c -
```

**看到 `/tmp/ecr-credential-provider: OK` 才继续。** 然后安装：

```bash
install -D -m 0755 /tmp/ecr-credential-provider $BIN_DIR/ecr-credential-provider
ls -l $BIN_DIR

# 告诉 kubelet：哪些镜像地址要找这个插件拿密码
mkdir -p /etc/kubernetes/image-credential-provider
cat > /etc/kubernetes/image-credential-provider/config.yaml <<'EOF'
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
  - name: ecr-credential-provider
    matchImages:
      - "*.dkr.ecr.*.amazonaws.com"
      - "*.dkr.ecr.*.amazonaws.com.cn"
      - "*.dkr-ecr.*.on.aws"
    defaultCacheDuration: "12h"
    apiVersion: credentialprovider.kubelet.k8s.io/v1
EOF
```

最后要让 kubelet 启动时带上两个参数，告诉它配置文件和插件放在哪。先看看 kubelet 是怎么被 systemd 启动的：

```bash
systemctl cat kubelet
```

除了 `kubelet.service` 本体，还有一个 kubeadm 装进来的"补丁"文件 `10-kubeadm.conf`（systemd 叫它 drop-in）。注意其中两行：

```
EnvironmentFile=-/etc/default/kubelet
ExecStart=/usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
```

也就是说，`/etc/default/kubelet` 里定义的 `KUBELET_EXTRA_ARGS` 会被拼到 kubelet 的启动命令末尾：

```bash
cat /etc/default/kubelet          # 安装包自带的，内容是空的：KUBELET_EXTRA_ARGS=
cat > /etc/default/kubelet <<'EOF'
KUBELET_EXTRA_ARGS="--image-credential-provider-config=/etc/kubernetes/image-credential-provider/config.yaml --image-credential-provider-bin-dir=/usr/local/libexec/kubernetes/image-credential-provider"
EOF
```

> 📝 K8s 官方更推荐把 kubelet 的额外参数写进 kubeadm 的配置文件（`kubeletExtraArgs`）。但插件放在哪个目录，本来就是"每台节点自己的事"，放在节点本地的文件里更合适；第 03 章 init 和第 05 章 join 的配置也就都不用管它了。

动手 B 结束，退回普通用户：

```bash
exit
```

---

## 🛠 动手 C：用脚本准备 worker-1、worker-2（Mac）

cp-1 上的 8 个步骤，在 worker-1、worker-2 上还要再做一遍，第 11 章加新节点时又要做 3 遍。手敲既慢又容易漏，正确的做法是把它写成**脚本**，一次推到多台机器上执行。

### 先认识 SSM Run Command

```
  Session Manager（./scripts/ssm.sh）         Run Command（./scripts/run-on-nodes.sh）

  你 ⇄ 一台机器                                你 ──"把这段脚本拿去执行"──► 多台机器
       交互式终端，一条条敲                                  各自执行，把结果交回来

  适合：探索、排障                              适合：批量、可重复的操作
  身份：ssm-user（需要 sudo）                   身份：root
```

两者都走节点上 SSM agent 主动向外建立的那条通道（第 01 章讲过），所以同样不需要开任何入站端口。谁能发命令，由 IAM 权限决定；每一次执行，AWS 都留有记录。

### 步骤 11：读懂脚本

在编辑器里打开 `scripts/node/prepare-node.sh`。它的每一段都对应你在 cp-1 上做过的步骤：

| 脚本里的段落 | 对应你在 cp-1 上做的 |
|---|---|
| `[1/7] 前置检查 + 更新软件源` | 步骤 3 |
| `[2/7] 内核模块与 sysctl` | 步骤 4 |
| `[3/7] 时间同步` | 步骤 5 |
| `[4/7] containerd 2.x` | 步骤 6 |
| `[5/7] kubelet / kubeadm / kubectl` | 步骤 8 |
| `[6/7] crictl` | 步骤 9 的前半。不预拉控制面镜像，worker 用不到 |
| `[7/7] ecr-credential-provider` | 步骤 10 |
| （没有） | 步骤 1、2、7 的实验 |

和手敲相比，脚本多做了几件事，这也是写运维脚本的常见做法：

- **可以重复执行**（幂等）：每个文件都先写到临时文件里比较，内容没变就不动它；containerd 只在配置真的变了时才重启。
- **出错立刻停下**：`set -Eeuo pipefail` 加上 `trap ... ERR`，任何一步失败，都会报告是哪一步，并打印日志的最后 50 行。
- **少打印**：屏幕上每一步只打一行，apt 之类的详细输出写在节点的 `/var/log/k8s-prepare-node.log` 里。这是因为 Run Command 只会把输出的前 24000 个字符交回给你。
- **SystemdCgroup 的改法更稳妥**：先删掉再插入，就算哪天默认配置里没有这一行也能处理。

再打开 `scripts/run-on-nodes.sh`，它在 Mac 上运行，做的事情是：

1. 把节点名换成实例 ID，确认 SSM agent 在线；
2. 用 `aws ssm send-command` 把整个脚本发出去；
3. 每隔几秒查一次执行状态，直到结束；
4. 打印每台节点的输出。

### 步骤 12：推到两台 worker

💻 **Mac：**

```bash
./scripts/run-on-nodes.sh scripts/node/prepare-node.sh worker-1 worker-2
```

大约 3~5 分钟。输出类似：

```
==> 把 prepare-node.sh 推到：worker-1 worker-2
==> CommandId = 1a2b3c4d-....（控制台 Run Command 的 Command history 里能看到）
==> worker-1：InProgress ...

 ✔ worker-1 (i-xxxxxxxxxxxxxxxxx)：Success
    节点：ip-10-0-10-21    日志：/var/log/k8s-prepare-node.log
    20:31:02  [1/7] 前置检查 + 更新软件源
    20:31:15  [2/7] 内核模块与 sysctl
    ...
    ✅ 完成：ip-10-0-10-21  containerd 2.2.1-0ubuntu1~24.04.4  kubelet 1.36.6-1.1

 ✔ worker-2 (i-xxxxxxxxxxxxxxxxx)：Success
    ...
 ✔ 全部 2 台执行成功
```

趁它在跑，可以打开 AWS 控制台 → **Systems Manager** → **Run Command** → **Command history**，看看这次执行的记录。

> 💡 想体会一下"幂等"：同一条命令对 worker-1 再执行一次。这次会快很多，而且什么都不会改变。

### 步骤 13：给 3 台节点打分

💻 **Mac：**

```bash
./scripts/run-on-nodes.sh scripts/node/check-node.sh cp-1 worker-1 worker-2
```

`check-node.sh` 只读不写，逐项检查并打印 ✅ 或 ❌。cp-1 是你手敲的，如果它有 ❌，回到对应的步骤看看是不是漏了什么。

---

## ✅ 验证

全部打勾，本章就完成了：

- [ ] 动手 A：unshare 里 `ps aux` 只看得到 1 号进程；超过内存限制的 python 被杀掉，退出码 137
- [ ] cp-1 上 `sudo crictl images` 能看到 7 个控制面镜像
- [ ] `check-node.sh` 在 cp-1、worker-1、worker-2 上全部 ✅
- [ ] 收工再开工（`lab-down.sh` → `lab-up.sh`）之后，再跑一次 `check-node.sh` 依然全部 ✅。这一条验证的是：所有配置重启之后都还在

---

## 🔍 深入原理

### 1. kubelet 为什么一直在重启？

🖥️ **cp-1：**

```bash
systemctl cat kubelet
```

kubelet 的启动命令由 4 组参数拼成：

| 变量 | 来自哪里 | 内容 | 现在存在吗 |
|---|---|---|---|
| `KUBELET_KUBECONFIG_ARGS` | drop-in 里写死的 | 去哪里找连接 apiserver 的凭证（`kubelet.conf`） | 文件还不存在 |
| `KUBELET_CONFIG_ARGS` | drop-in 里写死的 | `--config=/var/lib/kubelet/config.yaml` | **文件不存在 → 退出** |
| `KUBELET_KUBEADM_ARGS` | `/var/lib/kubelet/kubeadm-flags.env` | kubeadm 生成的参数 | 文件还不存在 |
| `KUBELET_EXTRA_ARGS` | `/etc/default/kubelet` | 你写的凭证插件参数 | ✅ |

`kubelet.service` 里设置了 `Restart=always`、`RestartSec=10`，所以它每 10 秒被拉起来一次，读不到配置又退出。

第 03 章 `kubeadm init` 会依次生成这几个文件，然后重启 kubelet。你会亲眼看到它从这个循环里"活过来"，再由它把控制面的组件一个个拉起来。

### 2. cgroup driver：如果忘了设会怎样？

**什么报错都不会有。** 前面说过，kubelet 会问 containerd 用哪种 driver 并跟着它走。如果你忘了把 `SystemdCgroup` 改成 `true`，containerd 就会回答 `cgroupfs`，kubelet 也乖乖用 `cgroupfs`，集群照样能建起来、Pod 照样能跑。

问题会在很久以后才出现：两个管家各记各的账，资源紧张时节点出现奇怪的不稳定，而且很难查到根源。

**静默的错误最危险。** 这就是为什么 `check-node.sh` 专门检查了这一项。

### 3. pause 容器和 sandbox 镜像

每个 Pod 里都有一个你看不见的 **pause 容器**。它最先启动，唯一的工作就是"占着"这个 Pod 的网络 namespace（以及 IPC 等），然后永远睡觉。你的应用容器启动时，会**加入**它的 namespace。

```
        Pod
 ┌──────────────────────────────────┐
 │  pause   ← 持有 network namespace │  ← Pod 的 IP 在这里
 │    ▲          ▲                   │
 │  nginx      sidecar  ← 加入它的 namespace，所以共享同一个 IP，
 │                         互相用 localhost 就能访问
 └──────────────────────────────────┘
```

containerd 配置里的 `sandbox` 就是"用哪个 pause 镜像"。如果它和 kubeadm 预拉的版本不一致，containerd 会在第一次创建 Pod 时再去下载另一个版本，在不能联网的环境里就会直接失败。

更麻烦的是，搭配 containerd 2.x 时，kubeadm 检测不到这种不一致，**也不会给出任何警告**。所以只能我们自己保证两边一致。第 06 章会用 `crictl pods` 亲眼看到 pause 容器。

### 4. `apt-mark hold`：为什么要锁定版本？

Ubuntu 默认开启了 **unattended-upgrades**，每天自动安装 Ubuntu 官方源里的安全更新：

- **containerd** 属于 Ubuntu 官方源。不锁定的话，它可能在某天夜里被自动升级并重启。
- **kubelet、kubeadm、kubectl** 来自 pkgs.k8s.io，不在自动更新范围内。但只要你哪天顺手 `apt upgrade` 一下，它们就会被升级。

K8s 对组件之间的版本差有严格要求（例如 kubelet 不能比 apiserver 新），升级必须按顺序来：先升控制面，再逐台腾空节点、升级、恢复。这些是第 18 章的内容。`hold` 把"意外升级"的路堵死了。

代价是：containerd 的安全更新要我们自己挑时间来做。

### 5. 为什么老教程都要加 `br_netfilter`？

Linux 里，经过**网桥**（bridge）转发的包默认不经过 iptables。

- 如果 Pod 都挂在一个网桥上（例如 flannel 的 `cni0`），同一节点上 Pod 之间的流量就会绕开 kube-proxy 设的 iptables 规则，访问 Service 就会出问题。
- 所以那类网络方案需要加载 `br_netfilter` 模块，并打开 `bridge-nf-call-iptables`，让网桥上的包也去走一遍 iptables。

**Calico 不用网桥**：每个 Pod 的虚拟网卡都是由宿主机按路由（三层）转发的，包本来就会经过 iptables。新版本的 kubeadm 也已经不再检查这一项。

> 配置要知其所以然。网上的步骤往往是"多年以前、某个网络方案下"必要的东西。照抄不会出错，但你就失去了一次理解系统的机会。

---

## 💥 故意搞坏

### 演练 1：containerd 停了，容器会死吗？

🖥️ **cp-1：**

```bash
sudo -i

# 用 ctr 跑一个容器。pause 镜像步骤 9 已经拉好了，它的工作就是"永远睡觉"
ctr -n k8s.io run -d registry.k8s.io/pause:3.10.2 drill
ctr -n k8s.io tasks ls

# 停掉 containerd
systemctl stop containerd
crictl ps                       # 报错：连不上 /run/containerd/containerd.sock
ctr -n k8s.io tasks ls          # 也报错

# 但容器进程和它的 shim 还活着！
ps -ef | grep -E '[c]ontainerd-shim|[/]pause'
```

记住 `crictl` 的报错长什么样：`validate service connection ... containerd.sock ...`（`no such file or directory` 或 `connection refused`）。以后看到 kubelet 日志里出现类似的话，第一反应就该是：**containerd 是不是挂了？**

把 containerd 启动回来：

```bash
systemctl start containerd
ctr -n k8s.io tasks ls          # drill 依然是 RUNNING，就像什么都没发生过
```

这就是 shim 存在的意义：**升级或重启 containerd，不会杀掉正在运行的 Pod**。

清理：

```bash
ctr -n k8s.io tasks kill -s SIGKILL drill
sleep 1
ctr -n k8s.io tasks rm drill
ctr -n k8s.io containers rm drill
```

### 演练 2：配置文件写坏了

```bash
cp /etc/containerd/config.toml /root/config.toml.bak
echo 'this line is not valid toml' >> /etc/containerd/config.toml

systemctl restart containerd    # 失败：Job for containerd.service failed ...
```

假装你不知道发生了什么，按排障的标准动作走：

```bash
# 第一步：服务现在是什么状态？
systemctl status containerd --no-pager | head -5

# 第二步：它最后说了什么？
journalctl -u containerd -n 20 --no-pager
```

日志里会明确指出 `/etc/containerd/config.toml` 解析失败，还会告诉你是哪一行出了问题。修复：

```bash
cp /root/config.toml.bak /etc/containerd/config.toml
systemctl restart containerd
systemctl is-active containerd   # active
exit
```

> 🔑 **排查 systemd 服务的标准动作：先 `systemctl status`，再 `journalctl -u <服务名>`。** 后面每一章都会反复用到。

最后，在 💻 **Mac** 上重新检查一遍 cp-1，确认恢复如初：

```bash
./scripts/run-on-nodes.sh scripts/node/check-node.sh cp-1
```

---

## ❓ 思考题

**1. 容器和虚拟机最本质的区别是什么？由此推断：在我们的 arm64 节点上，能直接运行 amd64 架构的镜像吗？**

<details>
<summary>参考答案</summary>

容器共用宿主机的内核，本质上就是宿主机上的进程；虚拟机有自己的内核，跑在模拟出来的硬件上。

所以容器里的程序是直接由宿主机的 CPU 执行的。amd64 的程序在 arm64 的 CPU 上根本无法执行，会报 `exec format error`。这就是为什么第 12 章构建镜像时要构建 arm64 版本，第 17 章的 CI 要用 arm64 的 runner。
</details>

**2. 如果忘了把 `SystemdCgroup` 改成 `true`，第 03 章的 `kubeadm init` 会报错吗？**

<details>
<summary>参考答案</summary>

不会。kubelet 会问 containerd 用哪种 cgroup driver，然后跟着用 `cgroupfs`，一切看起来都正常。问题要到资源紧张时才会暴露，而且很难查。见深入原理 2。
</details>

**3. 为什么 `ctr images ls` 看不到 kubeadm 拉的镜像？反过来，为什么 `crictl images` 看不到 busybox？**

<details>
<summary>参考答案</summary>

containerd 用自己的"命名空间"把数据分开存放。K8s（经过 CRI）用的是 `k8s.io`，`ctr` 默认用 `default`。kubeadm 是通过 CRI 拉的镜像，所以在 `k8s.io` 里；busybox 是 `ctr` 在 `default` 里拉的。`crictl` 只看 `k8s.io`，`ctr` 不加 `-n k8s.io` 只看 `default`。
</details>

**4. worker 上又不跑控制面，为什么也要装 kubeadm？**

<details>
<summary>参考答案</summary>

第 05 章的 `kubeadm join` 就是在 worker 上执行的。它负责：

- 验证 control plane 的身份（CA 证书指纹）；
- 用一个临时的 bootstrap token 换来 kubelet 的正式证书（TLS bootstrap）；
- 生成 kubelet 的配置文件，再重启 kubelet。

第 18 章升级集群时，worker 上也要执行 `kubeadm upgrade node`。kubeadm 是"节点的安装和维护工具"，不只是控制面的。
</details>

**5. `run-on-nodes.sh` 能以 root 身份在节点上执行任意脚本，听起来很危险。谁能做这件事？怎么限制？怎么审计？**

<details>
<summary>参考答案</summary>

- **谁能做**：拥有 `ssm:SendCommand` 权限的 IAM 身份。你的 `admin` 用户什么都能做，所以能。
- **怎么限制**：在 IAM 策略里收窄范围，例如只允许对带某个标签的实例、只允许执行某几个预先审核过的 SSM 文档，而不是能执行任意 shell 的 `AWS-RunShellScript`。
- **怎么审计**：每次 `SendCommand` 都会记进 CloudTrail（谁、什么时候、对哪些实例、执行了什么），Run Command 的 Command history 里也有记录。

和"所有人共用一把 SSH 私钥"相比，这种方式的权限控制和审计都要好得多。这也是很多公司在生产环境禁用 SSH、改用 SSM 的原因。
</details>

---

## 🧹 收工

💻 **Mac：**

```bash
cd ~/Desktop/code/K8s-learning
./scripts/lab-down.sh

git add -A
git commit -m "ch02: 节点准备"
```

把 README 里第 02 章的状态改成 ✅。

**下一章预告**：第 03 章，在 cp-1 上执行 `kubeadm init`。我们会拆开它的每一个阶段：生成整套证书、写出 kubeconfig、用 static pod 拉起 etcd 和 apiserver……你会看到 kubelet 从重启循环里活过来，再由它把整个控制面一个个启动起来。
