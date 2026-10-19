# =============================================================================
# WHY THIS IS A SEPARATE ROOT MODULE (AND NOT PART OF 02-PLATFORM)
# =============================================================================
# Everything here is a plain AWS-account resource (EC2, IAM, ACM, ELBv2,
# Route53) — no kubernetes/helm/kubectl provider is needed. Folding it into
# 02-platform would force every apply of this optional add-on to also
# reconcile the cluster's Helm releases. Splitting it out means it can be
# applied, destroyed, or skipped entirely without touching 02-platform.
#
# It still depends on 02-platform having been applied (the shared ALB must
# already exist) — see alb.tf, which looks the ALB up directly by the tags
# the AWS Load Balancer Controller stamped onto it, rather than reading
# 02-platform's state. That keeps this module working even if 02-platform's
# outputs change shape, at the cost of no compile-time dependency: if
# 02-platform hasn't been applied yet, the lookup in alb.tf simply fails at
# plan/apply time with "no matching Load Balancer found".
data "terraform_remote_state" "infra" {
  backend = "local"

  config = {
    path = "${path.module}/../01-infra/terraform.tfstate"
  }
}

locals {
  infra   = data.terraform_remote_state.infra.outputs
  region  = local.infra.region
  cluster = local.infra.cluster_name
}

provider "aws" {
  region = local.region

  default_tags {
    tags = var.tags
  }
}
