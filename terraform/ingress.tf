# ============================================================
# 公网入口（第 09 章）：让浏览器能访问 https://app.lab.<你的域名>
#
# 原计划是一个公网 NLB。账号暂时不能创建负载均衡（见第 01 章附录），
# 所以先让 NAT 实例兼做入口：
#
#   浏览器 ──► EIP（固定公网 IP）──► NAT 实例 :80/:443
#                                      │ iptables DNAT（scripts/nat-ingress.sh 配置）
#                                      ▼
#                         worker 的 NodePort :30080/:30443 ──► Envoy Gateway
#
#   - 回包：worker → 私有路由表的默认路由 → NAT 实例 → conntrack 自动改回地址 → 浏览器
#   - DNAT 不改源地址，所以 worker 看到的来源是你的公网 IP，安全组要按 my_ip_cidr 放行
#   - 只放行 my_ip_cidr（你自己的 IP），不对整个互联网开放
#
# 以后能创建 LB 了，换成公网 NLB：DNS 记录改指向 NLB，删掉这里的 EIP 和规则即可，集群里不用改。
#
# 关于 EIP：
#   - 绑上 EIP 后，NAT 实例原来那个自动分配的公网 IP 就被释放了。节点访问外网的出口 IP 也随之变成这个 EIP，
#     而且从此固定（stop/start 也不变）。
#   - 绑定那一刻，节点访问外网的连接会断一下，几秒后恢复。
#   - EIP 不管机器开没开都收费：$0.005/小时 ≈ $3.6/月（机器开着时，原来的自动公网 IP 也是这个价）。
# ============================================================

resource "aws_eip" "ingress" {
  count  = var.enable_public_ingress ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.cluster_name}-ingress" }

  lifecycle {
    precondition {
      condition     = var.my_ip_cidr != null
      error_message = "打开 enable_public_ingress 之前，先用 scripts/update-my-ip.sh 填好 my_ip_cidr。"
    }
  }
}

resource "aws_eip_association" "ingress" {
  count         = var.enable_public_ingress ? 1 : 0
  allocation_id = aws_eip.ingress[0].id
  instance_id   = aws_instance.nat.id
}

locals {
  public_ingress_rules = var.enable_public_ingress ? {
    # 浏览器 → NAT 实例
    "nat-http-from-me"  = { sg = local.sg_nat, port = 80, desc = "Public ingress HTTP (DNAT to worker NodePort)" }
    "nat-https-from-me" = { sg = local.sg_nat, port = 443, desc = "Public ingress HTTPS (DNAT to worker NodePort)" }
    # NAT 实例 DNAT 之后 → worker 的 NodePort（源地址仍是你的 IP）
    "worker-30080-from-me" = { sg = local.sg_worker, port = 30080, desc = "Envoy Gateway NodePort HTTP via NAT DNAT" }
    "worker-30443-from-me" = { sg = local.sg_worker, port = 30443, desc = "Envoy Gateway NodePort HTTPS via NAT DNAT" }
  } : {}
}

resource "aws_vpc_security_group_ingress_rule" "public" {
  for_each = local.public_ingress_rules

  security_group_id = each.value.sg
  cidr_ipv4         = var.my_ip_cidr
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  description       = each.value.desc

  tags = { Name = each.key }
}
