# 第 10 章 · 监控与日志：Prometheus、Grafana、Loki

> 📍 **搭建篇**：只管把东西装好、确认能用。原理留到学习篇（这一章对应 **第 19 章 · 可观测性实战**）。

## 🎯 做完是什么样

- `kubectl top nodes` / `kubectl top pods` 有数据
- Prometheus 抓到整个集群的指标：apiserver、etcd、controller-manager、scheduler、kube-proxy、kubelet、节点、示例应用，**全部 up**
- Grafana 里有 29 个现成的 dashboard，还能在同一个界面里查日志（Loki）
- 所有 Pod 的日志都被收进 Loki，保留 7 天

大约 **1 小时**，全程在 **Mac** 上操作。

## 🗺 在整体里的位置

到第 09 章为止，集群和应用都跑起来了，但"跑得怎么样"只能靠 `kubectl get` 和 `kubectl logs` 一个个看。这一章装上一整套可观测性工具：**指标**（数字随时间的变化，Prometheus 采集、Grafana 画图）和**日志**（Alloy 在每个节点上收集、Loki 存储、Grafana 查询）。学习篇里排障、压测、故障演练都靠它们。

```
  每个节点                                      monitoring 命名空间
  ┌──────────────────────────┐
  │ node-exporter :9100      │◄──── 抓 ─────┐
  │ kubelet :10250           │◄──── 抓 ─────┤   Prometheus ──► Grafana ◄── 你（浏览器）
  │ kube-proxy :10249        │◄──── 抓 ─────┤   （20Gi EBS）       ▲
  │ (cp) etcd/cm/scheduler   │◄──── 抓 ─────┘                     │
  │ Pod 的 /metrics          │◄──── 抓 （ServiceMonitor）          │
  │                          │                                   │
  │ /var/log/pods ──► Alloy ─┼──── 推 ────►  Loki（10Gi EBS）──────┘
  └──────────────────────────┘
```

## 🧩 新名词

| 词 | 一句话 |
|---|---|
| **metrics-server** | 只保存"此刻"各节点和 Pod 用了多少 CPU / 内存，给 `kubectl top` 和自动扩缩容（HPA）用 |
| **Prometheus** | 每隔一段时间去各个目标（target）的 `/metrics` 拉一次数字，存成时间序列 |
| **ServiceMonitor** | Prometheus Operator 的 CRD："去抓这些 Service 的这个端口"，operator 帮你翻译成 Prometheus 配置 |
| **Grafana** | 画图和查询的网页界面，数据源可以是 Prometheus、Loki 等 |
| **Loki / Alloy** | Loki 存日志（只给日志建标签索引，不建全文索引，所以省资源）；Alloy 是每个节点上的收集器 |

---

## 🛠 步骤

### 步骤 1：开工

💻 **Mac**（两个终端）：

```bash
cd ~/Desktop/code/K8s-learning
./scripts/lab-up.sh                     # 如果机器是停着的
./scripts/api-tunnel.sh                 # 终端 1，保持开着
```

```bash
cd ~/Desktop/code/K8s-learning          # 终端 2
export KUBECONFIG=~/.kube/k8s-lab.yaml
```

### 步骤 2：补安全组规则（Terraform）

Prometheus 会跑在 worker 上，要去抓 control plane 上 etcd（2381）、controller-manager（10257）、scheduler（10259）、kube-proxy（10249）、node-exporter（9100）的指标，以及其他 worker 上的 10249、9100。第 03 章已经让这些组件监听 `0.0.0.0`，但安全组还没放行。[`terraform/security.tf`](../terraform/security.tf) 里新加了 7 条规则（搜 "第 10 章"）。

```bash
cd terraform
terraform plan          # Plan: 7 to add, 0 to change, 0 to destroy.
terraform apply
cd ..
```

为什么来源写的是 worker 安全组，而不是 Pod 的 IP：Pod 访问节点 IP 时，Calico 的 natOutgoing 会把源地址换成 Pod 所在节点的 IP。📖 第 11 章。

### 步骤 3：metrics-server

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install metrics-server metrics-server/metrics-server --version 3.14.0 -n kube-system --wait
kubectl top nodes                       # 装完等半分钟再看
```

```
NAME            CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
ip-10-0-10-11   269m         13%      1973Mi          52%
ip-10-0-10-21   68m          3%       818Mi           10%
ip-10-0-11-21   52m          2%       835Mi           10%
```

**没有**加网上教程常见的 `--kubelet-insecure-tls`：第 03、05 章批准过每个节点 kubelet 的 serving 证书，metrics-server 可以正常校验它们。

### 步骤 4：kube-prometheus-stack

一个 chart 装好 Prometheus Operator、Prometheus、Alertmanager、Grafana、node-exporter、kube-state-metrics，外加现成的告警规则和 dashboard。

先建 Grafana 管理员密码（随机生成，存在 `secrets/`，不进 git）：

```bash
mkdir -p secrets
[ -f secrets/grafana-admin-password ] || openssl rand -base64 24 | tr -d '/+=\n' > secrets/grafana-admin-password
chmod 600 secrets/grafana-admin-password

kubectl create namespace monitoring
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin --from-file=admin-password=secrets/grafana-admin-password
```

[`manifests/ch10-monitoring/kube-prometheus-stack-values.yaml`](../manifests/ch10-monitoring/kube-prometheus-stack-values.yaml) 改了这些：

| 设置 | 为什么 |
|---|---|
| `grafana.admin.existingSecret` | 密码从上面的 Secret 读，不写进 values |
| `grafana.additionalDataSources` | 加一个 Loki 数据源 |
| `prometheus.prometheusSpec.retention` / `retentionSize` | 保留 7 天，最多 18GB |
| `...SelectorNilUsesHelmValues: false` | 默认只认带本 release 标签的 ServiceMonitor；改成"集群里的都认"，示例应用的 ServiceMonitor 才会生效 |
| `storageSpec` | 数据存在 20Gi 的 gp3 EBS 卷上（第 07 章），Pod 重建不丢 |

```bash
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 93.4.0 \
  -n monitoring -f manifests/ch10-monitoring/kube-prometheus-stack-values.yaml --wait --timeout 10m
kubectl -n monitoring get pods -o wide
```

8 个 Pod 全部 Running：alertmanager、grafana、kube-state-metrics、operator、prometheus，加上每个节点一个 node-exporter（用宿主机网络，IP 是节点 IP）。

### 步骤 5：Loki + Alloy

[`loki-values.yaml`](../manifests/ch10-monitoring/loki-values.yaml)：单体模式（一个 Pod 干所有活），日志存在 10Gi 的 EBS 卷上，保留 7 天，关掉缓存和自测组件。

[`alloy-values.yaml`](../manifests/ch10-monitoring/alloy-values.yaml)：每个节点一个 Alloy（包括 control plane），读 `/var/log/pods` 下的容器日志，打上 `namespace`、`pod`、`container`、`app`、`node` 标签，推给 Loki。

```bash
helm upgrade --install loki grafana/loki --version 7.6.0 \
  -n monitoring -f manifests/ch10-monitoring/loki-values.yaml --wait --timeout 10m
helm upgrade --install alloy grafana/alloy --version 1.16.0 \
  -n monitoring -f manifests/ch10-monitoring/alloy-values.yaml --wait
kubectl -n monitoring get pods | grep -E 'loki|alloy'
```

```
alloy-bd5wx                     2/2     Running
alloy-mkvss                     2/2     Running
alloy-vmmw5                     2/2     Running
loki-0                          2/2     Running
loki-gateway-75fdc66c6f-4fpc5   1/1     Running
```

### 步骤 6：让 Prometheus 也抓示例应用

api 的 `/metrics` 里有请求数、耗时等指标。[`app-servicemonitor.yaml`](../manifests/ch10-monitoring/app-servicemonitor.yaml) 告诉 Prometheus 去抓它：

```bash
kubectl apply -f manifests/ch10-monitoring/app-servicemonitor.yaml
```

### 步骤 7：检查 Prometheus 的抓取目标

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 &
curl -s localhost:19090/api/v1/targets?state=active \
  | jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.health)"' | sort | uniq -c
```

```
   2 api	up
   1 apiserver	up
   2 coredns	up
   1 kube-controller-manager	up
   1 kube-etcd	up
   2 kube-prometheus-stack-alertmanager	up
   1 kube-prometheus-stack-grafana	up
   1 kube-prometheus-stack-operator	up
   2 kube-prometheus-stack-prometheus	up
   3 kube-proxy	up
   1 kube-scheduler	up
   1 kube-state-metrics	up
   9 kubelet	up
   3 node-exporter	up
```

- 全部 `up`。api 刚加上时会先显示 `unknown`，等一个抓取周期（30 秒）就好。
- 扩成 3 个 control plane 后（第 06 章），etcd、controller-manager、scheduler、apiserver 会各变成 3 个。
- 浏览器打开 `http://localhost:19090` → Status → Target health 能看到同样的列表。

当前的告警（Alerts 页面）应该只有一条 **Watchdog**：它是"心跳"，本来就应该一直在 firing，用来证明告警链路是通的。

```bash
kill %1
```

### 步骤 8：Grafana

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 13000:80
```

浏览器打开 `http://localhost:13000`，用户名 `admin`，密码：

```bash
cat secrets/grafana-admin-password      # 在另一个终端看
```

随便点几个：

- **Dashboards → Kubernetes / Compute Resources / Cluster**：整个集群的 CPU / 内存
- **Dashboards → etcd**、**Kubernetes / Controller Manager**、**Kubernetes / Scheduler**：控制面组件
- **Dashboards → Node Exporter / Nodes**：每台机器的 CPU、内存、磁盘、网络
- **Explore → 数据源选 Loki** → 查询 `{namespace="app", app="api"}`：示例应用的日志（JSON 格式，每个请求一行）

---

## ✅ 验收

- [ ] `kubectl top nodes` 有数据（没有用 `--kubelet-insecure-tls`）
- [ ] Prometheus 的 target 全部 `up`，包括 `kube-etcd`、`kube-controller-manager`、`kube-scheduler`、每个节点的 `kube-proxy`、`api`
- [ ] 告警只有 Watchdog
- [ ] Grafana 能登录，Prometheus、Loki 两个数据源都能用
- [ ] Loki 里能查到 `{namespace="app"}` 的日志

---

## 🧹 收工

```bash
./scripts/lab-down.sh
git add -A
git commit -m "ch10: 监控与日志"
```

Prometheus（20Gi）和 Loki（10Gi）的 EBS 卷关机后还在，约 $2.4/月。下次开机，之前的指标和日志都还在（7 天内的）。

---

## 🧯 出问题时

| 现象 | 可能的原因 | 怎么查 |
|---|---|---|
| `kubectl top` 报 `Metrics API not available` | metrics-server 还没就绪，或连不上 kubelet | `kubectl -n kube-system logs deploy/metrics-server`；看到 `x509` 说明有节点的 serving 证书没批准（第 05 章步骤 4） |
| `kube-etcd` / `kube-controller-manager` / `kube-scheduler` 是 down，`context deadline exceeded` | 安全组没放行 | 步骤 2 的 terraform apply 有没有做 |
| 同上，但是 `connection refused` | 组件只监听 127.0.0.1 | 第 03 章 kubeadm 配置里的 `bind-address` / `listen-metrics-urls` |
| `kube-proxy` 是 down | 10249 只监听 127.0.0.1，或安全组 | `kubectl -n kube-system get cm kube-proxy -o yaml \| grep metricsBindAddress` |
| `api` 的 target 不出现 | ServiceMonitor 没被选中 | values 里的 `serviceMonitorSelectorNilUsesHelmValues: false` 是否生效：`helm get values kube-prometheus-stack -n monitoring` |
| prometheus / loki 的 Pod 一直 Pending | PVC 建不出来 | `kubectl -n monitoring get pvc`；第 07 章排障表 |
| Loki 里查不到日志 | Alloy 没在发 | `kubectl -n monitoring logs ds/alloy -c alloy --tail=20`；端口转发 `svc/alloy 12345` 后打开 `http://localhost:12345` 看组件图 |
| Grafana 登录不了 | 密码不对 | `kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' \| base64 -d` |

---

## 📖 学习篇第 19 章（可观测性实战）会深入

- `/metrics` 长什么样：counter、gauge、histogram；PromQL 入门（`rate`、`sum by`、`histogram_quantile`）
- ServiceMonitor → Prometheus 配置 → target：operator 在中间做了什么
- 告警：一条规则从 pending 到 firing，再到 Alertmanager
- LogQL：从 JSON 日志里按字段过滤，统计每分钟的错误数
- 演练：把 api 弄出 5xx，从告警 → dashboard → 日志一路定位
