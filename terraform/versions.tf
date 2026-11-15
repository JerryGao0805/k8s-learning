# Terraform 本身和 provider（插件）的版本约束。
# provider 是 Terraform 跟某个平台（这里是 AWS）打交道的"驱动程序"。
terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" # 允许 6.x 的任何版本，不会自动跳到 7.0
    }
    archive = {
      source  = "hashicorp/archive" # 用来把自动关机 Lambda 的 Python 代码打成 zip
      version = "~> 2.7"
    }
  }
}
