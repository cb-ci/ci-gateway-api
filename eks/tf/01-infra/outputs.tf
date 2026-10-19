# Consumed by 02-platform via terraform_remote_state.
output "region" {
  description = "AWS region."
  value       = var.region
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA, for the kubernetes/helm providers."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "vpc_id" {
  description = "VPC the cluster runs in."
  value       = module.vpc.vpc_id
}

output "cluster_security_group_id" {
  description = <<-EOT
    EKS-managed "cluster security group". Because endpoint_private_access is
    true, anything resolving the cluster endpoint from inside the VPC gets a
    private ENI IP gated by this security group's inbound rules — public
    endpoint access does not help those callers, since they never take the
    public path. Consumers outside the cluster's own node groups (e.g. the
    EC2 Client Controller in 03-ec2-controller) must be explicitly allowed
    here to reach the API server on 443.
  EOT
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet IDs — where the ALB is placed."
  value       = module.vpc.public_subnets
}

output "efs_id" {
  description = "EFS file system ID, used by the efs-sc StorageClass."
  value       = aws_efs_file_system.this.id
}

output "acm_certificate_arn" {
  description = "Validated ACM certificate ARN for the ALB listener."
  # Reference the validation resource, not the certificate: this forces
  # 02-platform to wait for ISSUED before attaching the cert to the ALB.
  value = aws_acm_certificate_validation.cjoc.certificate_arn
}

output "alb_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller service account."
  value       = aws_iam_role.irsa["alb_controller"].arn
}

output "cluster_autoscaler_role_arn" {
  description = "IRSA role ARN for the Cluster Autoscaler service account."
  value       = aws_iam_role.irsa["cluster_autoscaler"].arn
}

output "cluster_version" {
  description = "EKS control plane Kubernetes minor version, e.g. \"1.35\". cluster-autoscaler's image tag tracks this 1:1."
  value       = aws_eks_cluster.this.version
}

output "route53_zone_id" {
  description = "Hosted zone ID that owns cjoc_host_name."
  value       = data.aws_route53_zone.this.zone_id
}

output "route53_zone_domain" {
  description = "Hosted zone apex domain."
  value       = local.zone_domain
}

output "cjoc_host_name" {
  description = "Public hostname for the Operations Center."
  value       = var.cjoc_host_name
}
