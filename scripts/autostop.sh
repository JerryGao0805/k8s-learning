#!/usr/bin/env bash
# ------------------------------------------------------------
# 每晚自动关机的开关。
#   用法：./scripts/autostop.sh status   # 查看
#         ./scripts/autostop.sh off      # 今晚别关（比如要通宵做集群升级）
#         ./scripts/autostop.sh on       # 恢复（做完记得打开！）
# ------------------------------------------------------------
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
require aws

cmd="${1:-status}"
case "$cmd" in
  on|off)
    aws ssm put-parameter --name "$AUTOSTOP_PARAM" --value "$cmd" --overwrite >/dev/null
    ok "自动关机开关已设为：$cmd"
    ;;
  status)
    switch=$(aws ssm get-parameter --name "$AUTOSTOP_PARAM" --query 'Parameter.Value' --output text)
    aws scheduler get-schedule --name "$AUTOSTOP_SCHEDULE" \
      --query '{Schedule: ScheduleExpression, TimeZone: ScheduleExpressionTimezone, State: State}' \
      --output table
    log "开关：${switch}（只有定时任务 State=ENABLED 且开关为 on 时才会关机）"
    ;;
  *)
    die "用法：$0 on|off|status"
    ;;
esac
