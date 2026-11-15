# 第 01 章 · AWS 网络地基

## 🎯 本章目标

1. 理解 Terraform 的基本用法：**写代码 → plan → apply → destroy**
2. 理解集群底下的 AWS 网络：VPC、子网、路由表、NAT、安全组、负载均衡、私有 DNS
3. 用一条命令建出：网络 + NAT 实例 + 3 台 K8s 节点（1 个 control plane + 2 个 worker）+ apiserver 的内网负载均衡
4. 用 SSM 登录节点，**亲手验证**每一层网络是怎么工作的
5. 学会开工 / 收工

大约需要 **1.5 小时**。apply 之后开始计费（约 $0.21/小时），学完记得收工。

---

## 🧠 概念 1：Terraform 是什么

在 AWS 控制台里手动点一遍建出 VPC、子网、安全组、实例……大概要点上百下，而且：

- 很难记住自己到底点了什么
- 想再建一套一模一样的？再点一百下
- 删的时候漏掉一个，就一直扣钱

**Terraform 的做法：把基础设施写成代码（Infrastructure as Code）。** 你描述"我要什么资源"，Terraform 负责创建。

```
 *.tf 代码              terraform plan              terraform apply
（期望状态）  ───────►  对比 代码 vs 现实    ───────►  调 AWS API 创建/修改/删除
                         列出将要做的变更                    │
                              ▲                             ▼
                              └──────── terraform.tfstate（记录"我建了什么"）
```

是不是有点眼熟？**这和 K8s 的声明式思想一模一样**：描述期望状态，由工具负责让现实和期望一致。

几个核心概念：

| 概念 | 含义 |
|---|---|
| **provider** | 插件，负责和某个平台的 API 打交道（这里是 `hashicorp/aws`） |
| **resource** | 一个要创建的资源，例如 `resource "aws_vpc" "main" { ... }` |
| **data** | 只读查询，例如"查一下最新的 Ubuntu AMI ID 是多少" |
| **variable** | 输入参数（在 `terraform.tfvars` 里赋值） |
| **output** | 建完之后要打印出来的信息 |
| **state** | `terraform.tfstate` 文件，记录 Terraform 管理着哪些真实资源。**不要手动改，也不要删** |

---

## 🧠 概念 2：我们要建的网络

```
                         Internet
                            ▲
                            │
                   ┌────────┴────────┐
                   │ Internet Gateway│  VPC 通往公网的大门
                   └────────┬────────┘
┌───────────────────────────┼──────────────── VPC 10.0.0.0/16 ─────────────┐
│                           │                                              │
│  公有子网 10.0.0.0/24 ─────┤  路由表：0.0.0.0/0 → Internet Gateway         │
│   ┌──────────────────┐    │                                              │
│   │ NAT 实例          │────┘  有公网 IP                                    │
│   │ 10.0.0.x         │                                                   │
│   └────────▲─────────┘                                                   │
│            │  私有子网的路由表：0.0.0.0/0 → NAT 实例的网卡                   │
│  私有子网 10.0.10.0/24 (AZ a)    10.0.11.0/24 (AZ b)    10.0.12.0/24 (AZ c)  │
│   ┌──────────────┐             ┌──────────────┐                          │
│   │ cp-1         │             │              │                          │
│   │ 10.0.10.11   │             │              │                          │
│   ├──────────────┤             ├──────────────┤                          │
│   │ worker-1     │             │ worker-2     │                          │
│   │ 10.0.10.21   │             │ 10.0.11.21   │                          │
│   └──────────────┘             └──────────────┘                          │
│                                                                          │
│   [内网 NLB]  ◄── api.k8s.internal（Route53 私有托管区，只有 VPC 内能解析）  │
│      └─► cp-1:6443                                                       │
└──────────────────────────────────────────────────────────────────────────┘
```

| 概念 | 说明 |
|---|---|
| **VPC** | 你在 AWS 里的一张私有网络，`10.0.0.0/16` 表示这张网络有 65536 个地址（10.0.0.0 ~ 10.0.255.255） |
| **可用区（AZ）** | 同一个区域里物理上隔离的机房。我们把 3 个 control plane 分散在 3 个 AZ，一个机房出事集群还能活 |
| **子网** | VPC 的一块，属于某一个 AZ。`/24` = 256 个地址 |
| **路由表** | 决定"去某个地址的包从哪儿走"。**公有子网和私有子网的唯一区别就是路由表**：公有子网的默认路由指向 Internet Gateway，私有子网的默认路由指向 NAT |
| **NAT** | 让私有子网的机器能**主动访问公网**（装软件、拉镜像），但公网**无法主动连进来** |
| **安全组** | 绑在网卡上的防火墙，规定允许哪些流量进来 |
| **NLB** | Network Load Balancer，四层（TCP）负载均衡器。我们用它做 apiserver 的统一入口 |
| **Route53 私有托管区** | 只在 VPC 内部生效的 DNS。`api.k8s.internal` 在公网上查不到 |
| **IAM instance profile** | 给 EC2 实例分配一个"身份"，实例上的程序可以凭它调用 AWS API，不需要把密钥写在机器上 |
| **SSM Session Manager** | 不开 22 端口也能登录机器。机器上的 SSM agent 主动往外连 AWS，你的登录请求由 AWS 转接过去 |

---

## 🧠 概念 3：代码导览

先花 15 分钟读一遍 `terraform/` 目录下的代码。不需要每一行都看懂，重点看注释。

| 文件 | 内容 | 重点看什么 |
|---|---|---|
| `versions.tf` / `providers.tf` | Terraform 和 provider 的版本、默认标签 | `default_tags`：所有资源都会打上 `Project=k8s-learning` |
| `variables.tf` | 所有可调的参数 | `cp_count`、`worker_count`：第 11 章会改它们 |
| `network.tf` | VPC、子网、路由表 | 公有/私有路由表的区别 |
| `nat.tf` + `templates/nat-userdata.sh.tftpl` | NAT 实例 | `source_dest_check = false`，以及开机脚本里的 `ip_forward` 和 `MASQUERADE` |
| `endpoints.tf` | S3 网关端点 | 为什么拉镜像的流量可以不走 NAT |
| `security.tf` | 安全组 | 每条规则的注释：哪个端口是给哪个组件用的 |
| `iam.tf` | 实例的 IAM 角色 | 为什么 control plane 和 worker 的权限不同 |
| `nodes.tf` | K8s 节点 | 固定私网 IP；`http_put_response_hop_limit` 为什么 cp 是 2、worker 是 1 |
| `api-lb.tf` | 内网 NLB + `api.k8s.internal` | **`preserve_client_ip = "false"`** 和 `/readyz` 健康检查的注释 |
| `ssm.tf` | SSM 会话设置 | 登录后用 bash、60 分钟空闲超时 |
| `scheduler.tf` + `lambda/autostop.py` | 每晚自动关机 | IAM 条件：只能 stop 带本项目标签的实例 |
| `budget.tf` | 预算告警 | |
| `outputs.tf` | apply 后打印的信息 | |

> 💡 读的时候有任何"为什么要这样写"的疑问，随时问我。

---

## 🛠 动手

### 步骤 1：填写变量

💻 **Mac：**

```bash
cd ~/Desktop/code/K8s-learning/terraform
cp terraform.tfvars.example terraform.tfvars
```

用编辑器打开 `terraform.tfvars`，把 `budget_email` 改成你的邮箱。其他值保持默认即可。

> `terraform.tfvars` 已经被 `.gitignore` 排除，不会提交到 git。

### 步骤 2：初始化

💻 **Mac：**

```bash
terraform init
```

`init` 会下载 provider 插件到 `.terraform/` 目录，并生成 `.terraform.lock.hcl`（锁定插件版本，这个文件**应该**提交到 git）。

### 步骤 3：预览变更（plan）

💻 **Mac：**

```bash
terraform plan
```

输出很长，不用慌。拉到最后，应该看到：

```
Plan: 88 to add, 0 to change, 0 to destroy.
```

（如果没填 `budget_email`，就是 87 个，因为少了预算告警。）

**在输出里找找下面这几行**，对照代码里的注释，想想为什么要这样设置：

💻 **Mac：**

```bash
terraform plan -no-color | grep -E 'source_dest_check|preserve_client_ip|http_put_response_hop_limit|private_ip  '
```

> 🔑 **养成习惯：apply 之前一定先 plan，并且认真看 plan 的输出。** 尤其要注意有没有 `destroy`（删除）或 `must be replaced`（销毁重建），生产事故往往就出在没看 plan。

### 步骤 4：创建（apply）

💻 **Mac：**

```bash
terraform apply
```

它会再展示一遍 plan，然后问你 `Enter a value:`，输入 `yes` 回车。

大约 **3~5 分钟**，其中 NLB 最慢。完成后会打印 outputs：

```
control_plane_endpoint = "api.k8s.internal:6443"
nodes = {
  "cp-1"     = { az = "us-east-1a", private_ip = "10.0.10.11", role = "control-plane", ... }
  "worker-1" = { az = "us-east-1a", private_ip = "10.0.10.21", role = "worker", ... }
  "worker-2" = { az = "us-east-1b", private_ip = "10.0.11.21", role = "worker", ... }
}
...
```

⏱️ **从这一刻开始计费。**

### 步骤 5：查看状态

实例刚开机，SSM agent 需要 1~3 分钟才能上线（节点还要等 NAT 实例完成初始化，才能连上 AWS）。

💻 **Mac：**

```bash
cd ~/Desktop/code/K8s-learning
./scripts/status.sh
```

等到第二张表里 4 台机器的 `Ping` 全部是 `Online`。还没到就过一分钟再运行一次。

### 步骤 6：登录 NAT 实例，看看 NAT 是怎么实现的

💻 **Mac：**

```bash
./scripts/ssm.sh nat
```

成功后提示符会变成 `(nat)ssm-user@ip-10-0-0-xx:~$`。下面的命令都在 NAT 实例上执行。

🖥️ **nat：**

```bash
# 1. 开机脚本执行完了吗？应该是 status: done
cloud-init status

# 2. 内核转发开关：1 表示开启。普通服务器是 0，不会帮别人转发包
sysctl net.ipv4.ip_forward

# 3. NAT 规则：从 10.0.0.0/16 来、要从 ens5 网卡出去的包，做 MASQUERADE
sudo iptables -t nat -S POSTROUTING

# 4. 这条规则持久化保存在这里，重启后由 netfilter-persistent 自动恢复
cat /etc/iptables/rules.v4

# 5. 网卡和路由
ip -br addr
ip route

# 6. 记下 NAT 实例的公网 IP，下一步要用
curl -s https://checkip.amazonaws.com
```

**MASQUERADE 在做什么？**

```
cp-1 发出的包：   源 10.0.10.11:52000  →  目的 <dl.k8s.io 的 IP>:443
                         │
                   到达 NAT 实例（因为私有子网的默认路由指向它）
                         │  MASQUERADE：把源地址改成 NAT 自己的地址，
                         │  并在 conntrack 表里记下这个映射关系
                         ▼
发往公网的包：    源 10.0.0.x:52000  →  目的 <dl.k8s.io 的 IP>:443
                         │  经 Internet Gateway 时，AWS 再把 10.0.0.x 换成 NAT 的公网 IP
                         ▼
回包到达 NAT：    目的 10.0.0.x:52000  →  查 conntrack 表，改回 10.0.10.11:52000，转发给 cp-1
```

> 💡 **记住 MASQUERADE 和 conntrack。** 到了 K8s 里你会再次见到它们：Pod 访问公网时，Calico 用 MASQUERADE；访问 Service 时，kube-proxy 用 DNAT。原理一模一样。

输入 `exit` 退出。

### 步骤 7：登录 cp-1，验证网络

💻 **Mac：**

```bash
./scripts/ssm.sh cp-1
```

🖥️ **cp-1：**

```bash
# 1. 这台机器是谁
hostname          # ip-10-0-10-11 —— 以后它就是 K8s 里的节点名
hostname -f       # ip-10-0-10-11.ec2.internal

# 2. 网卡和路由：默认网关是 10.0.10.1（AWS 子网的虚拟路由器），它会按路由表把包交给 NAT 实例
ip -br addr
ip route

# 3. 能上网吗？（经 NAT 出去）顺便看看 K8s 当前最新的稳定版本号
curl -s https://dl.k8s.io/release/stable.txt; echo

# 4. 我在公网上显示为哪个 IP？
curl -s https://checkip.amazonaws.com
```

**第 4 条的结果和你在 NAT 实例上看到的公网 IP 一样吗？** 想想为什么。（答案就在上一步的图里）

继续在 cp-1 上：

🖥️ **cp-1：**

```bash
# 5. DNS 服务器是谁？—— 10.0.0.2（VPC 自带的 DNS 解析器 = VPC 网段起始地址 + 2）
resolvectl status | grep -A1 'DNS Servers'

# 6. 解析私有域名：应该返回 3 个 10.0.x.x 的地址（NLB 在 3 个子网里各有一个节点）
dig +short api.k8s.internal     # 如果没有 dig 命令，用：getent ahosts api.k8s.internal

# 7. 尝试连接 apiserver 的入口：现在应该失败（Connection refused 或超时）
#    因为 apiserver 还不存在，第 03 章才会装
nc -vz -w 3 api.k8s.internal 6443

# 8. 和 worker-1 通吗？（安全组允许 VPC 内的 ICMP）
ping -c 3 10.0.10.21
```

最后看一下这台机器的"身份"。EC2 实例可以通过一个特殊地址 `169.254.169.254` 访问**实例元数据服务（IMDS）**，查询关于自己的信息，包括 IAM 角色的临时凭证：

🖥️ **cp-1：**

```bash
# IMDSv2：先用 PUT 拿一个临时 token，再带着 token 查询
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")

curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone; echo

curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/; echo
```

最后一条会输出 `k8s-lab-control-plane`，这就是 Terraform 给 cp-1 分配的 IAM 角色。（第 10 章的 EBS CSI driver 会用这个身份去创建磁盘。）

输入 `exit` 退出。

### 步骤 8：查看 NLB 的健康检查状态

💻 **Mac：**

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$(terraform -chdir=terraform output -raw api_target_group_arn)" \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table
```

现在 cp-1 是 **unhealthy**，原因是 `Target.FailedHealthChecks`：NLB 每 10 秒访问一次 `https://cp-1:6443/readyz`，而 apiserver 还不存在。

这是**预期中的**。第 03 章装好 apiserver 之后，你会看到它变成 `healthy`。

> 💡 有个细节：当**所有**目标都不健康时，NLB 会"fail open"，也就是照样把流量转发给所有目标（总比全部丢掉强）。所以 kubeadm init 期间，即使健康检查还没通过，经 NLB 访问 apiserver 也能成功。

### 步骤 9：练习收工和开工

💻 **Mac：**

```bash
./scripts/lab-down.sh
```

stop 之后，看一下私有子网的路由表：

💻 **Mac：**

```bash
aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=k8s-lab-private-rt" \
  --query 'RouteTables[].Routes[].{Dest:DestinationCidrBlock,Target:NetworkInterfaceId,State:State}' \
  --output table
```

`0.0.0.0/0` 这条路由的状态变成了 **`blackhole`**（黑洞）：目标网卡所在的 NAT 实例停了，发往公网的包无处可去。

再开工：

💻 **Mac：**

```bash
./scripts/lab-up.sh
```

脚本会先启动 NAT、等它就绪，再启动节点，最后等所有机器在 SSM 上线。启动后再查一次路由表，状态应该恢复为 `active`。

---

## ✅ 验证

全部打勾，本章就完成了：

- [ ] `terraform apply` 成功，`terraform plan` 再运行一次显示 `No changes`
- [ ] `./scripts/status.sh` 显示 4 台机器 `running`，SSM 全部 `Online`
- [ ] NAT 实例上 `ip_forward = 1`，并且能看到 MASQUERADE 规则
- [ ] cp-1 上 `curl -s https://dl.k8s.io/release/stable.txt` 能打印出版本号（例如 `v1.37.2`）
- [ ] cp-1 上 `checkip` 返回的是 NAT 实例的公网 IP
- [ ] cp-1 上 `dig api.k8s.internal` 能解析出 10.0.x.x 的地址
- [ ] NLB 目标 cp-1 显示 `unhealthy`（预期中的）
- [ ] `lab-down.sh` 后路由显示 `blackhole`；`lab-up.sh` 后恢复 `active`

---

## 🔍 深入原理

### 1. 为什么只有 1 个 control plane，也要在它前面放一个 NLB？

第 03 章执行 `kubeadm init` 时，有一个重要参数 **`controlPlaneEndpoint`**，也就是"集群的 apiserver 地址"。它会被写进：

- apiserver 的 TLS 证书（证书里列出了"我是谁"）
- 每个节点上 kubelet、kube-proxy 的配置文件
- 你的 kubeconfig

假如当时写的是 `10.0.10.11:6443`（cp-1 的 IP），等到第 11 章扩成 3 个 control plane 时，所有组件仍然只认 cp-1，cp-1 一挂集群就瘫了。要改的话，得重新签发证书、修改每个节点的配置，非常麻烦。

所以**从第一天起就用一个稳定的名字 `api.k8s.internal`**，指向 NLB。以后加 control plane，只需要把新机器注册到 NLB 后面，所有客户端都不用改。

> 这就是"为未来设计"：生产环境里很多决定一旦做出就很难改，`controlPlaneEndpoint` 就是其中之一。

### 2. `preserve_client_ip = "false"`：hairpin 问题

NLB 默认会**保留客户端的源 IP**：后端看到的包，源地址就是真实的客户端。大多数时候这很好，但在我们的场景里会出问题：

```
cp-1 上的 kubelet 访问 api.k8s.internal:6443
   源 10.0.10.11  ──►  NLB  ──► NLB 选中的目标恰好也是 cp-1
                               │
                               ▼  保留源 IP：cp-1 收到一个"源地址是自己"的包
                     cp-1 的回包直接发给"自己"，不经过 NLB
                     → 客户端等的是 NLB 的回包，连接卡死、超时
```

这叫 **hairpin（发卡弯）问题**。只有 1 个 control plane 时，NLB **每次**都会选中 cp-1，所以每次都会失败。

关掉源 IP 保留之后，NLB 会把源地址换成自己的 IP，回包就会先回到 NLB，再转给客户端。代价是 apiserver 的审计日志里看到的来源是 NLB 的 IP，不是真实客户端（第 16 章会提到）。这也是为什么安全组里 control plane 的 6443 端口要放行"来自 NLB 安全组"的流量。

### 3. SSM：没有任何入站端口，怎么登录的？

```
你的 Mac                 AWS SSM 服务                   cp-1（私有子网）
   │                         ▲  ▲                            │
   │ aws ssm start-session   │  │  SSM agent 开机后就"主动"    │
   └─────────────────────────┘  └── 经 NAT 往外连到 SSM 服务 ──┘
                    （双方都是出站连接，由 AWS 在中间接起来）
```

- cp-1 不需要公网 IP，安全组里也没有任何入站规则
- 谁能登录，由你的 IAM 权限决定（可以精确到"某个人只能登录某几台机器"）
- 还可以把会话的每一个字符都记录到 S3 或 CloudWatch 审计

**副作用**：SSM agent 要经过 NAT 才能出去。**NAT 挂了 = 登录不了私有子网的机器**。下面的💥环节就会体验到。

### 4. IMDS 和 hop limit

你刚才在 cp-1 上通过 `169.254.169.254` 拿到了 IAM 角色名，再往下查一层，就能拿到**真正的临时 AccessKey**。这意味着：**能访问 IMDS 的程序，就能以这台机器的身份调用 AWS API**。

`http_put_response_hop_limit` 限制 IMDSv2 的 token 响应能经过几跳网络：

- 宿主机上的进程（kubelet）：1 跳就够
- **容器里**的进程：包要先经过容器的虚拟网卡，多一跳，所以需要 2

我们把 worker 设成 1，这样 worker 上的业务 Pod **拿不到**实例凭证；control plane 设成 2，是因为第 10 章的 EBS CSI controller 运行在 Pod 里，需要凭证去创建 EBS 卷。第 16 章（安全）还会用 NetworkPolicy 进一步封堵。

---

## 💥 故意搞坏：关掉 NAT 的转发开关

**打开两个终端窗口。**

**窗口 A**：登录 cp-1，持续访问公网

💻 **Mac（窗口 A）：**

```bash
./scripts/ssm.sh cp-1
```

🖥️ **cp-1（窗口 A）：**

```bash
while true; do
  printf '%s  ' "$(date +%T)"
  curl -s -m 3 -o /dev/null -w '%{http_code}\n' https://dl.k8s.io/release/stable.txt || echo "FAIL"
  sleep 2
done
```

你会看到每 2 秒一行 `200`。

**窗口 B**：登录 NAT，关掉转发

💻 **Mac（窗口 B）：**

```bash
./scripts/ssm.sh nat
```

🖥️ **nat（窗口 B）：**

```bash
sudo sysctl -w net.ipv4.ip_forward=0
```

**观察窗口 A。** 你会发现：

1. 输出变成了 `FAIL`……或者**整个窗口卡住不动了**！

想想为什么会卡住？因为**你和 cp-1 之间的 SSM 会话本身也要经过 NAT**。NAT 不转发了，SSM 的数据也送不出来。

等 20~30 秒，在窗口 B 恢复：

🖥️ **nat（窗口 B）：**

```bash
sudo sysctl -w net.ipv4.ip_forward=1
```

窗口 A 应该会恢复，并且一下子刷出积压的输出（如果会话已经断开，重新登录即可）。在窗口 A 按 `Ctrl-C` 停止循环。

**这个实验说明了什么？**

- 一个看起来不起眼的内核参数，决定了整个私有子网能不能上网
- 排障时要想到"我用来排障的通道，是不是也依赖这个故障点"
- 窗口 B 能一直正常工作，是因为 NAT 实例自己在公有子网，有公网 IP，不依赖 NAT

### 选做：验证持久化

`sysctl -w` 只改了内存里的值，重启就没了。那我们写进 `/etc/sysctl.d/` 和 `/etc/iptables/rules.v4` 的配置，重启后还在吗？

🖥️ **nat：**

```bash
sudo reboot
```

等 1 分钟，再用 `./scripts/ssm.sh nat` 登录，检查 `sysctl net.ipv4.ip_forward` 和 `sudo iptables -t nat -S POSTROUTING` 是否依然正确。

---

## ❓ 思考题

**1. 如果 NAT 实例挂了，以后 K8s 集群内部 Pod 之间的通信会受影响吗？哪些功能会受影响？**

<details>
<summary>参考答案</summary>

**集群内部通信不受影响**。VPC 内部的流量（10.0.0.0/16）由路由表里的 `local` 路由直接送达，不经过 NAT。所以节点之间、Pod 之间、Pod 到 apiserver 都正常。

**受影响的**是所有需要访问公网的功能：拉取新镜像（已经缓存在节点上的镜像不受影响）、apt 安装软件、SSM 登录、cert-manager 申请证书、external-dns 更新 Cloudflare 记录等等。

这就是为什么生产环境通常每个 AZ 放一个 NAT Gateway，避免单点故障。我们为了省钱只用了一个。
</details>

**2. 为什么私有子网里的 cp-1 访问 checkip，看到的是 NAT 实例的公网 IP？**

<details>
<summary>参考答案</summary>

cp-1 的包经过 NAT 实例时，被 MASQUERADE 把源地址改成了 NAT 实例的私网 IP。离开 VPC 时，Internet Gateway 又把它换成了 NAT 实例的公网 IP。所以对外部世界来说，整个私有子网的所有机器都"长着同一张脸"。
</details>

**3. 安全组里有一条规则 `cp-6443-from-worker`：允许 worker 访问 control plane 的 6443 端口。既然节点都是经 NLB 访问 apiserver，为什么还需要它？**

<details>
<summary>参考答案</summary>

因为不是所有流量都经过 NLB。集群里有一个特殊的 Service 叫 `kubernetes`（ClusterIP 通常是 `10.96.0.1`），Pod 里的程序（例如 CoreDNS、各种 controller）通过它访问 apiserver。kube-proxy 会把发往 `10.96.0.1:443` 的流量 DNAT 到 apiserver 的**节点真实 IP**（`10.0.10.11:6443`），绕过 NLB 直接到达 cp-1。所以 worker 必须能直接访问 cp-1 的 6443。第 08 章会亲眼看到这条 DNAT 规则。
</details>

**4. 如果把 `terraform.tfvars` 里的 `cp_count` 从 1 改成 3，`terraform plan` 会显示什么变更？**

<details>
<summary>参考答案</summary>

会新增 4 个资源：`aws_instance.control_plane["cp-2"]`、`["cp-3"]`，以及它们在 NLB 目标组里的 2 个 `aws_lb_target_group_attachment`。已有的资源不会变化。

可以现在就试一下 `terraform plan -var cp_count=3` 看看（只 plan，**不要 apply**）。这正是 `for_each` 的好处：增减节点只影响对应的那几个资源。
</details>

**5. NLB 的健康检查为什么用 HTTPS `/readyz`，而不是简单地检查 6443 端口通不通？**

<details>
<summary>参考答案</summary>

TCP 检查只能说明"有进程在监听这个端口"。但 apiserver 进程活着，不代表它能正常工作，比如它连不上 etcd 时端口照样是通的。`/readyz` 是 apiserver 自己提供的就绪检查接口，它会检查 etcd 连接等内部状态，全部正常才返回 200。

用 `/readyz` 做健康检查，NLB 就能把"活着但不能干活"的 apiserver 从流量里摘掉。
</details>

---

## 🧹 收工

💻 **Mac：**

```bash
cd ~/Desktop/code/K8s-learning
./scripts/lab-down.sh

git add -A
git commit -m "ch01: AWS 网络地基"
```

**stop 之后仍然在计费的资源**：内网 NLB（约 $0.55/天）、EBS 磁盘（约 $0.26/天）、Route53 私有区，合计约 **$0.8/天**。

把 README 里第 00、01 章的状态改成 ✅。

**下一章预告**：第 02 章，我们会登录到每个节点上，亲手完成"把一台普通 Ubuntu 变成 K8s 节点"的全部准备工作。在那之前，我们会先用几个 Linux 命令，亲手造一个"简陋的容器"，搞清楚容器的本质到底是什么。
