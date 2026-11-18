# ============================================================
# 安全组（Security Group）= 绑在网卡上的有状态防火墙。
#   - "有状态"：放行了进来的请求，回包自动放行，不用另写规则
#   - 规则的来源可以是 CIDR，也可以是"另一个安全组"（意思是：绑了那个安全组的所有机器）
#
# 端口依据：
#   - K8s 官方 Ports and Protocols：https://kubernetes.io/docs/reference/networking/ports-and-protocols/
#   - Calico（VXLAN 模式）额外需要的端口
#
# 节点上没有任何从公网进来的规则。登录走 SSM，不需要 22 端口。
# ============================================================

resource "aws_security_group" "nat" {
  name        = "${var.cluster_name}-nat"
  description = "NAT instance"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.cluster_name}-nat" }
}

resource "aws_security_group" "control_plane" {
  name        = "${var.cluster_name}-control-plane"
  description = "Kubernetes control plane nodes"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.cluster_name}-control-plane" }
}

resource "aws_security_group" "worker" {
  name        = "${var.cluster_name}-worker"
  description = "Kubernetes worker nodes"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.cluster_name}-worker" }
}

# 给内网 NLB 用的安全组。NLB 要等账号能创建负载均衡后才建（enable_api_lb），但 NLB 的安全组只能在创建时绑定，
# 所以先把它和相关规则建好留着。安全组本身不收费。
resource "aws_security_group" "api_lb" {
  name        = "${var.cluster_name}-api-lb"
  description = "Internal NLB in front of kube-apiserver"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.cluster_name}-api-lb" }
}

locals {
  sg_nat    = aws_security_group.nat.id
  sg_cp     = aws_security_group.control_plane.id
  sg_worker = aws_security_group.worker.id
  sg_api_lb = aws_security_group.api_lb.id

  # 入站规则表。每条：sg = 规则加在哪个安全组上；from_sg / cidr = 允许谁进来（二选一）
  ingress_rules = {
    # ---------------- NAT 实例 ----------------
    # VPC 内部来的所有流量都放行。NAT 要转发的不只是 80/443：
    # 还有 cert-manager 查 DNS 用的 53、git 用的 22、NTP、ICMP 等。
    "nat-all-from-vpc" = { sg = local.sg_nat, from_sg = null, cidr = var.vpc_cidr, proto = "-1", from = null, to = null, desc = "All traffic from inside the VPC (to be NATed)" }

    # ---------------- 内网 API NLB ----------------
    # 节点、以及 SSM 端口转发（从某个节点发起）都来自 VPC 内部
    "apilb-6443-from-vpc" = { sg = local.sg_api_lb, from_sg = null, cidr = var.vpc_cidr, proto = "tcp", from = 6443, to = 6443, desc = "kube-apiserver via NLB" }

    # ---------------- Control Plane ----------------
    # kube-apiserver：经 NLB 进来时，来源是 NLB（因为 preserve_client_ip=false，见 api-lb.tf）
    "cp-6443-from-apilb" = { sg = local.sg_cp, from_sg = local.sg_api_lb, cidr = null, proto = "tcp", from = 6443, to = 6443, desc = "kube-apiserver from internal NLB" }
    # 节点上的 Pod 访问 kubernetes Service(10.96.0.1) 时，会被 DNAT 直接打到 apiserver 的节点 IP
    "cp-6443-from-cp"     = { sg = local.sg_cp, from_sg = local.sg_cp, cidr = null, proto = "tcp", from = 6443, to = 6443, desc = "kube-apiserver from control plane / its pods" }
    "cp-6443-from-worker" = { sg = local.sg_cp, from_sg = local.sg_worker, cidr = null, proto = "tcp", from = 6443, to = 6443, desc = "kube-apiserver from worker pods via kubernetes Service" }
    # etcd：2379 给 apiserver 当客户端用，2380 是 etcd 成员之间的 Raft 通信。只有 control plane 之间需要
    "cp-etcd-from-cp" = { sg = local.sg_cp, from_sg = local.sg_cp, cidr = null, proto = "tcp", from = 2379, to = 2380, desc = "etcd client + peer" }
    # kubelet API：apiserver 用它执行 logs/exec；metrics-server/Prometheus（跑在 worker 上）也要访问它
    "cp-10250-from-cp"     = { sg = local.sg_cp, from_sg = local.sg_cp, cidr = null, proto = "tcp", from = 10250, to = 10250, desc = "kubelet API" }
    "cp-10250-from-worker" = { sg = local.sg_cp, from_sg = local.sg_worker, cidr = null, proto = "tcp", from = 10250, to = 10250, desc = "kubelet API (metrics-server etc.)" }
    # kube-controller-manager / kube-scheduler 的安全端口（健康检查、指标）
    "cp-10257-from-cp" = { sg = local.sg_cp, from_sg = local.sg_cp, cidr = null, proto = "tcp", from = 10257, to = 10257, desc = "kube-controller-manager" }
    "cp-10259-from-cp" = { sg = local.sg_cp, from_sg = local.sg_cp, cidr = null, proto = "tcp", from = 10259, to = 10259, desc = "kube-scheduler" }
    # kube-proxy 健康检查端口
    "cp-10256-from-vpc" = { sg = local.sg_cp, from_sg = null, cidr = var.vpc_cidr, proto = "tcp", from = 10256, to = 10256, desc = "kube-proxy healthz" }
    # Calico VXLAN 隧道：跨节点的 Pod 流量都封装在 UDP 4789 里。
    # apiserver 调用 webhook（cert-manager、Kyverno……）也走这条隧道，所以 cp<->worker 双向都要开
    "cp-vxlan-from-cp"     = { sg = local.sg_cp, from_sg = local.sg_cp, cidr = null, proto = "udp", from = 4789, to = 4789, desc = "Calico VXLAN" }
    "cp-vxlan-from-worker" = { sg = local.sg_cp, from_sg = local.sg_worker, cidr = null, proto = "udp", from = 4789, to = 4789, desc = "Calico VXLAN" }
    # Calico Typha：calico-node 通过它订阅集群状态（减轻 apiserver 的压力）
    "cp-typha-from-cp"     = { sg = local.sg_cp, from_sg = local.sg_cp, cidr = null, proto = "tcp", from = 5473, to = 5473, desc = "Calico Typha" }
    "cp-typha-from-worker" = { sg = local.sg_cp, from_sg = local.sg_worker, cidr = null, proto = "tcp", from = 5473, to = 5473, desc = "Calico Typha" }
    # ICMP：方便 ping 排障；更重要的是 "需要分片"(type 3 code 4) 消息，MTU 探测要靠它
    "cp-icmp-from-vpc" = { sg = local.sg_cp, from_sg = null, cidr = var.vpc_cidr, proto = "icmp", from = -1, to = -1, desc = "ICMP (ping, PMTU discovery)" }
    # 监控（第 10 章）：Prometheus 跑在 worker 上，来抓 control plane 上各组件的指标。
    # Pod 访问节点 IP 时，Calico 的 natOutgoing 会把源地址换成 Pod 所在节点的 IP，所以来源写 worker 安全组。
    "cp-etcd-metrics-from-worker"  = { sg = local.sg_cp, from_sg = local.sg_worker, cidr = null, proto = "tcp", from = 2381, to = 2381, desc = "etcd metrics (Prometheus)" }
    "cp-proxy-metrics-from-worker" = { sg = local.sg_cp, from_sg = local.sg_worker, cidr = null, proto = "tcp", from = 10249, to = 10249, desc = "kube-proxy metrics (Prometheus)" }
    "cp-10257-from-worker"         = { sg = local.sg_cp, from_sg = local.sg_worker, cidr = null, proto = "tcp", from = 10257, to = 10257, desc = "kube-controller-manager metrics (Prometheus)" }
    "cp-10259-from-worker"         = { sg = local.sg_cp, from_sg = local.sg_worker, cidr = null, proto = "tcp", from = 10259, to = 10259, desc = "kube-scheduler metrics (Prometheus)" }
    "cp-node-exporter-from-worker" = { sg = local.sg_cp, from_sg = local.sg_worker, cidr = null, proto = "tcp", from = 9100, to = 9100, desc = "node-exporter (Prometheus)" }

    # ---------------- Worker ----------------
    "worker-10250-from-cp"     = { sg = local.sg_worker, from_sg = local.sg_cp, cidr = null, proto = "tcp", from = 10250, to = 10250, desc = "kubelet API" }
    "worker-10250-from-worker" = { sg = local.sg_worker, from_sg = local.sg_worker, cidr = null, proto = "tcp", from = 10250, to = 10250, desc = "kubelet API (metrics-server etc.)" }
    "worker-10256-from-vpc"    = { sg = local.sg_worker, from_sg = null, cidr = var.vpc_cidr, proto = "tcp", from = 10256, to = 10256, desc = "kube-proxy healthz" }
    # NodePort 端口段：第 14 章会在节点之间用 curl 测试 NodePort Service
    "worker-nodeport-tcp-from-cp"     = { sg = local.sg_worker, from_sg = local.sg_cp, cidr = null, proto = "tcp", from = 30000, to = 32767, desc = "NodePort Services (TCP)" }
    "worker-nodeport-tcp-from-worker" = { sg = local.sg_worker, from_sg = local.sg_worker, cidr = null, proto = "tcp", from = 30000, to = 32767, desc = "NodePort Services (TCP)" }
    "worker-nodeport-udp-from-cp"     = { sg = local.sg_worker, from_sg = local.sg_cp, cidr = null, proto = "udp", from = 30000, to = 32767, desc = "NodePort Services (UDP)" }
    "worker-nodeport-udp-from-worker" = { sg = local.sg_worker, from_sg = local.sg_worker, cidr = null, proto = "udp", from = 30000, to = 32767, desc = "NodePort Services (UDP)" }
    "worker-vxlan-from-cp"            = { sg = local.sg_worker, from_sg = local.sg_cp, cidr = null, proto = "udp", from = 4789, to = 4789, desc = "Calico VXLAN" }
    "worker-vxlan-from-worker"        = { sg = local.sg_worker, from_sg = local.sg_worker, cidr = null, proto = "udp", from = 4789, to = 4789, desc = "Calico VXLAN" }
    "worker-typha-from-cp"            = { sg = local.sg_worker, from_sg = local.sg_cp, cidr = null, proto = "tcp", from = 5473, to = 5473, desc = "Calico Typha" }
    "worker-typha-from-worker"        = { sg = local.sg_worker, from_sg = local.sg_worker, cidr = null, proto = "tcp", from = 5473, to = 5473, desc = "Calico Typha" }
    "worker-icmp-from-vpc"            = { sg = local.sg_worker, from_sg = null, cidr = var.vpc_cidr, proto = "icmp", from = -1, to = -1, desc = "ICMP (ping, PMTU discovery)" }
    # 监控（第 10 章）：Prometheus 抓其他 worker 上的 kube-proxy 指标和 node-exporter
    "worker-proxy-metrics-from-worker" = { sg = local.sg_worker, from_sg = local.sg_worker, cidr = null, proto = "tcp", from = 10249, to = 10249, desc = "kube-proxy metrics (Prometheus)" }
    "worker-node-exporter-from-worker" = { sg = local.sg_worker, from_sg = local.sg_worker, cidr = null, proto = "tcp", from = 9100, to = 9100, desc = "node-exporter (Prometheus)" }
  }
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = local.ingress_rules

  security_group_id            = each.value.sg
  referenced_security_group_id = each.value.from_sg
  cidr_ipv4                    = each.value.cidr
  ip_protocol                  = each.value.proto
  from_port                    = each.value.from
  to_port                      = each.value.to
  description                  = each.value.desc

  tags = { Name = each.key }
}

# 出站：全部放行。节点要访问 apt 源、镜像仓库、AWS API、SSM 等。
# 注意：NLB 的健康检查也受 NLB 安全组的「出站」规则约束，所以 api_lb 的出站必须放开。
resource "aws_vpc_security_group_egress_rule" "all" {
  for_each = {
    nat    = local.sg_nat
    cp     = local.sg_cp
    worker = local.sg_worker
    api_lb = local.sg_api_lb
  }

  security_group_id = each.value
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all outbound"

  tags = { Name = "${each.key}-egress-all" }
}
