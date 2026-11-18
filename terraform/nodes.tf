# ============================================================
# K8s 节点：control plane × cp_count，worker × worker_count
#
# 节点按顺序轮流放进 3 个 AZ，并用固定的私网 IP，好记、好排障：
#   cp-1 10.0.10.11 (a)   cp-2 10.0.11.11 (b)   cp-3 10.0.12.11 (c)
#   worker-1 10.0.10.21   worker-2 10.0.11.21   worker-3 10.0.12.21
# ============================================================

# Canonical 官方发布的 Ubuntu 24.04 LTS arm64 镜像 ID（从 SSM 公共参数里查）
data "aws_ssm_parameter" "ubuntu_arm64" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

locals {
  control_plane_nodes = {
    for i in range(var.cp_count) : "cp-${i + 1}" => {
      az_index   = i % 3
      private_ip = cidrhost(local.private_subnet_cidrs[i % 3], 11)
    }
  }

  worker_nodes = {
    for i in range(var.worker_count) : "worker-${i + 1}" => {
      az_index   = i % 3
      private_ip = cidrhost(local.private_subnet_cidrs[i % 3], 21)
    }
  }
}

resource "aws_instance" "control_plane" {
  for_each = local.control_plane_nodes

  ami                    = data.aws_ssm_parameter.ubuntu_arm64.insecure_value
  instance_type          = var.cp_instance_type
  subnet_id              = aws_subnet.private[each.value.az_index].id
  private_ip             = each.value.private_ip
  vpc_security_group_ids = [aws_security_group.control_plane.id]
  iam_instance_profile   = local.instance_profile_cp

  user_data = templatefile("${path.module}/templates/node-userdata.sh.tftpl", {
    node_name = each.key
  })

  metadata_options {
    http_tokens = "required" # 只允许 IMDSv2
    # hop limit = 数据包能经过几"跳"。容器里的进程访问 IMDS 要多一跳，所以设成 2。
    # 只在 control plane 上这么设：第 07 章的 EBS CSI controller（跑在 Pod 里）
    # 需要通过 IMDS 拿实例凭证。worker 保持 1，worker 上的 Pod 拿不到实例凭证。
    http_put_response_hop_limit = 2
  }

  # T 系列是"可突发"机型：平时 CPU 用量低于基准就攒积分，忙的时候花积分。
  # unlimited：积分花光了也不降速（持续超出基准才会额外收一点费）。
  # 选它是为了避免 etcd/apiserver 在 CPU 被限速时出现各种诡异的超时。
  credit_specification {
    cpu_credits = "unlimited"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.node_root_volume_gb
    encrypted   = true
  }

  tags = {
    Name     = "${var.cluster_name}-${each.key}"
    NodeName = each.key # 脚本按这个标签找机器：./scripts/ssm.sh cp-1
    Role     = "control-plane"
  }

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  depends_on = [aws_iam_role_policy_attachment.node, aws_route.private_default]
}

resource "aws_instance" "worker" {
  for_each = local.worker_nodes

  ami                    = data.aws_ssm_parameter.ubuntu_arm64.insecure_value
  instance_type          = var.worker_instance_type
  subnet_id              = aws_subnet.private[each.value.az_index].id
  private_ip             = each.value.private_ip
  vpc_security_group_ids = [aws_security_group.worker.id]
  iam_instance_profile   = local.instance_profile_worker

  user_data = templatefile("${path.module}/templates/node-userdata.sh.tftpl", {
    node_name = each.key
  })

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1 # worker 上的 Pod 访问不到 IMDS（kubelet 在宿主机上，不受影响）
  }

  credit_specification {
    cpu_credits = "unlimited"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.node_root_volume_gb
    encrypted   = true
  }

  tags = {
    Name     = "${var.cluster_name}-${each.key}"
    NodeName = each.key
    Role     = "worker"
  }

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  depends_on = [aws_iam_role_policy_attachment.node, aws_route.private_default]
}
