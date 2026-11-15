# terraform apply 完成后打印这些信息；之后随时可以用 `terraform output` 再看。

output "vpc_id" {
  value = aws_vpc.main.id
}

output "nat_instance" {
  description = "NAT 实例（公网 IP 在 stop/start 后会变）"
  value = {
    id         = aws_instance.nat.id
    private_ip = aws_instance.nat.private_ip
    public_ip  = aws_instance.nat.public_ip
  }
}

output "nodes" {
  description = "K8s 节点：名字 → 实例 ID / 私网 IP / 可用区"
  value = merge(
    { for k, v in aws_instance.control_plane : k => { id = v.id, private_ip = v.private_ip, az = v.availability_zone, role = "control-plane" } },
    { for k, v in aws_instance.worker : k => { id = v.id, private_ip = v.private_ip, az = v.availability_zone, role = "worker" } },
  )
}

output "control_plane_endpoint" {
  description = "kubeadm 配置里 controlPlaneEndpoint 填这个"
  value       = "${aws_route53_record.api.name}:6443"
}

output "api_nlb_dns" {
  value = aws_lb.api.dns_name
}

output "api_target_group_arn" {
  description = "查看 NLB 目标健康状态：aws elbv2 describe-target-health --target-group-arn <这个值>"
  value       = aws_lb_target_group.api.arn
}

output "ssm_shell_document" {
  value = aws_ssm_document.shell.name
}

output "ubuntu_ami_id" {
  description = "本次创建实例用的 Ubuntu 24.04 arm64 AMI"
  value       = data.aws_ssm_parameter.ubuntu_arm64.insecure_value
}
