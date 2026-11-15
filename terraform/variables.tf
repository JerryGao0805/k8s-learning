# ============================================================
# 输入变量。在 terraform.tfvars 里覆盖默认值（该文件不进 git）。
# ============================================================

# ---------- 全局 ----------
variable "region" {
  description = "AWS 区域"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "项目标签值；脚本和自动关机都靠它识别本项目的资源"
  type        = string
  default     = "k8s-learning"
}

variable "cluster_name" {
  description = "集群名，用作资源名前缀"
  type        = string
  default     = "k8s-lab"
}

# ---------- 网络 ----------
variable "vpc_cidr" {
  description = "VPC 网段。注意不能和 Pod 网段(192.168.0.0/16)、Service 网段(10.96.0.0/12)重叠"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "使用的 3 个可用区。节点按顺序轮流放进这些 AZ"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]

  validation {
    condition     = length(var.azs) == 3
    error_message = "本项目按 3 个可用区设计（etcd 3 节点各占一个 AZ），请正好给 3 个。"
  }
}

# ---------- 节点 ----------
variable "cp_count" {
  description = "control plane 节点数。从 1 开始，第 11 章改成 3 做高可用（必须是奇数）"
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 3], var.cp_count)
    error_message = "cp_count 只能是 1 或 3（etcd 需要奇数个成员，且本项目最多 3 个 AZ）。"
  }
}

variable "worker_count" {
  description = "worker 节点数。从 2 开始，第 11 章改成 3"
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 1 && var.worker_count <= 3
    error_message = "worker_count 取 1~3。"
  }
}

variable "cp_instance_type" {
  description = "control plane 机型（Graviton/arm64）。2 vCPU / 4 GiB"
  type        = string
  default     = "t4g.medium"
}

variable "worker_instance_type" {
  description = "worker 机型（Graviton/arm64）。2 vCPU / 8 GiB，后面要跑监控栈，内存给足"
  type        = string
  default     = "t4g.large"
}

variable "nat_instance_type" {
  description = "NAT 实例机型。t4g.small 在 2026-12-31 前每月有 750 小时免费额度"
  type        = string
  default     = "t4g.small"
}

variable "node_root_volume_gb" {
  description = "每个 K8s 节点的系统盘大小（GiB，gp3）"
  type        = number
  default     = 30
}

# ---------- 访问 / 安全 ----------
variable "my_ip_cidr" {
  description = "你家/办公室的公网 IP（/32）。第 13 章公网入口才用到；用 scripts/update-my-ip.sh 自动填"
  type        = string
  default     = null
}

# ---------- 成本护栏 ----------
variable "autostop_enabled" {
  description = "是否创建『每晚自动关机』定时任务"
  type        = bool
  default     = true
}

variable "autostop_cron" {
  description = "自动关机时间（EventBridge Scheduler 的 cron 表达式）。默认每天 02:00"
  type        = string
  default     = "cron(0 2 * * ? *)"
}

variable "autostop_timezone" {
  description = "自动关机 cron 使用的时区"
  type        = string
  default     = "America/New_York"
}

variable "budget_limit_usd" {
  description = "AWS Budgets 每月预算上限（美元）"
  type        = number
  default     = 80
}

variable "budget_email" {
  description = "预算告警邮件发给谁。留空则不创建预算告警"
  type        = string
  default     = ""
}
