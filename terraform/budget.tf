# ============================================================
# 成本护栏 2：AWS Budgets 月度预算告警
#
# 注意：这是"整个账号"的预算，账号里其他机器的费用也算在内。
# 按标签只统计本项目的费用也可以做，但需要先在 Billing 控制台激活
# "成本分配标签"，并且要等约 24 小时才生效，这里先不搞复杂。
#
# 告警节点：实际花费达到 50% / 80% / 100%，以及预测月底会超过 100%。
# 第一次创建后，AWS 不会发确认邮件，到了阈值才会直接发告警。
# ============================================================

locals {
  budget_alerts = [
    { type = "ACTUAL", threshold = 50 },
    { type = "ACTUAL", threshold = 80 },
    { type = "ACTUAL", threshold = 100 },
    { type = "FORECASTED", threshold = 100 },
  ]
}

resource "aws_budgets_budget" "monthly" {
  count = var.budget_email == "" ? 0 : 1

  name         = "${var.cluster_name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = local.budget_alerts
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value.type
      subscriber_email_addresses = [var.budget_email]
    }
  }
}
