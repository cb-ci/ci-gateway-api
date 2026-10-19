output "instance_id" {
  description = "EC2 instance ID of the Client Controller host."
  value       = aws_instance.this.id
}

output "instance_private_ip" {
  description = "Private IP of the Client Controller host (SSM Session Manager target)."
  value       = aws_instance.this.private_ip
}

output "ec2_controller_url" {
  description = "URL of the standalone Client Controller. Not yet attached to CJOC as a managed controller — see README.md."
  value       = "https://${var.ec2_controller_host_name}/"
}

output "target_group_arn" {
  description = "ARN of the target group registered against the shared ALB."
  value       = aws_lb_target_group.this.arn
}

output "security_group_id" {
  description = "Security group attached to the EC2 instance."
  value       = aws_security_group.this.id
}

output "eks_api_test_command" {
  description = "Run from the instance (e.g. via SSM Session Manager) to confirm network access to the EKS API server."
  # cluster_endpoint from 01-infra is already a full https:// URL.
  value = "curl -k ${local.infra.cluster_endpoint}/version"
}
