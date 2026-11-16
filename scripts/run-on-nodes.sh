#!/usr/bin/env bash
# ------------------------------------------------------------
# 用 SSM Run Command，把 Mac 上的一个脚本推到一台或多台节点上，以 root 身份执行，然后打印每台的结果。
#   用法：./scripts/run-on-nodes.sh <脚本> <节点名>...
#   例子：./scripts/run-on-nodes.sh scripts/node/prepare-node.sh worker-1 worker-2
#         ./scripts/run-on-nodes.sh scripts/node/check-node.sh cp-1 worker-1 worker-2
#
# 和 ssm.sh 的区别：
#   ssm.sh          = Session Manager：开一个交互式终端，人坐在前面一条条敲
#   run-on-nodes.sh = Run Command：把一段脚本"投递"给多台机器，各自执行完把结果交回来，不需要人盯着
#
# 注意：
#   - 脚本在节点上以 root 身份运行（不是登录时的 ssm-user）。
#   - AWS 只返回 stdout 的前 24000 个字符、stderr 的前 8000 个字符。节点脚本要少打印，详细日志写到节点本地文件。
#   - 每次执行都有记录：AWS 控制台 → Systems Manager → Run Command → Command history。
# ------------------------------------------------------------
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
require aws jq

TIMEOUT_SECONDS=1200   # 最多等 20 分钟

[ $# -ge 2 ] || die "用法：$0 <脚本> <节点名>...，例如：$0 scripts/node/check-node.sh cp-1 worker-1 worker-2"
script=$1
shift
[ -f "$script" ] || die "找不到脚本：${script}"
head -n 1 "$script" | grep -q '^#!' \
  || die "${script} 的第一行必须是 #!/usr/bin/env bash（SSM 靠它决定用 bash 执行）"

# ---------- 节点名 → 实例 ID，并确认 SSM agent 在线 ----------
names=()
ids=()
for name in "$@"; do
  id=$(instance_id_by_name "$name")
  [ -n "$id" ] || die "找不到正在运行的 ${name}。先用 ./scripts/status.sh 看看，或者 ./scripts/lab-up.sh 开机"
  ping=$(aws ssm describe-instance-information \
           --filters "Key=InstanceIds,Values=${id}" \
           --query 'InstanceInformationList[0].PingStatus' --output text)
  [ "$ping" = "Online" ] || die "${name} (${id}) 的 SSM agent 不在线（${ping}）。刚开机的话等 1~2 分钟再试"
  names+=("$name")
  ids+=("$id")
done

# ---------- 发送命令 ----------
# 把整个脚本原样作为 commands 里的一个元素（jq -Rs：把整个文件读成一个 JSON 字符串）。
params=$(mktemp)
trap 'rm -f "$params"' EXIT
jq -Rs '{commands: [.], executionTimeout: ["1800"]}' "$script" >"$params"

log "把 $(basename "$script") 推到：$*"
cmd_id=$(aws ssm send-command \
  --document-name AWS-RunShellScript \
  --instance-ids "${ids[@]}" \
  --comment "k8s-learning: $(basename "$script")" \
  --parameters "file://${params}" \
  --query 'Command.CommandId' --output text)
log "CommandId = ${cmd_id}（控制台 Run Command 的 Command history 里能看到）"

# ---------- 逐台等待结果 ----------
deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
failed=0
i=0
while [ "$i" -lt "${#ids[@]}" ]; do
  name=${names[$i]}
  id=${ids[$i]}
  i=$((i + 1))

  last=""
  while :; do
    sleep 3
    # 刚发出命令时，调用记录可能还没生成（InvocationDoesNotExist），稍等重试即可
    if ! inv=$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$id" --output json 2>&1); then
      echo "$inv" | grep -q InvocationDoesNotExist || die "查询 ${name} 的执行结果失败：${inv}"
      status="Pending"
    else
      status=$(echo "$inv" | jq -r '.Status')
    fi

    case "$status" in
      Success|Failed|Cancelled|TimedOut) break ;;
    esac
    if [ "$status" != "$last" ]; then
      log "${name}：${status} ..."
      last=$status
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      warn "${name}：等了 ${TIMEOUT_SECONDS} 秒还没结束（${status}）。去控制台的 Command history 看看"
      status="(等待超时)"
      inv=""
      break
    fi
  done

  echo
  if [ "$status" = "Success" ]; then
    ok "${name} (${id})：Success"
  else
    code=$( [ -n "$inv" ] && echo "$inv" | jq -r '.ResponseCode' || echo "?" )
    printf '\033[1;31m ✘\033[0m %s (%s)：%s（退出码 %s）\n' "$name" "$id" "$status" "$code"
    failed=$((failed + 1))
  fi
  if [ -n "$inv" ]; then
    echo "$inv" | jq -r '.StandardOutputContent' | sed 's/^/    /'
    if [ "$status" != "Success" ]; then
      echo "    ---- stderr ----"
      echo "$inv" | jq -r '.StandardErrorContent' | sed 's/^/    /'
    fi
  fi
done

echo
if [ "$failed" -eq 0 ]; then
  ok "全部 ${#ids[@]} 台执行成功"
else
  die "${failed} 台执行失败（见上面的输出）"
fi
