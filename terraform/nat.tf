# ============================================================
# NAT 实例：让私有子网里的 K8s 节点能主动访问公网（apt、拉镜像、SSM），
# 但公网无法主动连进来。
#
# AWS 有托管的 NAT Gateway，但它约 $33/月，而且只要存在就一直计费、没法 stop。
# 我们自己用一台小 EC2 来做，原理完全一样：
#   - 内核打开 ip_forward（允许转发）
#   - iptables MASQUERADE（把源地址改成自己的）
# 这两样东西在 K8s 里会反复出现（kube-proxy、Calico 的 natOutgoing），
# 先在这里亲手见一次。
# ============================================================

resource "aws_instance" "nat" {
  ami                         = data.aws_ssm_parameter.ubuntu_arm64.insecure_value
  instance_type               = var.nat_instance_type
  subnet_id                   = aws_subnet.public[0].id
  associate_public_ip_address = true # 需要公网 IP 才能替别人上网（stop/start 后这个 IP 会变，没关系）
  vpc_security_group_ids      = [aws_security_group.nat.id]
  iam_instance_profile        = local.instance_profile_nat

  # 关键！EC2 默认会丢弃"源地址或目的地址不是自己"的包（source/dest check）。
  # NAT 要转发别人的包，必须关掉这个检查。
  source_dest_check = false

  user_data = templatefile("${path.module}/templates/nat-userdata.sh.tftpl", {
    vpc_cidr = var.vpc_cidr
  })

  metadata_options {
    http_tokens                 = "required" # 只允许 IMDSv2（带 token 的元数据访问方式，更安全）
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  tags = {
    Name     = "${var.cluster_name}-nat"
    NodeName = "nat" # 脚本按这个标签找机器：./scripts/ssm.sh nat
    Role     = "nat"
  }

  lifecycle {
    # Ubuntu 的 AMI ID 每隔一段时间就会更新。不忽略的话，下次 apply 会要求销毁重建这台机器。
    ignore_changes = [ami, user_data]
  }

  # 等 SSM 权限挂好再开机，SSM agent 第一次启动就能注册成功
  depends_on = [aws_iam_role_policy_attachment.node]
}
