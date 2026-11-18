#!/usr/bin/env bash
# ------------------------------------------------------------
# 找出（并可选删除）集群通过 EBS CSI 动态创建的 EBS 卷（第 07 章起）。
#   用法：./scripts/cleanup-orphans.sh            # 只列出，不删
#         ./scripts/cleanup-orphans.sh --delete   # 删除其中"未挂载"（available）的卷
#
# 为什么需要它：这些卷是 K8s 里的 PVC 让 CSI 驱动去建的，Terraform 不知道它们的存在。
# 正常情况下删掉 PVC 就会连带删掉卷；但如果先把集群拆了（terraform destroy）、PVC 没删，
# 卷就会留在账号里一直计费。所以 destroy 之前先跑一遍。
#
# 只认 CSI 驱动打的标签 KubernetesCluster=k8s-lab（见 manifests/ch07-storage/ebs-csi-values.yaml），
# 不会碰节点的系统盘，也不会碰账号里其他东西。
# ------------------------------------------------------------
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
require aws

mode="${1:-list}"
[ "$mode" = "list" ] || [ "$mode" = "--delete" ] || die "用法：$0 [--delete]"

vols=$(aws ec2 describe-volumes \
  --filters "Name=tag:KubernetesCluster,Values=${CLUSTER_NAME}" \
  --query 'Volumes[].[VolumeId,State,Size,AvailabilityZone,Tags[?Key==`kubernetes.io/created-for/pvc/namespace`]|[0].Value,Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value]' \
  --output text)

if [ -z "$vols" ]; then
  ok "没有 CSI 创建的 EBS 卷"
  exit 0
fi

printf '%-24s %-10s %5s  %-12s %s\n' "卷 ID" "状态" "GiB" "可用区" "PVC"
echo "$vols" | while read -r id state size az ns pvc; do
  printf '%-24s %-10s %5s  %-12s %s/%s\n' "$id" "$state" "$size" "$az" "$ns" "$pvc"
done

if [ "$mode" = "--delete" ]; then
  echo "$vols" | while read -r id state _; do
    if [ "$state" = "available" ]; then
      aws ec2 delete-volume --volume-id "$id"
      ok "已删除 $id"
    else
      warn "$id 是 ${state}（还挂在节点上），跳过。先在集群里删掉对应的 PVC，或者等节点关机/销毁后再跑一次"
    fi
  done
else
  echo
  log "只是列出。要删除未挂载的卷：$0 --delete"
fi
