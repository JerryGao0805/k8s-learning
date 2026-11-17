# 常用命令速查

边学边补充。每一章学到的新命令，都会整理到这里。

---

## 开工 / 收工（在仓库根目录执行）

| 命令 | 作用 |
|---|---|
| `./scripts/lab-up.sh` | 开工：先启动 NAT，再启动全部节点，等待 SSM 上线 |
| `./scripts/lab-down.sh` | 收工：stop 所有实例 |
| `./scripts/status.sh` | 查看实例状态、IP、SSM 是否在线 |
| `./scripts/ssm.sh <节点名>` | 登录节点：`cp-1`、`worker-1`、`nat` ... |
| `./scripts/run-on-nodes.sh <脚本> <节点>...` | 用 SSM Run Command 把脚本推到节点上以 root 执行，例如 `scripts/node/check-node.sh cp-1 worker-1 worker-2` |
| `./scripts/api-tunnel.sh` | 打开 Mac → apiserver 的隧道（第 05 章起使用） |
| `./scripts/autostop.sh status\|on\|off` | 每晚自动关机的开关 |
| `./scripts/update-my-ip.sh` | 把当前公网 IP 写进 tfvars（第 13 章起使用） |

## Terraform（在 `terraform/` 目录执行）

| 命令 | 作用 |
|---|---|
| `terraform init` | 下载 provider 插件（第一次使用，或者改了 provider 版本之后执行） |
| `terraform fmt` | 自动格式化代码 |
| `terraform validate` | 检查语法 |
| `terraform plan` | 预览变更，**apply 之前必须看** |
| `terraform apply` | 执行变更 |
| `terraform output` | 查看输出值；`-raw <名字>` 只输出值本身 |
| `terraform state list` | 列出 Terraform 管理的所有资源 |
| `terraform plan -var cp_count=3` | 临时覆盖变量，只用来预览 |
| `terraform destroy` | 删除全部资源（⚠️ 不可恢复） |

## AWS

```bash
aws sts get-caller-identity                     # 我是谁

# 查看 api.k8s.internal 的 DNS 记录（现在指向 cp-1 的 IP；第 11 章起指向 NLB）
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name k8s.internal \
  --query "HostedZones[?Name=='k8s.internal.'].Id | [0]" --output text)
aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Name=='api.k8s.internal.']" --output table

# 查看 NLB 目标健康状态（第 11 章打开 enable_api_lb 之后）
aws elbv2 describe-target-health \
  --target-group-arn "$(terraform -chdir=terraform output -raw api_target_group_arn)" \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table

# 查看私有子网路由表（NAT 停机时默认路由会显示 blackhole）
aws ec2 describe-route-tables --filters "Name=tag:Name,Values=k8s-lab-private-rt" \
  --query 'RouteTables[].Routes[]' --output table
```

## 节点上的 Linux 网络排障

| 命令 | 作用 |
|---|---|
| `ip -br addr` | 简洁地列出网卡和 IP |
| `ip route` | 路由表 |
| `resolvectl status` | DNS 配置 |
| `dig +short <域名>` | DNS 解析 |
| `nc -vz -w 3 <主机> <端口>` | 测试 TCP 端口通不通 |
| `curl -s https://checkip.amazonaws.com` | 查看自己在公网上显示的 IP |
| `sysctl net.ipv4.ip_forward` | 内核转发开关 |
| `sudo iptables -t nat -S` | 查看 NAT 表的规则 |
| `cloud-init status` | 开机初始化脚本是否执行完毕 |
| `sudo tail -50 /var/log/cloud-init-output.log` | 开机脚本的输出日志 |

## 节点：服务与日志（第 02 章）

| 命令 | 作用 |
|---|---|
| `sudo -i` | 切换成 root shell（`exit` 退回） |
| `systemctl status <服务> --no-pager` | 服务现在的状态（排障第一步） |
| `journalctl -u <服务> -n 50 --no-pager` | 服务最近的日志（排障第二步） |
| `journalctl -u kubelet -f` | 持续跟踪 kubelet 日志 |
| `systemctl cat kubelet` | 查看 kubelet 的启动命令和 drop-in |
| `apt-mark showhold` | 查看被锁定版本的软件包 |
| `chronyc -n sources` / `chronyc tracking` | 时间同步的来源和状态 |

## 节点：容器运行时（第 02 章）

| 命令 | 作用 |
|---|---|
| `sudo crictl ps -a` | 经 CRI 列出容器（K8s 视角，命名空间 `k8s.io`） |
| `sudo crictl pods` | 列出 Pod sandbox |
| `sudo crictl images` | 列出镜像 |
| `sudo crictl logs <容器ID>` | 看容器日志（apiserver 起不来时很有用） |
| `sudo crictl info` | 运行时状态（RuntimeReady / NetworkReady） |
| `sudo ctr -n k8s.io images ls -q` | 绕过 CRI 直接看 containerd（`-n` 指定 containerd 命名空间） |
| `sudo containerd config dump` | containerd 实际生效的配置 |
| `sudo lsns -p <PID>` | 某个进程所在的 Linux namespace |
| `cat /proc/<PID>/cgroup` | 某个进程所在的 cgroup |

## kubectl（第 03 章起）

> 第 03、04 章在 cp-1 上用（root 已设好 `KUBECONFIG=/etc/kubernetes/admin.conf`，`k` 是 `kubectl` 的缩写）；第 05 章起也可以在 Mac 上用。

| 命令 | 作用 |
|---|---|
| `kubectl get nodes -o wide` | 节点列表，带 IP、系统、容器运行时 |
| `kubectl get pods -A -o wide` | 所有命名空间的 Pod，带 IP 和所在节点 |
| `kubectl -n kube-system get deploy,ds,cm` | 一次查看多种对象 |
| `kubectl describe node <节点>` | 节点详情：Conditions、Taints、资源（排障常用） |
| `kubectl describe pod <Pod> -n <命名空间>` | Pod 详情：Tolerations、Events |
| `kubectl -n <命名空间> logs <Pod> --tail=20` | 看 Pod 日志（要求 kubelet 的服务端证书已批准） |
| `kubectl get events -A --field-selector reason=FailedScheduling` | 调度失败的原因 |
| `kubectl get <对象> -o yaml` / `-o jsonpath='{.spec.podCIDR}'` | 看对象的完整定义 / 取某个字段 |
| `kubectl auth whoami` | 在集群眼里我是谁（用户名、组） |
| `kubectl get csr` | 证书签名请求列表 |
| `kubectl get csr --field-selector spec.signerName=kubernetes.io/kubelet-serving -o name \| xargs kubectl certificate approve` | 批准所有 kubelet 服务端证书申请（先核对内容） |
| `kubectl get --raw='/readyz?verbose'` | apiserver 的各项健康检查 |
| `kubectl -n kube-system get lease` | 谁持有 controller-manager / scheduler 的锁 |

## 控制面（第 03 章，在 cp-1 上以 root 执行）

| 命令 | 作用 |
|---|---|
| `ls /etc/kubernetes/manifests/` | static pod 的定义文件（移走 = 停掉，移回 = 启动；备份别放这里） |
| `find /etc/kubernetes/pki -type f \| sort` | 所有证书和私钥 |
| `openssl x509 -in <证书> -noout -subject -issuer -dates -ext subjectAltName` | 看证书的身份、签发者、有效期、SAN |
| `kubeadm certs check-expiration` | 所有证书的到期时间 |
| `kubeadm token list` | bootstrap token 列表（给新节点加入用） |
| `kubeadm config validate --config <文件>` | 校验 kubeadm 配置文件 |
| `cat /var/lib/kubelet/config.yaml` | kubelet 的配置 |
| `curl -s http://127.0.0.1:10248/healthz` | kubelet 健康检查 |
| `crictl exec $(crictl ps --name etcd -q) etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt --key=/etc/kubernetes/pki/etcd/healthcheck-client.key member list -w table` | 在 etcd 容器里执行 etcdctl（第 03 章步骤 12 有简化用的函数） |
| `kubeadm reset -f` | 撤销 init/join（危险！会删掉证书和控制面） |
