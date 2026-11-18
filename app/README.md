# 示例应用：notes-app

一个很小的"笔记 + 点击计数"应用：前端 nginx + Go API + Postgres + Redis。
它的作用是给集群一个真实的负载，用来练习 Deployment、StatefulSet、Service、探针、存储、Gateway、监控等。

## 架构

```
浏览器  https://<应用域名>
   │
   ▼
Gateway（Envoy Gateway + HTTPRoute，按路径分流，第 09 章）
   │
   ├── /api/*  ──► Service api :80 ──► api Pod ×2（Go，:8080）
   │                                     ├──► Service postgres :5432（headless）──► postgres-0
   │                                     │       StatefulSet，数据在 5Gi EBS 卷上（StorageClass gp3）
   │                                     └──► Service redis :6379 ──► redis Pod ×1（只在内存里，不持久化）
   │
   └── /       ──► Service web :80 ──► web Pod ×2（nginx，:8080，只提供静态页面 index.html）
```

所有资源都在 `app` 命名空间，带 `app.kubernetes.io/part-of: notes-app` 标签。

## 目录

```
app/
├── api/                Go 后端：main.go（启动、连库、优雅退出）、handlers.go（接口）、observability.go（指标、日志）
├── web/                index.html（页面）+ nginx.conf
├── deploy/
│   ├── base/           和环境无关的 K8s 清单（Kustomize base）
│   └── overlays/lab/   lab 环境：把占位镜像名换成 ECR 地址和版本号
└── build-push.sh       构建 arm64 镜像并推送到 ECR
```

## API 接口

| 方法和路径 | 说明 |
|---|---|
| `GET /api/notes` | 最新 50 条笔记 |
| `POST /api/notes` | 新建笔记，请求体 `{"text": "..."}`（1–500 字），返回 201 |
| `GET /api/hits` | Redis 计数 +1，返回 `{"hits": N, "pod": "<Pod 名>"}`，多点几次能看到负载均衡 |
| `GET /api/info` | `{"pod": "...", "version": "..."}` |
| `GET /healthz` | 存活探针（liveness）：进程活着就返回 200 |
| `GET /readyz` | 就绪探针（readiness）：Postgres 和 Redis 都能在 1 秒内 ping 通才返回 200，否则 503 |
| `GET /metrics` | Prometheus 指标：`http_requests_total`、`http_request_duration_seconds`，以及 Go 运行时指标 |

配置全部来自环境变量：`PGHOST` `PGPORT` `PGUSER` `PGPASSWORD` `PGDATABASE`（libpq 标准变量）、`REDIS_ADDR`（默认 `redis:6379`）、`PORT`（默认 `8080`）。
日志是 JSON，每个请求一行（`/healthz`、`/readyz`、`/metrics` 太频繁，不记日志，只记指标）。

## 构建并推送镜像

两个 ECR 仓库 `k8s-lab/api`、`k8s-lab/web` 由 Terraform 创建（`terraform/ecr.tf`，第 08 章）。

在仓库根目录执行（参数是版本号，默认 `0.1.0`）：

```bash
./app/build-push.sh 0.1.0
```

改了代码要发新版本时，换一个新版本号（比如 `0.1.1`），并同步修改 `deploy/overlays/lab/kustomization.yaml` 里的 `newTag`。
同一个 tag 重复推送的话，节点上已经缓存的旧镜像不会被重新拉取。

## 部署到集群

前提：`gp3` StorageClass 已创建（第 07 章）；节点上的 ecr-credential-provider 已装好（第 02 章），节点才能拉 ECR 私有镜像。

```bash
# 1. 先建命名空间，再建数据库密码 Secret。Secret 不放进 git，只在集群里手动创建。
kubectl apply -f app/deploy/base/namespace.yaml
# 密码随机生成，存在 secrets/postgres-password（已被 .gitignore 忽略）
mkdir -p secrets && [ -f secrets/postgres-password ] || openssl rand -hex 16 > secrets/postgres-password
kubectl -n app create secret generic postgres-auth --from-file=password=secrets/postgres-password

# 2. 渲染清单 -> 把 ECR_REGISTRY 占位符换成真实地址 -> 应用到集群
export ECR_REGISTRY=$(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com
kubectl kustomize app/deploy/overlays/lab | sed "s|ECR_REGISTRY|${ECR_REGISTRY}|g" | kubectl apply -f -

# 3. 查看状态
kubectl -n app get pods,svc,pvc
kubectl -n app logs deploy/api

# 4. 还没配 Gateway 时，可以用端口转发直接访问 api
kubectl -n app port-forward svc/api 8080:80
curl localhost:8080/api/hits        # 另开一个终端执行
```

几点说明：

- 为什么不直接 `kubectl apply -k`：overlay 里的 `ECR_REGISTRY` 是占位符，必须先用 sed 换掉。这样 AWS 账号 ID 不会进 git。
- `POSTGRES_PASSWORD` 只在 Postgres **第一次初始化空磁盘**时生效。之后再改 Secret，数据库里的密码不会变，api 会连不上。
  要换密码，得进数据库用 `ALTER USER` 改，或者删掉 PVC 重新初始化（数据会丢）。
- 删除 StatefulSet 不会删除 PVC（EBS 卷还在、继续计费）。彻底清理要再执行 `kubectl -n app delete pvc data-postgres-0`。

## 本地测试（不需要集群）

```bash
docker network create notes-net
docker run -d --name notes-pg --network notes-net --network-alias postgres \
  -e POSTGRES_DB=app -e POSTGRES_USER=app -e POSTGRES_PASSWORD=devpass \
  public.ecr.aws/docker/library/postgres:18-alpine
docker run -d --name notes-redis --network notes-net --network-alias redis \
  public.ecr.aws/docker/library/redis:8-alpine

docker build -t notes-api:dev app/api
docker run -d --name notes-api --network notes-net -p 8080:8080 \
  -e PGHOST=postgres -e PGUSER=app -e PGDATABASE=app -e PGPASSWORD=devpass notes-api:dev

curl localhost:8080/readyz
curl -X POST localhost:8080/api/notes -d '{"text": "你好，K8s"}'
curl localhost:8080/api/notes
curl localhost:8080/api/hits
curl -s localhost:8080/metrics | grep http_requests_total
docker logs notes-api

docker build -t notes-web:dev app/web
docker run -d --name notes-web -p 8081:8080 notes-web:dev
open http://localhost:8081
# 页面能打开，但本地没有 Gateway 帮忙转发 /api，所以页面上会显示"api 暂时不可用"。这是正常的。

# 清理
docker rm -f notes-pg notes-redis notes-api notes-web
docker network rm notes-net
```
