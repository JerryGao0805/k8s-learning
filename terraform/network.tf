# ============================================================
# 网络地基：VPC、子网、互联网网关、路由表
#
#   VPC 10.0.0.0/16
#   ├── public  10.0.0.0/24  (AZ a)  ← NAT 实例、（第 09 章）公网 NLB
#   ├── public  10.0.1.0/24  (AZ b)
#   ├── public  10.0.2.0/24  (AZ c)
#   ├── private 10.0.10.0/24 (AZ a)  ← cp-1, worker-1, 内网 API NLB
#   ├── private 10.0.11.0/24 (AZ b)  ← cp-2, worker-2
#   └── private 10.0.12.0/24 (AZ c)  ← cp-3, worker-3
#
# 「公有」和「私有」子网的唯一区别是路由表：
#   - 公有子网：0.0.0.0/0 → Internet Gateway（双向直通公网）
#   - 私有子网：0.0.0.0/0 → NAT 实例（只能主动出去，外面进不来）
# ============================================================

locals {
  public_subnet_cidrs  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i)]      # 10.0.0-2.0/24
  private_subnet_cidrs = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, 10 + i)] # 10.0.10-12.0/24
}

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # 这两项必须打开：
  #   - Route53 私有托管区（api.k8s.internal）依赖 VPC 自带的 DNS 解析器（10.0.0.2）
  #   - 实例会自动获得 ip-10-0-10-11.ec2.internal 这样的主机名，K8s 节点名就用它
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.cluster_name}-vpc" }
}

# Internet Gateway：VPC 通往公网的大门。只有公有子网的路由表会指向它。
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.cluster_name}-igw" }
}

# ---------- 子网 ----------
resource "aws_subnet" "public" {
  count = 3

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.public_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  # 不自动给公网 IP；NAT 实例会在自己的配置里单独申请
  map_public_ip_on_launch = false

  tags = { Name = "${var.cluster_name}-public-${var.azs[count.index]}", Tier = "public" }
}

resource "aws_subnet" "private" {
  count = 3

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = { Name = "${var.cluster_name}-private-${var.azs[count.index]}", Tier = "private" }
}

# ---------- 公有路由表 ----------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.cluster_name}-public-rt" }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------- 私有路由表 ----------
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.cluster_name}-private-rt" }
}

# 私有子网的默认路由指向 NAT 实例的网卡（ENI）。
# 停掉 NAT 实例时，这条路由会显示为 blackhole（黑洞）；NAT 启动后自动恢复，
# 因为网卡（ENI）在 stop/start 之后保持不变。
resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat.primary_network_interface_id
}

resource "aws_route_table_association" "private" {
  count          = 3
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
