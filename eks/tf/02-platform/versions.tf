terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    # Pinned to 2.x deliberately: helm provider 3.x changed `set` blocks to a
    # list attribute. Every release here passes values via yamlencode(), which
    # is stable across both, but the pin keeps `terraform init` reproducible.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    # Gateway API / Envoy Gateway custom resources are applied with this rather
    # than kubernetes_manifest: kubernetes_manifest needs the CRD to exist in
    # the API server at *plan* time, which is impossible when the same apply
    # installs the CRDs. alekc/kubectl is the maintained fork of
    # gavinbunney/kubectl, which is abandoned and breaks on modern Terraform.
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
  }
}
