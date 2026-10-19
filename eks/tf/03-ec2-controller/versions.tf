terraform {
  # Matches tf/.tool-versions (1.15.8) — see 01-infra/versions.tf for why the
  # asdf global default (1.4.6) will not work here.
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}
