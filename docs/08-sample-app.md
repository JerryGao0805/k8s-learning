# 第 08 章 · 示例应用上线：笔记墙

> 📍 **搭建篇**：只管把东西装好、确认能用。原理留到学习篇（这一章用到的对象分别在 **第 13 章 · 控制器**、**第 14 章 · Service**、**第 15 章 · 配置与调度**、**第 16 章 · 存储原理** 里拆开讲）。

## 🎯 做完是什么样

- 集群里跑着一个真正的应用 **notes-app**（笔记墙）：前端 web、后端 api、Postgres、Redis
- 镜像是你自己构建的（arm64），放在你账号的 ECR 私有仓库里
- 删掉 Postgres 的 Pod，数据还在（存在第 07 章的 EBS 卷上）
- 暂时用 `port-forward` 访问；第 09 章接上 `https://app.lab.<你的域名>`

大约 **1 小时**，全程在 **Mac** 上操作。

## 🗺 在整体里的位置

前几章搭的是"平台"，这一章第一次往平台上放"业务"。后面每一章都围绕这个应用：第 09 章给它接上 HTTPS 入口，第 10 章监控它的指标和日志，学习篇里用它做扩缩容、发布、故障演练。

```
             ┌──────── namespace: app ──────────────────────────────┐
  (第 09 章)  │  web ×2  (nginx，静态页面)                            │
  Gateway ──►│                                                      │
   /  → web  │  api ×2  (Go) ──► postgres-0 (StatefulSet + 5Gi EBS) │
   /api → api│              └──► redis ×1   (计数器，不持久化)        │
             └──────────────────────────────────────────────────────┘
```

## 🧩 新名词

| 词 | 一句话 |
|---|---|
| **ECR** | AWS 的私有镜像仓库。节点靠第 02 章装的 ecr-credential-provider 用自己的 IAM 角色登录拉取 |
| **Kustomize** | 不用模板语言的 YAML 组合工具：`base` 放公共部分，`overlays/lab` 只写这个环境的差异（这里是镜像地址和版本） |
| **StatefulSet** | 给"有状态"的程序用的控制器：Pod 名字固定（`postgres-0`），每个 Pod 有自己的盘，重建后挂回同一块 |
| **Secret** | 存密码一类的敏感配置。这里的数据库密码只放在集群里和本地的 `secrets/`，不进 git |

---

## 🛠 步骤

### 步骤 1：开工

💻 **Mac**（两个终端：一个跑隧道，一个敲命令）：

```bash
cd ~/Desktop/code/K8s-learning
./scripts/lab-up.sh                     # 如果机器是停着的
./scripts/api-tunnel.sh                 # 终端 1，保持开着
```

```bash
cd ~/Desktop/code/K8s-learning          # 终端 2
export KUBECONFIG=~/.kube/k8s-lab.yaml
kubectl get storageclass                # 有 gp3 (default)
```

Docker Desktop 要开着（构建镜像用）。

### 步骤 2：认识应用代码（看一眼就好）

| 目录 | 内容 |
|---|---|
| `app/api/` | Go 写的后端：`/api/notes`（Postgres）、`/api/hits`（Redis 计数）、`/api/info`、`/healthz`、`/readyz`、`/metrics` |
| `app/web/` | 一个静态页面 + nginx 配置 |
| `app/deploy/base/` | 和环境无关的 K8s 清单：Deployment、StatefulSet、Service、ConfigMap |
| `app/deploy/overlays/lab/` | 这个环境的差异：镜像换成 ECR 地址、版本 `0.1.0` |
| `app/build-push.sh` | 构建 arm64 镜像并推送到 ECR |

细节见 [`app/README.md`](../app/README.md)。

### 步骤 3：建 ECR 仓库（Terraform）

[`terraform/ecr.tf`](../terraform/ecr.tf)：两个仓库 `k8s-lab/api`、`k8s-lab/web`，推送时扫描漏洞，只保留最近 10 个镜像。

```bash
cd terraform
terraform plan          # Plan: 4 to add, 0 to change, 0 to destroy.
terraform apply
cd ..
```

### 步骤 4：构建并推送镜像

```bash
./app/build-push.sh 0.1.0
```

它做了三件事：登录 ECR（凭证 12 小时有效）→ 用 `docker buildx --platform linux/arm64` 构建 → 推送。Mac 是 M 系列芯片，本身就是 arm64，所以构建很快；如果在 Intel 机器上构建，忘了 `--platform` 会在节点上报 `exec format error`。

最后应该看到两次 `pushing manifest for ...k8s-lab/api:0.1.0`、`...k8s-lab/web:0.1.0`。

### 步骤 5：数据库密码

```bash
mkdir -p secrets && chmod 700 secrets
[ -f secrets/postgres-password ] || openssl rand -base64 24 | tr -d '/+=\n' > secrets/postgres-password
chmod 600 secrets/postgres-password

kubectl create namespace app
kubectl -n app create secret generic postgres-auth --from-file=password=secrets/postgres-password
```

`secrets/` 在 `.gitignore` 里，不会被提交。⚠️ Postgres 只在**第一次初始化空盘**时读这个密码，之后再改 Secret，数据库里的密码不会跟着变。

### 步骤 6：部署

```bash
export ECR_REGISTRY=$(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com
kubectl kustomize app/deploy/overlays/lab | sed "s|ECR_REGISTRY|${ECR_REGISTRY}|g" | kubectl apply -f -
```

- `kubectl kustomize`：把 base 和 overlay 合成最终的 YAML。
- `sed`：overlay 里写的是占位符 `ECR_REGISTRY`，部署时才换成真实地址，这样你的 AWS 账号 ID 不会进 git。

等它们起来：

```bash
kubectl -n app rollout status statefulset/postgres --timeout=240s
kubectl -n app rollout status deploy/api --timeout=240s
kubectl -n app get pods,pvc -o wide
```

```
NAME                        READY   STATUS    NODE
pod/api-74b5f8566-85d97     1/1     Running   ip-10-0-11-21
pod/api-74b5f8566-pt9br     1/1     Running   ip-10-0-10-21
pod/postgres-0              1/1     Running   ip-10-0-10-21
pod/redis-df999b9cb-gh4df   1/1     Running   ip-10-0-10-21
pod/web-85c5bfb855-l6ksr    1/1     Running   ip-10-0-11-21
pod/web-85c5bfb855-tkcrx    1/1     Running   ip-10-0-10-21

NAME                                    STATUS   CAPACITY   STORAGECLASS
persistentvolumeclaim/data-postgres-0   Bound    5Gi        gp3
```

- api 刚启动时可能有几秒 0/1：它在等 Postgres，startupProbe 会耐心等。
- 两个 api、两个 web 尽量分在不同 worker 上（topologySpreadConstraints）。

确认镜像确实是从 ECR 拉的：

```bash
kubectl -n app get events --field-selector reason=Pulled -o custom-columns=MSG:.message --no-headers | grep dkr.ecr | head -2
```

```
Successfully pulled image "<账号ID>.dkr.ecr.us-east-1.amazonaws.com/k8s-lab/api:0.1.0" in 761ms ...
```

### 步骤 7：试用

```bash
kubectl -n app port-forward svc/api 18080:80 &
curl -s localhost:18080/readyz; echo
curl -s -XPOST localhost:18080/api/notes -H 'content-type: application/json' -d '{"text":"第 08 章：第一条 note"}'; echo
curl -s localhost:18080/api/hits; echo
curl -s localhost:18080/api/info; echo
```

```
{"postgres":"ok","redis":"ok"}
{"id":1,"text":"第 08 章：第一条 note","created_at":"2026-11-18T21:44:32.65548Z"}
{"hits":1,"pod":"api-74b5f8566-85d97"}
{"pod":"api-74b5f8566-85d97","version":"0.1.0"}
```

`port-forward` 只连到一个 Pod，所以 `pod` 总是同一个；第 09 章经过 Gateway 访问时，会看到两个 api 轮流应答。

### 步骤 8：数据真的在盘上吗

```bash
kill %1                                  # 停掉上面的 port-forward
kubectl -n app delete pod postgres-0
kubectl -n app wait --for=condition=Ready pod/postgres-0 --timeout=180s

kubectl -n app port-forward svc/api 18080:80 &
sleep 3; curl -s localhost:18080/api/notes; echo
kill %1
```

```
[{"id":1,"text":"第 08 章：第一条 note","created_at":"2026-11-18T21:44:32.65548Z"}]
```

StatefulSet 重建了 `postgres-0`，并把它挂回了同一块 EBS 卷（`data-postgres-0`），数据还在。

页面也可以先看一眼：`kubectl -n app port-forward svc/web 18081:80`，浏览器打开 `http://localhost:18081`。这时页面上会显示"api 暂时不可用"：前端通过 `/api` 访问后端，而把 `/api` 转给 api 是第 09 章 Gateway 的工作。

---

## ✅ 验收

- [ ] ECR 里有 `k8s-lab/api:0.1.0`、`k8s-lab/web:0.1.0`
- [ ] `kubectl -n app get pods`：6 个 Pod 全部 Running
- [ ] `data-postgres-0` 是 Bound
- [ ] `/readyz` 返回 `{"postgres":"ok","redis":"ok"}`
- [ ] 删掉 `postgres-0` 后，之前写的 note 还在

---

## 🧹 收工

```bash
./scripts/lab-down.sh
git add -A
git commit -m "ch08: 示例应用 notes-app"
```

机器关了之后，Postgres 的 EBS 卷还在（按 5Gi 收费，约 $0.4/月），下次开机数据都在。

**下一章**：第 09 章，`https://app.lab.<你的域名>`。

---

## 🧯 出问题时

| 现象 | 可能的原因 | 怎么查 |
|---|---|---|
| `build-push.sh` 报 `ECR 仓库不存在` | 还没 apply `terraform/ecr.tf` | 回到步骤 3 |
| `docker: Cannot connect to the Docker daemon` | Docker Desktop 没开 | 打开 Docker Desktop |
| Pod `ImagePullBackOff`，Events 里 `no basic auth credentials` / `401` | 节点没能用 ecr-credential-provider 登录 ECR | `./scripts/run-on-nodes.sh scripts/node/check-node.sh worker-1` 看 [ECR 凭证插件] 那几项；`journalctl -u kubelet \| grep -i credential` |
| Pod `ImagePullBackOff`，`not found` | 版本号对不上 | overlay 里的 `newTag` 和推送的版本是否一致 |
| Pod `CreateContainerConfigError` | Secret `postgres-auth` 没建 | `kubectl -n app get secret`；回到步骤 5 |
| `postgres-0` 一直 Pending | PVC 建不出来 | `kubectl -n app describe pvc data-postgres-0`；见第 07 章的排障表 |
| api 一直 0/1，日志里 `password authentication failed` | 盘上的数据库是用旧密码初始化的 | 实验环境里最简单：删掉 StatefulSet 和 PVC（**数据会丢**），重新部署 |
| api 一直 0/1，日志里在重试连接 | Postgres 还没就绪 | `kubectl -n app logs postgres-0`；`kubectl -n app logs deploy/api` |

---

## 📖 学习篇会深入

- **第 13 章 · 控制器**：Deployment → ReplicaSet → Pod；滚动更新、回滚；StatefulSet 和 Deployment 的区别
- **第 14 章 · Service**：`api`、`web` 的 ClusterIP 怎么变成 iptables 规则；`postgres` 为什么是 headless；集群 DNS
- **第 15 章 · 配置与调度**：ConfigMap / Secret 怎么进到容器里；requests/limits 和 QoS；三种探针各管什么；topology spread
- **第 16 章 · 存储原理**：`volumeClaimTemplates` 和 `data-postgres-0` 的关系
- **第 20 章 · 扩缩容与发布**：发布 0.1.1、金丝雀
- **第 21 章 · 安全加固**：Pod 的 securityContext（非 root、只读根文件系统），Pod Security Standards
