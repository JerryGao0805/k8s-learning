# ============================================================
# S3 Gateway Endpoint（免费）
#
# 访问 S3 的流量直接走 AWS 内网，不经过 NAT 实例。
# 为什么重要：ECR 的镜像层实际存放在 S3 上。以后拉大镜像（Prometheus、
# Argo CD……）时，大部分流量会走这里，不会挤占 NAT 实例那点带宽
# （t4g.small 的基准带宽并不高）。
# ============================================================

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"

  # Gateway 类型的 endpoint 通过往路由表里加一条"前缀列表 → endpoint"的路由来生效
  route_table_ids = [aws_route_table.private.id, aws_route_table.public.id]

  tags = { Name = "${var.cluster_name}-s3-endpoint" }
}
