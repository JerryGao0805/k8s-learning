#!/usr/bin/env bash
# ------------------------------------------------------------
# 公共函数，被 scripts/ 下的其他脚本 source 引入，不要直接执行。
# 写法兼容 macOS 自带的 bash 3.2（不用关联数组、mapfile 等 bash 4 特性）。
# ------------------------------------------------------------

PROJECT="${PROJECT:-k8s-learning}"
CLUSTER_NAME="${CLUSTER_NAME:-k8s-lab}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_PAGER=""   # 不让 aws 命令的输出进 less 分页

SSM_SHELL_DOC="${CLUSTER_NAME}-shell"
AUTOSTOP_PARAM="/${PROJECT}/autostop"
AUTOSTOP_SCHEDULE="${CLUSTER_NAME}-nightly-stop"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[警告]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

require() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "缺少命令：$c（安装方法见 docs/00-prerequisites.md）"
  done
}

# 按 NodeName 标签查实例 ID。
#   $1 = 节点名（cp-1 / worker-1 / nat ...）
#   $2 = 状态过滤，逗号分隔（默认 running）
instance_id_by_name() {
  aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=${PROJECT}" \
              "Name=tag:NodeName,Values=$1" \
              "Name=instance-state-name,Values=${2:-running}" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

# 按 Role 标签列出实例 ID（空格分隔）。
#   $1 = control-plane / worker / nat，可以用逗号写多个
#   $2 = 状态过滤
instance_ids_by_role() {
  aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=${PROJECT}" \
              "Name=tag:Role,Values=$1" \
              "Name=instance-state-name,Values=$2" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

# 列出所有已注册到 SSM 且状态为 Online 的本项目实例 ID
# 注意：SSM 的 tag 过滤不能和其他过滤条件（如 PingStatus）写在同一个 --filters 里，
# 否则报 ValidationException: Cannot mix tag or inventory filter with any other filter。
# 所以服务端只按 tag 过滤，Online 交给 --query（JMESPath）在本地筛。
ssm_online_ids() {
  aws ssm describe-instance-information \
    --filters "Key=tag:Project,Values=${PROJECT}" \
    --query "InstanceInformationList[?PingStatus=='Online'].InstanceId" --output text
}
