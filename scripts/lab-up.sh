#!/usr/bin/env bash
# ------------------------------------------------------------
# 开工：按正确顺序启动整套实验环境。
#   用法：./scripts/lab-up.sh
#
# 顺序很重要：
#   1. 先启动 NAT。私有子网里的节点要靠它上网，SSM agent 也要经它连到 AWS。
#      NAT 没起来就启动节点，节点上的 SSM agent 会进入退避重试，要过好几分钟才能登录。
#   2. control plane 和 worker 一起启动。etcd 需要多数派成员在线（3 个里至少 2 个），
#      所以 control plane 永远一起开、一起关。
#   3. 等到所有节点在 SSM 上显示 Online，才算可以开始干活了。
# ------------------------------------------------------------
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
require aws

# 启动一组实例：处于 stopping 状态的先等它停稳，已经在运行的跳过
start_instances() {
  local ids="$1" stopping running_or_pending to_start
  [ -n "$ids" ] || return 0

  stopping=$(aws ec2 describe-instances --instance-ids $ids \
    --filters "Name=instance-state-name,Values=stopping" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  if [ -n "$stopping" ]; then
    log "   有实例还在 stopping，先等它们完全停止..."
    aws ec2 wait instance-stopped --instance-ids $stopping
  fi

  to_start=$(aws ec2 describe-instances --instance-ids $ids \
    --filters "Name=instance-state-name,Values=stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  if [ -n "$to_start" ]; then
    aws ec2 start-instances --instance-ids $to_start >/dev/null
  fi
  aws ec2 wait instance-running --instance-ids $ids
}

ALL_STATES="pending,running,stopping,stopped"

# ---------- 1. NAT ----------
nat=$(instance_id_by_name nat "$ALL_STATES")
[ -n "$nat" ] || die "找不到 NAT 实例。是不是还没有 terraform apply？"

log "1/3 启动 NAT 实例 ${nat}"
start_instances "$nat"
log "   等待 NAT 通过状态检查（通常 1~3 分钟）..."
aws ec2 wait instance-status-ok --instance-ids "$nat"
ok "NAT 就绪"

# ---------- 2. 节点 ----------
nodes=$(instance_ids_by_role "control-plane,worker" "$ALL_STATES")
if [ -z "$nodes" ]; then
  warn "没有找到 K8s 节点，只启动了 NAT"
  exit 0
fi

log "2/3 启动 control plane + worker：$(echo $nodes | wc -w | tr -d ' ') 台"
start_instances "$nodes"
ok "节点已进入 running"

# ---------- 3. 等 SSM 上线 ----------
log "3/3 等待所有实例在 SSM 上显示 Online（最多 6 分钟）..."
want=$(echo "$nat $nodes" | wc -w | tr -d ' ')
for i in $(seq 1 36); do
  online=$(ssm_online_ids)
  n=0
  for id in $nat $nodes; do
    case " $online " in *" $id "*) n=$((n + 1)) ;; esac
  done
  printf '\r   Online: %s/%s ' "$n" "$want"
  if [ "$n" -eq "$want" ]; then
    echo
    ok "全部就绪"
    break
  fi
  if [ "$i" -eq 36 ]; then
    echo
    warn "等了 6 分钟仍有实例不在线，可以稍后用 ./scripts/status.sh 再看看"
  fi
  sleep 10
done

echo
"$(dirname "$0")/status.sh"
echo
log "下一步：./scripts/ssm.sh cp-1   登录 control plane"
