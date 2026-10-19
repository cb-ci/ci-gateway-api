terraform {
  # The asdf global default is Terraform 1.4.6, which is EOL and cannot run AWS
  # provider 5.9x (plugin protocol mismatch). tf/.tool-versions pins 1.15.8.
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
