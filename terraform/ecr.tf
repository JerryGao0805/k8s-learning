# ============================================================
# ECR：存放第 08 章示例应用的镜像（私有仓库）。
#   k8s-lab/api   Go 写的后端
#   k8s-lab/web   静态前端（nginx）
#
# 节点拉镜像时，kubelet 通过第 02 章装的 ecr-credential-provider，
# 用节点 IAM 角色（AmazonEC2ContainerRegistryPullOnly，见 iam.tf）换取临时登录凭证。
# 推镜像在 Mac 上做：./app/build-push.sh
# ============================================================

resource "aws_ecr_repository" "app" {
  for_each = toset(["api", "web"])

  name                 = "${var.cluster_name}/${each.key}"
  image_tag_mutability = "MUTABLE" # 同一个 tag 可以覆盖。生产环境通常设成 IMMUTABLE（第 20 章讨论）
  force_delete         = true      # terraform destroy 时，仓库里还有镜像也照样删除

  image_scanning_configuration {
    scan_on_push = true # 推送时做一次基础的漏洞扫描（免费）
  }
}

# 只保留最近 10 个镜像，旧的自动删除（ECR 按存储量收费）
resource "aws_ecr_lifecycle_policy" "app" {
  for_each = aws_ecr_repository.app

  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep only the 10 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
