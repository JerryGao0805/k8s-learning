# K8s-learning：在 AWS 上从零搭建生产级 Kubernetes 集群

用 **kubeadm** 在 **AWS EC2** 上亲手搭一个高可用的 Kubernetes 集群，再在上面部署一个真实的多服务应用，把存储、流量入口、监控、安全、GitOps、升级、故障排查都完整走一遍。

> 学习方式：每一章是一份 lab 文档，**所有命令由你自己敲**。遇到报错不要慌，报错正是学习的好机会，把报错贴出来，我们一起排查。

---

## 最终架构

```
                           Internet
                              │
  Cloudflare DNS *.lab.<你的域名>               你的 Mac
            │                                 (kubectl → 127.0.0.1:16443
            ▼                                   经 SSM 端口转发)
 ┌──────────────────── VPC 10.0.0.0/16（3 个可用区）──────────────────┐
 │ 公有子网                                                            │
 │   [公网 NLB :80/:443]                    [NAT 实例]                  │
 │          │                                  ▲ 节点经它访问公网        │
 │ 私有子网 │ NodePort                          │                        │
 │          ▼                                  │                        │
 │   worker-1/2/3  ◄──── Calico VXLAN ────►  cp-1/2/3                  │
 │   (应用 Pods、Envoy Gateway)               (apiserver、etcd、        │
 │                                             scheduler、controller)   │
 │                         [内网 API NLB :6443] ◄ api.k8s.internal      │
 └─────────────────────────────────────────────────────────────────────┘
```

| 层 | 选型 |
|---|---|
| 基础设施 | Terraform（AWS us-east-1）、Graviton（arm64）实例、私有子网 + 自建 NAT 实例、SSM 登录（不开 SSH） |
| 集群 | kubeadm、Kubernetes v1.36 → 升级到 v1.37、containerd 2.x、3 个 control plane（stacked etcd）+ 3 个 worker |
| 网络 | Calico（VXLAN）+ kube-proxy、Gateway API（Envoy Gateway）、公网 NLB、external-dns + cert-manager（Cloudflare，Let's Encrypt） |
| 存储 | AWS EBS CSI driver |
| 进阶 | kube-prometheus-stack、Loki、HPA、RBAC/PSA/NetworkPolicy/Kyverno、Argo CD、etcd 备份、版本升级、故障演练 |

---

## 课程目录与进度

课程分两段：

- **搭建篇（00–10）**：先把整套系统搭起来：集群、高可用、存储、示例应用、HTTPS 入口、监控。每一步只讲"它是什么"，原理留到学习篇。做完之后，浏览器里能打开你的应用，Grafana 里能看到整个集群。
- **学习篇（11–25）**：在搭好的系统上逐块拆开：讲原理、看现场、故意搞坏再修好。

第 00–03 章写于改版之前，搭建和原理是讲在一起的。

每章做完后，把 ⬜ 改成 ✅。

| # | 章节 | 内容 | 状态 |
|---|---|---|---|
| **搭建篇** ||||
| 00 | [前置准备与全局概览](docs/00-prerequisites.md) | K8s 架构全景、工具安装、费用模型 | ✅ |
| 01 | [AWS 网络地基](docs/01-aws-foundation.md) | Terraform、VPC/子网/路由、NAT 原理、安全组、SSM、私有 DNS | ✅ |
| 02 | [节点准备](docs/02-node-prep.md) | 容器的本质（namespace/cgroup）、containerd、kubeadm 安装、SSM Run Command | ✅ |
| 03 | [kubeadm init](docs/03-kubeadm-init.md) | 控制面组件、证书即身份、kubeconfig、static pod、etcd 一瞥、kubelet 证书 | ✅ |
| 04 | [安装 Calico](docs/04-calico.md) | 网络插件、operator 与 CRD、Pod 网络冒烟测试 | ✅ |
| 05 | [加入 worker 与远程 kubectl](docs/05-join-workers.md) | kubeadm join、批准 kubelet 证书、在 Mac 上用 kubectl | ✅ |
| 06 | 扩成高可用 | 3 个 control plane + 3 个 worker、etcd 快照 | ⬜ |
| 07 | [存储](docs/07-storage.md) | Helm、EBS CSI、StorageClass | ✅ |
| 08 | [示例应用上线](docs/08-sample-app.md) | Dockerfile、ECR、Kustomize、Postgres | ✅ |
| 09 | HTTPS 入口 | Envoy Gateway、cert-manager、external-dns | ⬜ |
| 10 | [监控与日志](docs/10-monitoring.md) | metrics-server、Prometheus、Grafana、Loki | ✅ |
| **学习篇** ||||
| 11 | Pod 网络 | CNI、veth、/32 与 proxy ARP、IPAM、跨节点 VXLAN、CrossSubnet 演练 | ⬜ |
| 12 | 节点与 Pod 的一生 | TLS bootstrap、组件协作链路、直接查看 etcd、节点失联与驱逐 | ⬜ |
| 13 | 控制器 | Deployment、DaemonSet、Job、reconcile 循环 | ⬜ |
| 14 | Service 与集群内网络 | ClusterIP/NodePort、iptables、CoreDNS | ⬜ |
| 15 | 配置、资源与调度 | ConfigMap/Secret、探针、QoS、亲和性、污点 | ⬜ |
| 16 | 存储原理 | PV/PVC/StorageClass、CSI、StatefulSet、可用区绑定 | ⬜ |
| 17 | etcd 与高可用 | Raft 多数派、leader 选举、快照与恢复 | ⬜ |
| 18 | 一次 HTTPS 请求的旅程 | Gateway API、证书自动签发、DNS 自动化 | ⬜ |
| 19 | 可观测性实战 | PromQL、Grafana、日志查询、告警 | ⬜ |
| 20 | 扩缩容与发布 | HPA、PDB、金丝雀/蓝绿 | ⬜ |
| 21 | 安全加固 | RBAC、Pod Security、NetworkPolicy、加密、审计、Kyverno | ⬜ |
| 22 | 运维 I | etcd 定期备份、集群升级、证书续期 | ⬜ |
| 23 | 运维 II · 故障演练 | 排障方法论、常见故障实战 | ⬜ |
| 24 | GitOps | Helm 深入、Argo CD、GitHub Actions。放在最后：装上 Argo CD 后，手动的改动会被它改回去 | ⬜ |
| 25 | 毕业 | 销毁环境、回顾、后续方向 | ⬜ |

> 后面的章节会在你做完前一章之后再写，这样可以根据你实际遇到的情况调整内容。

---

## 每次开工 / 收工

💻 **Mac：**

```bash
cd ~/Desktop/code/K8s-learning

./scripts/lab-up.sh        # 开工：先启动 NAT，再启动全部节点，等它们在 SSM 上线
./scripts/status.sh        # 查看所有机器的状态
./scripts/ssm.sh cp-1      # 登录某个节点（cp-1 / worker-1 / nat ...）

./scripts/lab-down.sh      # 收工：stop 所有实例（集群状态保留）
```

**忘了收工也没关系**：每天凌晨 2 点（美东时间）会自动 stop 所有实例。哪天需要通宵，先运行 `./scripts/autostop.sh off`。

---

## 费用

| 阶段 | 停机时的固定费用 | 运行时的费用 | 每月学 40 小时的估算 |
|---|---|---|---|
| 第 01–05 章（1 CP + 2 worker） | 约 $9/月（EBS 磁盘、Route53） | 约 $0.21/小时 | 约 $17/月 |
| 第 06 章起（3 CP + 3 worker） | 约 $16/月 | 约 $0.34/小时 | 约 $30/月 |
| LB 限制解除后（再加内网和公网 NLB） | 约 $52/月 | 约 $0.36/小时 | 约 $66/月 |

- **stop 之后，实例的小时费就停了**，但磁盘、负载均衡器会继续计费。
- 新 AWS 账号可能不允许创建负载均衡。第 06 章（内网 API NLB）和第 09 章（公网入口）原本要用；**没解除也能继续**：第 06 章先用 DNS 轮询，第 09 章换一种入口方案。尽早按 [第 01 章附录](docs/01-aws-foundation.md#-附录申请解除负载均衡限制) 开 support case 解除限制。
- 长时间不学（比如超过两周），可以 `terraform destroy` 全部删掉，之后照着搭建篇重新搭一遍。
- 已经配了 AWS Budgets 告警（$80/月）。

---

## 目录结构

```
K8s-learning/
├── README.md            ← 你在这里
├── docs/                每章的 lab 文档 + cheatsheet.md（drafts/ 里是还没定稿的章节素材）
├── terraform/           AWS 基础设施代码
├── scripts/             开工/收工/登录等小工具
├── manifests/           每章用到的 YAML（按章节分目录）
├── app/                 示例应用源码（第 08 章）
└── gitops/              Argo CD 配置（第 24 章）
```

常用命令速查：[docs/cheatsheet.md](docs/cheatsheet.md)
