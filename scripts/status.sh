#!/usr/bin/env bash
# 查看本项目所有实例的状态、IP、SSM 是否在线、自动关机开关。
#   用法：./scripts/status.sh
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
require aws

log "EC2 实例（Project=${PROJECT}）"
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=${PROJECT}" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'sort_by(Reservations[].Instances[], &PrivateIpAddress)[].{
      Node: Tags[?Key==`NodeName`]|[0].Value,
      Role: Tags[?Key==`Role`]|[0].Value,
      State: State.Name,
      PrivateIP: PrivateIpAddress,
      PublicIP: PublicIpAddress,
      AZ: Placement.AvailabilityZone,
      Type: InstanceType,
      Id: InstanceId}' \
  --output table

log "SSM 在线状态（Online 才能用 ssm.sh 登录）"
aws ssm describe-instance-information \
  --filters "Key=tag:Project,Values=${PROJECT}" \
  --query 'InstanceInformationList[].{Id: InstanceId, Ping: PingStatus, Agent: AgentVersion, IP: IPAddress}' \
  --output table 2>/dev/null || warn "查询 SSM 失败"

switch=$(aws ssm get-parameter --name "$AUTOSTOP_PARAM" --query 'Parameter.Value' --output text 2>/dev/null || echo "未创建")
log "每晚自动关机开关：${switch}（切换：./scripts/autostop.sh on|off）"
