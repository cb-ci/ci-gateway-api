# =============================================================================
# WHY THIS IS A SEPARATE ROOT MODULE
# =============================================================================
# The kubernetes/helm/kubectl providers must be configured with the cluster
# endpoint and CA. If those came from resources created in the same apply,
# Terraform would have to configure a provider from values that do not exist
# until apply time — which fails on the first run and breaks `destroy`.
# Splitting the stack means 01-infra creates the cluster, and this module
# reads it back through state.
data "terraform_remote_state" "infra" {
  backend = "local"

  config = {
    path = "${path.module}/../01-infra/terraform.tfstate"
  }
}

locals {
  infra    = data.terraform_remote_state.infra.outputs
  region   = local.infra.region
  cluster  = local.infra.cluster_name
  endpoint = local.infra.cluster_endpoint
  ca_cert  = base64decode(local.infra.cluster_ca_certificate)

  # Short-lived token via the AWS CLI, so credentials are never written to
  # state. Requires `aws` on PATH with the same profile used for 01-infra.
  exec_args = ["eks", "get-token", "--cluster-name", local.cluster, "--region", local.region]
}

provider "aws" {
  region = local.region
}

provider "kubernetes" {
  host                   = local.endpoint
  cluster_ca_certificate = local.ca_cert

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.exec_args
  }
}

provider "helm" {
  kubernetes {
    host                   = local.endpoint
    cluster_ca_certificate = local.ca_cert

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.exec_args
    }
  }
}

provider "kubectl" {
  host                   = local.endpoint
  cluster_ca_certificate = local.ca_cert
  load_config_file       = false
  apply_retry_count      = 3

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.exec_args
  }
}
