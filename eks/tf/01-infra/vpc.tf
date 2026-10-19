# =============================================================================
# VPC — replaces the `vpc:` block of eksctl-config.yaml
# =============================================================================
# eksctl auto-derived subnets from vpc.cidr; here the /20s are explicit so the
# layout is reviewable in a plan. Single NAT gateway matches `nat.gateway: Single`.
# Nodes are private-only (privateNetworking: true) and egress through the NAT.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr
  azs  = var.azs

  private_subnets = [for i, az in var.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, az in var.azs : cidrsubnet(var.vpc_cidr, 4, i + length(var.azs))]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  # The AWS Load Balancer Controller discovers where to place load balancers
  # from these tags. Without the public tag the ALB silently fails to
  # provision with an "unable to discover subnets" event on the Ingress.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  # 02-create-efs-filesystem.sh looked subnets up by this exact tag; the EFS
  # mount targets in efs.tf use the module output directly instead.
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = local.tags
}
