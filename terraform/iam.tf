# ============================================================
# IAM：给 EC2 实例分配"身份"（instance profile → IAM role）。
# 实例上的程序（SSM agent、kubelet、EBS CSI driver……）通过元数据服务（IMDS）
# 拿到这个 role 的临时凭证去调用 AWS API。不需要把 AccessKey 写在机器上。
#
# 按角色拆分权限（最小权限原则）：
#   nat           : 只需要 SSM（能被你登录）
#   control plane : SSM + 拉 ECR 镜像 + 管理 EBS 卷（第 07 章 EBS CSI controller 固定调度到这里）
#   worker        : SSM + 拉 ECR 镜像
# ============================================================

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

locals {
  # 每个角色挂哪些 AWS 托管策略
  role_policies = {
    nat = [
      "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    ]
    control-plane = [
      "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
      "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly", # 只能拉镜像，不能推
      "arn:aws:iam::aws:policy/AmazonEBSCSIDriverPolicyV2",         # 第 07 章 EBS CSI 用
    ]
    worker = [
      "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
      "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    ]
  }

  # 展开成 "角色/策略ARN" → {role, arn} 的扁平 map，方便 for_each
  role_policy_attachments = merge([
    for role, arns in local.role_policies : {
      for arn in arns : "${role}/${basename(arn)}" => { role = role, arn = arn }
    }
  ]...)
}

resource "aws_iam_role" "node" {
  for_each = local.role_policies

  name               = "${var.cluster_name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = local.role_policy_attachments

  role       = aws_iam_role.node[each.value.role].name
  policy_arn = each.value.arn
}

resource "aws_iam_instance_profile" "node" {
  for_each = local.role_policies

  name = "${var.cluster_name}-${each.key}"
  role = aws_iam_role.node[each.key].name
}

# 起个短名字，nat.tf / nodes.tf 里读起来更直观
locals {
  instance_profile_nat    = aws_iam_instance_profile.node["nat"].name
  instance_profile_cp     = aws_iam_instance_profile.node["control-plane"].name
  instance_profile_worker = aws_iam_instance_profile.node["worker"].name
}
