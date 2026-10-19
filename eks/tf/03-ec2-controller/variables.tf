variable "ec2_controller_host_name" {
  description = "Public hostname for the standalone EC2 Client Controller, e.g. ec2-controller.example.com. A dedicated ACM certificate (SNI) is issued for this name and attached to the existing shared ALB listener."
  type        = string
}

variable "route53_zone_domain" {
  description = <<-EOT
    Public hosted zone that owns ec2_controller_host_name. Defaults to
    ec2_controller_host_name with its first label stripped — override when the
    apex is not simply one label up (multi-level subdomains). Usually the same
    zone as 01-infra's cjoc_host_name.
  EOT
  type        = string
  default     = ""
}

variable "envoy_gw_namespace" {
  description = "Namespace of the existing cjoc-alb Ingress from 02-platform. Used to find the shared ALB by its AWS Load Balancer Controller tags — must match 02-platform's envoy_gw_namespace."
  type        = string
  default     = "envoy-gateway-system"
}

variable "ingress_name" {
  description = "Name of the existing Ingress in 02-platform that provisioned the shared ALB."
  type        = string
  default     = "cjoc-alb"
}

variable "instance_name" {
  description = "Name for the EC2 instance and the resources derived from it (SG, IAM role/profile, target group). Defaults to \"<cluster_name>-ec2-controller\"."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type for the Client Controller host."
  type        = string
  default     = "t3.medium"
}

variable "volume_size_gb" {
  description = "Root EBS volume size (GiB). Holds the Docker-mounted JENKINS_HOME for the Client Controller container."
  type        = number
  default     = 50
}

variable "controller_port" {
  description = "Host port the CloudBees CI Client Controller container binds to and the target group forwards to."
  type        = number
  default     = 8080
}

variable "controller_image" {
  description = <<-EOT
    Docker image for the CloudBees CI Client Controller container. Carried
    over as a placeholder from 07-createEC2WithController.sh — confirm the
    correct image/tag for your licensed CloudBees CI version before applying
    outside a demo.
  EOT
  type        = string
  default     = "cloudbees/cloudbees-core-cm:latest"
}

variable "ssh_key_name" {
  description = "Optional EC2 key pair name for SSH access. SSM Session Manager (via the instance's IAM role) works without one."
  type        = string
  default     = ""
}

variable "ssh_cidr" {
  description = "CIDR allowed to reach the instance on port 22. Defaults to the VPC's own CIDR block."
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "Private subnet for the EC2 instance. Defaults to the first private subnet from 01-infra."
  type        = string
  default     = ""
}

variable "listener_rule_priority" {
  description = <<-EOT
    Priority for the host-header rule added to the shared ALB's HTTPS
    listener. The AWS Load Balancer Controller manages its own rule
    priorities for Ingress-generated rules (typically low numbers); this
    module claims a priority band above what it uses. If `terraform apply`
    fails with "PriorityInUse", pick a different value — check existing
    priorities with:
      aws elbv2 describe-rules --listener-arn <arn>
  EOT
  type        = number
  default     = 100
}

variable "tags" {
  description = "Tags applied to every taggable resource in this stack."
  type        = map(string)
  default = {
    cb-user        = "acaternberg"
    cb-owner       = "professional-services"
    cb-environment = "demo"
  }
}

locals {
  instance_name = var.instance_name != "" ? var.instance_name : "${local.cluster}-ec2-controller"

  # Mirrors the bash default: ROUTE53_ZONE_DOMAIN="${ROUTE53_ZONE_DOMAIN:-$(cut -d. -f2- <<< "$EC2_HOST_NAME")}"
  zone_domain = var.route53_zone_domain != "" ? var.route53_zone_domain : join(".", slice(split(".", var.ec2_controller_host_name), 1, length(split(".", var.ec2_controller_host_name))))

  ssh_cidr  = var.ssh_cidr != "" ? var.ssh_cidr : data.aws_vpc.this.cidr_block
  subnet_id = var.subnet_id != "" ? var.subnet_id : local.infra.private_subnet_ids[0]

  tags = var.tags
}
