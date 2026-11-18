# 第 07 章 · 存储：让 Pod 用上 EBS 卷

> 📍 **搭建篇**：只管把东西装好、确认能用。原理留到学习篇（这一章对应 **第 16 章 · 存储原理**）。

## 🎯 做完是什么样

- 集群里有一个默认的 StorageClass `gp3`
- 建一个 PVC，AWS 里就自动多出一块加密的 gp3 EBS 卷，并挂进 Pod；删掉 PVC，卷也自动删掉
- 第 08 章的 Postgres、第 10 章的 Prometheus / Loki 都靠它存数据

大约 **30 分钟**，全程在 **Mac** 上操作。

## 🗺 在整体里的位置

到现在为止，Pod 里写的文件都在节点的系统盘上，Pod 一删就没了。数据库要的是"Pod 换了、换节点了，数据还在"的盘。这一章装上 AWS 的 **EBS CSI 驱动**，让 K8s 能按需向 AWS 要 EBS 卷。顺便第一次用 **Helm**。

## 🧩 新名词

| 词 | 一句话 |
|---|---|
| **PVC** | PersistentVolumeClaim，Pod 的"要盘申请单"：我要 1Gi、只给一个节点读写 |
| **PV** | PersistentVolume，真正分配出来的那块盘在 K8s 里的记录（这里对应一块 EBS 卷） |
| **StorageClass** | "盘的规格模板"：用哪个驱动、什么类型（gp3）、加不加密、删 PVC 时删不删盘 |
| **CSI 驱动** | 存储厂商写的插件。K8s 只说"要一块盘"，具体怎么调 AWS API 由它来做 |
| **Helm** | K8s 的"软件包管理器"：一个 chart = 一堆 YAML 模板，安装时用 values 文件填参数 |

---

## 🛠 步骤

### 步骤 1：开工

💻 **Mac：**

```bash
cd ~/Desktop/code/K8s-learning
./scripts/lab-up.sh                     # 如果机器是停着的
./scripts/api-tunnel.sh                 # 这个窗口保持开着
```

**另开一个终端**（本章后面的命令都在这里敲）：

```bash
cd ~/Desktop/code/K8s-learning
export KUBECONFIG=~/.kube/k8s-lab.yaml
kubectl get nodes                       # 3 个 Ready
```

### 步骤 2：添加 Helm 仓库

```bash
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update aws-ebs-csi-driver
helm search repo aws-ebs-csi-driver/aws-ebs-csi-driver --versions | head -3
```

```
NAME                                 	CHART VERSION	APP VERSION
aws-ebs-csi-driver/aws-ebs-csi-driver	2.68.1       	1.68.1
```

### 步骤 3：看一眼 values 文件

[`manifests/ch07-storage/ebs-csi-values.yaml`](../manifests/ch07-storage/ebs-csi-values.yaml) 里只写了和默认值不同的地方：

| 设置 | 为什么 |
|---|---|
| `controller.nodeSelector` / `tolerations` → control plane | controller 要调 AWS API 建卷。只有 control plane 的 IAM 角色带了 EBS 权限（`terraform/iam.tf`），而且只有 control plane 的 IMDS hop limit 是 2，Pod 里才拿得到这个角色的凭证 |
| `controller.k8sTagClusterId` / `extraVolumeTags` | 给每块卷打上 `KubernetesCluster=k8s-lab`、`Project=k8s-learning` 标签，方便认出来和清理 |
| `node.hostNetwork: true` | node 插件要从 IMDS 读"我是哪台机器、在哪个可用区"。worker 的 hop limit 是 1，只有宿主机网络能访问 IMDS |
| `storageClasses` | 建一个默认的 `gp3`：等 Pod 调度好再建卷（`WaitForFirstConsumer`）、加密、删 PVC 时删卷、允许扩容 |

📖 第 16 章：IMDS hop limit 是什么，为什么"Pod 里拿不到节点凭证"是一种安全设计。

### 步骤 4：安装

```bash
helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --version 2.68.1 -n kube-system \
  -f manifests/ch07-storage/ebs-csi-values.yaml --wait --timeout 5m
```

- `upgrade --install`：没装过就装，装过就按新 values 升级。以后改了 values 再跑一遍同一条命令就行。
- 输出最后会有几段 NOTES（关于 IAM 策略和 FIPS 镜像的公告），和我们无关。

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-ebs-csi-driver -o wide
kubectl get storageclass
```

```
NAME                                  READY   STATUS    NODE
ebs-csi-controller-5c5c6b6c59-hwvlg   5/5     Running   ip-10-0-10-11
ebs-csi-controller-5c5c6b6c59-nkbtp   5/5     Running   ip-10-0-10-11
ebs-csi-node-g2frf                    3/3     Running   ip-10-0-10-11
ebs-csi-node-xgj9h                    3/3     Running   ip-10-0-11-21
ebs-csi-node-zfdjf                    3/3     Running   ip-10-0-10-21

NAME            PROVISIONER       RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
gp3 (default)   ebs.csi.aws.com   Delete          WaitForFirstConsumer   true
```

controller 两个副本都在 control plane 上；node 插件每个节点一个。

### 步骤 5：测试：建一个 PVC，让 Pod 往里写文件

[`manifests/ch07-storage/pvc-test.yaml`](../manifests/ch07-storage/pvc-test.yaml)：一个 1Gi 的 PVC，加一个启动时往 `/data/hello.txt` 写一行时间的 busybox。

```bash
kubectl apply -f manifests/ch07-storage/pvc-test.yaml
kubectl get pvc ebs-test                 # 先是 Pending：在等 Pod 调度（WaitForFirstConsumer）
kubectl wait --for=condition=Ready pod/ebs-test --timeout=180s
kubectl get pvc,pv
kubectl exec ebs-test -- sh -c 'df -h /data; cat /data/hello.txt'
```

```
NAME                             STATUS   VOLUME                                     CAPACITY   STORAGECLASS
persistentvolumeclaim/ebs-test   Bound    pvc-7b990c34-2c40-4443-9d23-ed124594a593   1Gi        gp3

Filesystem                Size      Used Available Use% Mounted on
/dev/nvme1n1            973.4M     28.0K    957.4M   0% /data
Wed Nov 18 21:38:54 UTC 2026
```

到 AWS 里看这块卷：

```bash
V=$(kubectl get pv $(kubectl get pvc ebs-test -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.csi.volumeHandle}')
aws ec2 describe-volumes --volume-ids $V \
  --query 'Volumes[0].{Id:VolumeId,Size:Size,Type:VolumeType,AZ:AvailabilityZone,Enc:Encrypted,State:State}'
```

`gp3`、`Enc: true`、`State: in-use`，可用区和 Pod 所在节点相同。

### 步骤 6：删掉，确认卷也跟着删了

```bash
kubectl delete -f manifests/ch07-storage/pvc-test.yaml
kubectl get pv                           # 先是 Released，约 1~2 分钟后消失
```

卷要先从节点上卸下来（detach）才能删，所以要等一两分钟。之后：

```bash
./scripts/cleanup-orphans.sh
```

```
 ✔ 没有 CSI 创建的 EBS 卷
```

`cleanup-orphans.sh` 列出所有带 `KubernetesCluster=k8s-lab` 标签的卷。**以后 `terraform destroy` 之前一定先跑一遍**：Terraform 不知道这些卷的存在，集群拆了它们还会留在账号里收钱。加 `--delete` 删除其中未挂载的卷。

---

## ✅ 验收

- [ ] `kubectl get storageclass`：`gp3 (default)`
- [ ] ebs-csi-controller 2 个副本在 control plane 上，ebs-csi-node 每个节点一个，全部 Running
- [ ] 测试 PVC 变成 `Bound`，Pod 里能写文件
- [ ] 删除 PVC 后，`cleanup-orphans.sh` 显示没有遗留的卷

---

## 🧹 收工

关掉隧道窗口（Ctrl-C），然后：

```bash
./scripts/lab-down.sh
git add -A
git commit -m "ch07: 存储（EBS CSI）"
```

**下一章**：第 08 章，把示例应用（前端 + API + Postgres + Redis）部署上来。

---

## 🧯 出问题时

| 现象 | 可能的原因 | 怎么查 |
|---|---|---|
| PVC 一直 `Pending`，Pod 也 Pending | 正常情况下 Pod 调度后几秒就会建卷；一直不动说明 controller 有问题 | `kubectl describe pvc ebs-test` 看 Events |
| Events 里有 `UnauthorizedOperation` / `AccessDenied` | controller 拿不到 control plane 的 IAM 权限 | controller 是不是跑在 control plane 上（`-o wide`）；`terraform/iam.tf` 里 control-plane 角色有没有 `AmazonEBSCSIDriverPolicyV2` |
| Events 里有 `no EC2 IMDS role found` 或连不上 `169.254.169.254` | Pod 里访问不到 IMDS | control plane 的 hop limit 要是 2（`terraform/nodes.tf`） |
| ebs-csi-node 一直 CrashLoopBackOff | node 插件读不到 IMDS | values 里 `node.hostNetwork: true` 有没有生效：`kubectl -n kube-system get ds ebs-csi-node -o jsonpath='{.spec.template.spec.hostNetwork}'` |
| Pod 卡在 `ContainerCreating`，Events 里 `FailedAttachVolume` | 卷和节点不在同一个可用区，或节点上挂的卷太多 | `kubectl describe pod`；`aws ec2 describe-volumes --volume-ids <卷>` 看 AZ |
| 删了 PVC，卷一直不消失 | 卷还没从节点卸下来 | `kubectl get volumeattachment`；几分钟后还在，看 controller 日志：`kubectl -n kube-system logs deploy/ebs-csi-controller -c csi-provisioner --tail=20` |

---

## 📖 学习篇第 16 章（存储原理）会深入

- PVC → PV → EBS 卷：provisioner、attacher、node 插件各自在什么时候做什么
- `WaitForFirstConsumer` 为什么重要：EBS 卷只能挂给同一个可用区的机器
- 演练：把 Pod 所在可用区的唯一 worker drain 掉，Pod 会卡在哪里
- `reclaimPolicy: Delete` vs `Retain`、卷扩容、快照
- IMDS hop limit：为什么 worker 上的 Pod 拿不到节点的 AWS 凭证
