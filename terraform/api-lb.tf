# ============================================================
# kube-apiserver 的统一入口：内网 NLB + 固定域名 api.k8s.internal
#
#   kubelet / kubectl / kube-proxy ──► api.k8s.internal:6443
#                                       │  (Route53 私有托管区，只有 VPC 内能解析)
#                                       ▼
#                                  内网 NLB :6443
#                                 ┌─────┼─────┐
#                               cp-1  cp-2  cp-3   ← 只有健康的才会收到流量
#
# 为什么只有 1 个 control plane 的时候就要建 NLB？
#   kubeadm init 时写的 controlPlaneEndpoint 会被写进证书和每个节点的 kubeconfig。
#   如果一开始写的是 cp-1 的 IP，以后扩成 3 个 control plane 时就得重签证书、改所有节点。
#   一开始就写一个"稳定的名字"，后面加 control plane 只需要往 NLB 里加目标。
# ============================================================

resource "aws_lb" "api" {
  name               = "${var.cluster_name}-api"
  load_balancer_type = "network"
  internal           = true # 内网 NLB，只有 VPC 里能访问
  subnets            = aws_subnet.private[*].id

  # NLB 的安全组只能在创建时绑定，之后加不上，所以一开始就绑。
  security_groups = [aws_security_group.api_lb.id]

  # 跨可用区负载均衡：关掉的话，没有健康目标的 AZ 会从 DNS 里摘掉。
  # 现在只有 1 个 control plane（只在 AZ a），必须打开。
  enable_cross_zone_load_balancing = true

  tags = { Name = "${var.cluster_name}-api" }
}

resource "aws_lb_target_group" "api" {
  name        = "${var.cluster_name}-api"
  port        = 6443
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  # ★ 关键设置：不保留客户端源 IP。
  # 如果保留，cp-1 通过 NLB 访问 apiserver、而 NLB 又恰好把请求转回 cp-1 时，
  # cp-1 会收到"源 IP 是自己"的包，回包不走 NLB，连接直接失败（hairpin 问题）。
  # 只有 1 个 control plane 时，这种情况每次都会发生。
  preserve_client_ip = "false"

  # 健康检查：用 HTTPS 访问 /readyz，而不是只检查 TCP 端口通不通。
  # apiserver 进程活着但 etcd 挂了时，TCP 能连上，/readyz 却会返回非 200。
  # （/readyz 默认允许匿名访问，所以 NLB 不用带证书。）
  health_check {
    protocol            = "HTTPS"
    path                = "/readyz"
    port                = "traffic-port"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  deregistration_delay = 30

  tags = { Name = "${var.cluster_name}-api" }
}

resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.api.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# 把每个 control plane 节点注册为 NLB 的目标。cp_count 从 1 改成 3 时会自动加上新节点。
resource "aws_lb_target_group_attachment" "api" {
  for_each = aws_instance.control_plane

  target_group_arn = aws_lb_target_group.api.arn
  target_id        = each.value.id
  port             = 6443
}

# ---------- Route53 私有托管区 ----------
# k8s.internal 这个域名只在我们的 VPC 里能解析，公网查不到。
resource "aws_route53_zone" "internal" {
  name = "k8s.internal"

  vpc {
    vpc_id = aws_vpc.main.id
  }

  tags = { Name = "${var.cluster_name}-internal-zone" }
}

# api.k8s.internal → NLB（alias 记录：类似 CNAME，但在 Route53 内部直接解析成 NLB 的 IP）
resource "aws_route53_record" "api" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "api.k8s.internal"
  type    = "A"

  alias {
    name                   = aws_lb.api.dns_name
    zone_id                = aws_lb.api.zone_id
    evaluate_target_health = false
  }
}
