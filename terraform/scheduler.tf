# ============================================================
# 成本护栏 1：每晚定时自动关机
#
#   EventBridge Scheduler (每天 02:00) ──► Lambda ──► stop 所有 Project=k8s-learning 的实例
#                                            │
#                                            └─ 先读 SSM 参数 /k8s-learning/autostop，值为 off 就跳过
#
# 这些服务在这种用量下都落在免费额度内。
# ============================================================

data "aws_caller_identity" "current" {}

# ---------- 开关 ----------
resource "aws_ssm_parameter" "autostop_switch" {
  name        = "/${var.project}/autostop"
  description = "on = nightly auto-stop enabled; off = skip. Toggle with scripts/autostop.sh"
  type        = "String"
  value       = "on"

  lifecycle {
    # 开关的值由 scripts/autostop.sh 改，Terraform 只负责创建，之后不管它的值
    ignore_changes = [value]
  }
}

# ---------- Lambda ----------
data "archive_file" "autostop" {
  type        = "zip"
  source_file = "${path.module}/lambda/autostop.py"
  output_path = "${path.module}/build/autostop.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "autostop_lambda" {
  name               = "${var.cluster_name}-autostop-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "autostop_lambda_logs" {
  role       = aws_iam_role.autostop_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "autostop_lambda" {
  statement {
    sid       = "Describe"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"] # Describe 类 API 不支持限定资源
  }

  statement {
    sid       = "StopOnlyOurInstances"
    actions   = ["ec2:StopInstances"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"]

    # 只能 stop 带本项目标签的实例。即使代码写错了，也动不了账号里的其他机器
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.project]
    }
  }

  statement {
    sid       = "ReadSwitch"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.autostop_switch.arn]
  }
}

resource "aws_iam_role_policy" "autostop_lambda" {
  name   = "autostop"
  role   = aws_iam_role.autostop_lambda.id
  policy = data.aws_iam_policy_document.autostop_lambda.json
}

resource "aws_cloudwatch_log_group" "autostop" {
  name              = "/aws/lambda/${var.cluster_name}-autostop"
  retention_in_days = 14
}

resource "aws_lambda_function" "autostop" {
  function_name    = "${var.cluster_name}-autostop"
  role             = aws_iam_role.autostop_lambda.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "autostop.handler"
  filename         = data.archive_file.autostop.output_path
  source_code_hash = data.archive_file.autostop.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      PROJECT      = var.project
      SWITCH_PARAM = aws_ssm_parameter.autostop_switch.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.autostop, aws_iam_role_policy_attachment.autostop_lambda_logs]
}

# ---------- 定时触发 ----------
data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "autostop_scheduler" {
  name               = "${var.cluster_name}-autostop-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

resource "aws_iam_role_policy" "autostop_scheduler" {
  name = "invoke-autostop"
  role = aws_iam_role.autostop_scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.autostop.arn
    }]
  })
}

resource "aws_scheduler_schedule" "autostop" {
  name                         = "${var.cluster_name}-nightly-stop"
  schedule_expression          = var.autostop_cron
  schedule_expression_timezone = var.autostop_timezone
  state                        = var.autostop_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.autostop.arn
    role_arn = aws_iam_role.autostop_scheduler.arn
  }
}
