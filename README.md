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

每章做完后，把 ⬜ 改成 ✅。

| # | 章节 | 你会学到 | 状态 |
|---|---|---|---|
| **阶段 0 · 准备** ||||
| 00 | [前置准备与全局概览](docs/00-prerequisites.md) | K8s 架构全景、工具安装、费用模型 | ⬜ |
| 01 | [AWS 网络地基](docs/01-aws-foundation.md) | Terraform、VPC/子网/路由、NAT 原理、安全组、SSM、内网 NLB | ⬜ |
| **阶段 1 · 搭建集群** ||||
| 02 | 节点准备 | 容器的本质（namespace/cgroup）、containerd、kubeadm 安装 | ⬜ |
| 03 | kubeadm init | 证书体系、static pod、etcd、控制面组件 | ⬜ |
| 04 | 安装 Calico | CNI 规范、VXLAN、Pod 网络底层 | ⬜ |
| 05 | 加入 worker 与远程访问 | TLS bootstrap、CSR、kubeconfig | ⬜ |
| **阶段 2 · 核心对象** ||||
| 06 | Pod 与一次请求的旅程 | Pod、组件协作链路、直接查看 etcd | ⬜ |
| 07 | 控制器 | Deployment、DaemonSet、Job、reconcile 循环 | ⬜ |
| 08 | Service 与集群内网络 | ClusterIP/NodePort、iptables、CoreDNS | ⬜ |
| 09 | 配置、资源与调度 | ConfigMap/Secret、探针、QoS、亲和性、污点 | ⬜ |
| 10 | 存储 | PV/PVC/StorageClass、EBS CSI、StatefulSet | ⬜ |
| **阶段 3 · 生产化** ||||
| 11 | etcd 备份与控制面高可用 | 快照恢复、Raft 多数派、leader 选举 | ⬜ |
| 12 | 示例应用上线 | Dockerfile、ECR、Kustomize | ⬜ |
| 13 | 流量入口 | Gateway API、cert-manager、external-dns | ⬜ |
| **阶段 4 · 进阶** ||||
| 14 | 可观测性 | Prometheus、Grafana、Loki | ⬜ |
| 15 | 扩缩容与发布 | HPA、PDB、金丝雀/蓝绿 | ⬜ |
| 16 | 安全加固 | RBAC、Pod Security、NetworkPolicy、加密、审计、Kyverno | ⬜ |
| 17 | GitOps | Helm、Argo CD、GitHub Actions | ⬜ |
| 18 | 运维 I | etcd 定期备份、集群升级、证书续期 | ⬜ |
| 19 | 运维 II · 故障演练 | 排障方法论、常见故障实战 | ⬜ |
| 20 | 毕业 | 销毁环境、回顾、后续方向 | ⬜ |

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
| 第 01–10 章（1 CP + 2 worker） | 约 $25/月（内网 NLB、EBS 磁盘、Route53） | 约 $0.21/小时 | 约 $35/月 |
| 第 11–12 章（3 CP + 3 worker） | 约 $32/月 | 约 $0.35/小时 | 约 $46/月 |
| 第 13 章起（再加公网 NLB） | 约 $52/月 | 约 $0.36/小时 | 约 $66/月 |

- **stop 之后，实例的小时费就停了**，但磁盘、负载均衡器会继续计费。
- 长时间不学（比如超过两周），可以 `terraform destroy` 全部删掉，之后需要按章节重新搭一遍。
- 已经配了 AWS Budgets 告警（$80/月）。

---

## 目录结构

```
K8s-learning/
├── README.md            ← 你在这里
├── docs/                每章的 lab 文档 + cheatsheet.md
├── terraform/           AWS 基础设施代码
├── scripts/             开工/收工/登录等小工具
├── manifests/           每章用到的 YAML（按章节分目录）
├── app/                 示例应用源码（第 12 章）
└── gitops/              Argo CD 配置（第 17 章）
```

常用命令速查：[docs/cheatsheet.md](docs/cheatsheet.md)
