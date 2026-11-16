#!/usr/bin/env bash
# ------------------------------------------------------------
# 在 Mac 上开一条到 kube-apiserver 的隧道，让本地 kubectl 能访问集群（第 05 章起使用）。
#   用法：./scripts/api-tunnel.sh                  # 经第一个在线的 control plane
#         ./scripts/api-tunnel.sh worker-1         # 指定经由哪个节点
#         LOCAL_PORT=26443 ./scripts/api-tunnel.sh # 换个本地端口
#
# 原理：
#   Mac:16443 ──(SSM 加密通道)──► 某个节点 ──► api.k8s.internal:6443 ──► apiserver
#   （api.k8s.internal 现在直接解析到 cp-1；第 11 章起解析到内网 NLB）
#
# api.k8s.internal 只在 VPC 里能解析，所以是"由节点帮我们去连"。
# 这个终端窗口要保持打开；按 Ctrl-C 关闭隧道。
# ------------------------------------------------------------
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
require aws session-manager-plugin

LOCAL_PORT="${LOCAL_PORT:-16443}"
API_HOST="api.k8s.internal"

via="${1:-}"
if [ -z "$via" ]; then
  for n in cp-1 cp-2 cp-3; do
    id=$(instance_id_by_name "$n")
    if [ -n "$id" ]; then via="$n"; break; fi
  done
  [ -n "$via" ] || die "没有正在运行的 control plane。先 ./scripts/lab-up.sh"
else
  id=$(instance_id_by_name "$via")
  [ -n "$id" ] || die "找不到正在运行的 ${via}"
fi

if lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  die "本地端口 ${LOCAL_PORT} 已被占用（是不是已经开了一条隧道？）。换个端口：LOCAL_PORT=26443 $0"
fi

log "隧道：127.0.0.1:${LOCAL_PORT} → ${via} (${id}) → ${API_HOST}:6443"
log "保持这个窗口打开，在另一个终端里使用 kubectl。Ctrl-C 关闭。"
exec aws ssm start-session \
  --target "$id" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${API_HOST}\"],\"portNumber\":[\"6443\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}"
