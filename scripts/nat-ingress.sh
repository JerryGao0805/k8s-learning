#!/usr/bin/env bash
# ------------------------------------------------------------
# 在 NAT 实例上配置公网入口的 DNAT 规则（第 09 章）。
#   用法：./scripts/nat-ingress.sh        # 配置 / 更新（worker 增减后重跑一次，比如第 06 章扩容后）
#         ./scripts/nat-ingress.sh off    # 删除规则
#
# 规则的意思：
#   从公网进来、目的地是 NAT 实例自己的 80 / 443  →  轮流转给每台 worker 的 30080 / 30443（Envoy Gateway 的 NodePort）
#
# worker 列表从 terraform output 读，所以永远和 Terraform 里的节点一致。
# 规则放在单独的链 LAB-INGRESS 里，每次先清空再重建，可以重复执行；
# 最后用 netfilter-persistent 保存，NAT 实例重启后规则还在。
# ------------------------------------------------------------
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
require terraform jq aws

mode="${1:-on}"
[ "$mode" = "on" ] || [ "$mode" = "off" ] || die "用法：$0 [off]"

workers=$(terraform -chdir="$TF_DIR" output -json nodes \
  | jq -r '[to_entries[] | select(.value.role == "worker") | .value.private_ip] | sort | join(" ")')
[ -n "$workers" ] || die "terraform output 里没有 worker"
log "worker：${workers}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ---------- 在 NAT 实例上执行的脚本 ----------
cat > "$tmp/nat-ingress-rules.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
MODE="__MODE__"
WORKERS="__WORKERS__"

# 入口规则：只匹配"目的地址是本机"（addrtype LOCAL）的 80/443。
# 这一条很关键：节点经 NAT 上网时，访问外部网站 443 的包也会从这块网卡进来，
# 但它们的目的地址是外部网站，不是本机，所以不会被误转给 worker。
JUMP=(PREROUTING -p tcp -m multiport --dports 80,443 -m addrtype --dst-type LOCAL -j LAB-INGRESS)

if [ "$MODE" = "off" ]; then
  iptables -t nat -D "${JUMP[@]}" 2>/dev/null || true
  iptables -t nat -F LAB-INGRESS 2>/dev/null || true
  iptables -t nat -X LAB-INGRESS 2>/dev/null || true
  netfilter-persistent save >/dev/null 2>&1
  echo "已删除 LAB-INGRESS"
  exit 0
fi

iptables -t nat -N LAB-INGRESS 2>/dev/null || iptables -t nat -F LAB-INGRESS
iptables -t nat -C "${JUMP[@]}" 2>/dev/null || iptables -t nat -A "${JUMP[@]}"

# 轮流分配：n 台 worker 时，第 1 条规则每 n 个新连接取 1 个，第 2 条每 n-1 个取 1 个……最后一条兜底。
# （nat 表只看每个连接的第一个包，同一个连接后续的包由 conntrack 记着，一直去同一台 worker）
set -- $WORKERS
n=$#
i=0
for ip in "$@"; do
  left=$((n - i))
  for pair in 80:30080 443:30443; do
    if [ "$left" -gt 1 ]; then
      iptables -t nat -A LAB-INGRESS -p tcp --dport "${pair%:*}" \
        -m statistic --mode nth --every "$left" --packet 0 -j DNAT --to-destination "${ip}:${pair#*:}"
    else
      iptables -t nat -A LAB-INGRESS -p tcp --dport "${pair%:*}" -j DNAT --to-destination "${ip}:${pair#*:}"
    fi
  done
  i=$((i + 1))
done

netfilter-persistent save >/dev/null 2>&1
iptables -t nat -S PREROUTING | grep LAB-INGRESS
iptables -t nat -S LAB-INGRESS
EOF
sed -i '' -e "s/__MODE__/${mode}/" -e "s/__WORKERS__/${workers}/" "$tmp/nat-ingress-rules.sh"

"$(dirname "$0")/run-on-nodes.sh" "$tmp/nat-ingress-rules.sh" nat
