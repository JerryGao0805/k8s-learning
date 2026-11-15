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

# 查看 NLB 目标健康状态
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

## kubectl

（第 03 章起补充）
