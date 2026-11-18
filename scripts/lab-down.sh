#!/usr/bin/env bash
# ------------------------------------------------------------
# 收工：stop 本项目的所有实例（NAT + 全部 K8s 节点）。
#   用法：./scripts/lab-down.sh            # stop 并等待全部停稳
#         ./scripts/lab-down.sh --no-wait  # 发出 stop 指令后立刻返回
#
# stop ≠ terminate：
#   - stop 之后不再收实例的小时费，但 EBS 磁盘还在（按 GB 计费），数据和集群状态都保留
#   - 私网 IP、主机名不变，所以 lab-up.sh 之后集群会自己恢复
#   - Route53 私有区、负载均衡（LB 限制解除后）这类资源不受影响，会继续计费（见 README 的费用说明）
# ------------------------------------------------------------
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
require aws

wait_flag=1
[ "${1:-}" = "--no-wait" ] && wait_flag=0

ids=$(instance_ids_by_role "control-plane,worker,nat" "pending,running")
if [ -z "$ids" ]; then
  ok "没有正在运行的实例，什么都不用做"
  exit 0
fi

log "stop $(echo $ids | wc -w | tr -d ' ') 台实例：$ids"
aws ec2 stop-instances --instance-ids $ids >/dev/null

if [ "$wait_flag" -eq 1 ]; then
  log "等待全部进入 stopped（通常不到 1 分钟）..."
  aws ec2 wait instance-stopped --instance-ids $ids
  ok "已全部停止。下次开工：./scripts/lab-up.sh"
else
  ok "已发出 stop 指令"
fi
