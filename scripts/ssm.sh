#!/usr/bin/env bash
# ------------------------------------------------------------
# 按名字登录节点（经 SSM Session Manager，不需要 SSH）。
#   用法：./scripts/ssm.sh cp-1
#         ./scripts/ssm.sh worker-2
#         ./scripts/ssm.sh nat
#
# 登录后你是 ssm-user（有 sudo 权限）。需要 root 时用 sudo -i。
# 退出：输入 exit，或者按 Ctrl-D。
# ------------------------------------------------------------
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
require aws session-manager-plugin

name="${1:-}"
[ -n "$name" ] || die "用法：$0 <节点名>，例如 $0 cp-1（节点名可以用 ./scripts/status.sh 查看）"

id=$(instance_id_by_name "$name")
[ -n "$id" ] || die "找不到正在运行的 ${name}。先用 ./scripts/status.sh 看看，或者 ./scripts/lab-up.sh 开机"

log "登录 ${name} (${id}) ..."
exec aws ssm start-session --target "$id" --document-name "$SSM_SHELL_DOC"
