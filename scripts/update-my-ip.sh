#!/usr/bin/env bash
# ------------------------------------------------------------
# 查出你当前的公网 IP，写进 terraform/terraform.tfvars 的 my_ip_cidr（第 09 章起使用）。
# 家里的宽带 IP 可能会变；访问公网入口被拒绝时，先跑一下这个脚本，再 terraform apply。
#   用法：./scripts/update-my-ip.sh
# ------------------------------------------------------------
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
require curl

tfvars="${TF_DIR}/terraform.tfvars"
[ -f "$tfvars" ] || die "找不到 ${tfvars}。先 cp terraform/terraform.tfvars.example terraform/terraform.tfvars"

ip=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')
echo "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || die "拿到的 IP 格式不对：'${ip}'"
cidr="${ip}/32"

if grep -Eq '^[#[:space:]]*my_ip_cidr[[:space:]]*=' "$tfvars"; then
  # macOS 的 sed 要求 -i 后面跟一个（可以为空的）备份后缀
  sed -i '' -E "s|^[#[:space:]]*my_ip_cidr[[:space:]]*=.*|my_ip_cidr = \"${cidr}\"|" "$tfvars"
else
  printf '\nmy_ip_cidr = "%s"\n' "$cidr" >> "$tfvars"
fi

ok "my_ip_cidr = ${cidr} 已写入 ${tfvars}"
log "接下来：cd terraform && terraform apply"
