variable "region" {
  description = "AWS region for every resource in this stack."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name. Also used as the prefix for EFS, security groups and IAM roles."
  type        = string
  default     = "USER_ID"
}

variable "kubernetes_version" {
  description = "EKS control plane version."
  type        = string
  default     = "1.35"
}

variable "vpc_cidr" {
  description = "CIDR for the VPC this stack creates."
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = <<-EOT
    AZs the VPC spans. EKS requires the control plane's cross-account ENIs to
    live in at least two distinct AZs — this is an AWS-side requirement and
    cannot be relaxed even for a single-AZ design. Compute is pinned to
    node_az alone; the second AZ exists only to satisfy the control plane.
  EOT
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]

  validation {
    condition     = length(var.azs) >= 2
    error_message = "EKS requires at least two availability zones."
  }
}

variable "node_az" {
  description = "The single AZ all worker nodes and the EFS mount target run in. Must be one of azs."
  type        = string
  default     = "us-east-1a"
}

variable "cjoc_host_name" {
  description = "Public hostname for the CloudBees Operations Center, e.g. ci.example.com. The ACM certificate is issued for this name."
  type        = string
}

variable "route53_zone_domain" {
  description = <<-EOT
    Public hosted zone that owns cjoc_host_name. Defaults to cjoc_host_name
    with its first label stripped — override when the apex is not simply one
    label up (multi-level subdomains).
  EOT
  type        = string
  default     = ""
}

variable "controller_instance_types" {
  description = "Instance types for the tainted CloudBees CI controller pool (ARM64/Graviton)."
  type        = list(string)
  default     = ["m7g.xlarge", "m7g.2xlarge"]
}

variable "agent_instance_types" {
  description = "Instance types for the tainted build-agent pool (x86_64)."
  type        = list(string)
  default     = ["m6i.xlarge"]
}

variable "system_instance_types" {
  description = "Instance types for the untainted system pool (x86_64) that hosts cluster add-ons once controllers/agents are both tainted."
  type        = list(string)
  default     = ["m6i.large"]
}

variable "tags" {
  description = "Tags applied to every taggable resource in this stack."
  type        = map(string)
  default = {
    cb-user        = "USER_ID"
    cb-owner       = "professional-services"
    cb-environment = "demo"
  }
}

variable "public_access_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the EKS public API endpoint (the AWS default is
    0.0.0.0/0). Mirrors EKS_PUBLIC_ACCESS_CIDRS in eksctl/.env-template. No
    default on purpose: the machine running terraform/kubectl/helm (including
    the 02-platform providers) must reach the API through one of these, e.g.
    the Tailscale app connector egress IP. Nodes and pods are unaffected
    because endpoint_private_access stays true.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.public_access_cidrs) > 0 && alltrue([for c in var.public_access_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "public_access_cidrs must be a non-empty list of valid IPv4 CIDRs and must not contain 0.0.0.0/0."
  }
}

locals {
  # Mirrors the bash default: ROUTE53_ZONE_DOMAIN="${ROUTE53_ZONE_DOMAIN:-$(cut -d. -f2- <<< "$CJOC_HOST_NAME")}"
  zone_domain = var.route53_zone_domain != "" ? var.route53_zone_domain : join(".", slice(split(".", var.cjoc_host_name), 1, length(split(".", var.cjoc_host_name))))

  tags = var.tags
}
