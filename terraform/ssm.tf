# ============================================================
# SSM Session Manager：不开 22 端口、不用 SSH 密钥也能登录节点。
#
# 原理：每台机器上的 SSM agent 主动"往外"连到 AWS 的 SSM 服务（经 NAT 出去），
# 你在 Mac 上执行 aws ssm start-session 时，AWS 把两头接起来。
# 全程只有出站连接，所以节点不需要任何入站规则；谁能登录由 IAM 权限决定。
#
# 这里建一个自定义的会话文档（"会话偏好设置"）：
#   - 默认 shell 是 sh，这里改成登录式 bash（有补全、历史记录、颜色）
#   - 空闲超时从默认的 20 分钟改成 60 分钟（上限就是 60）
# 用自定义文档，而不改账号级别的默认设置，是为了不影响账号里的其他机器。
# scripts/ssm.sh 会自动使用这个文档。
# ============================================================

resource "aws_ssm_document" "shell" {
  name            = "${var.cluster_name}-shell"
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Interactive bash shell for the ${var.project} lab"
    sessionType   = "Standard_Stream"
    inputs = {
      idleSessionTimeout          = "60"
      runAsEnabled                = false
      runAsDefaultUser            = ""
      s3BucketName                = ""
      s3KeyPrefix                 = ""
      s3EncryptionEnabled         = false
      cloudWatchLogGroupName      = ""
      cloudWatchEncryptionEnabled = false
      cloudWatchStreamingEnabled  = false
      kmsKeyId                    = ""
      shellProfile = {
        linux   = "cd ~ && exec bash -l"
        windows = ""
      }
    }
  })
}
