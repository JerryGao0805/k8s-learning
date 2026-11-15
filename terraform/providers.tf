provider "aws" {
  region = var.region

  # default_tags：这里定义的标签会自动打到本项目创建的每一个资源上。
  # 好处：
  #   1. 在 AWS 控制台按 Project=k8s-learning 过滤，一眼看到全部资源
  #   2. 脚本（lab-up/lab-down）和自动关机 Lambda 只操作带这个标签的实例，
  #      不会误伤账号里的其他机器
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}
