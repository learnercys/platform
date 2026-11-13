terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  # State in S3 with native locking. Bucket and region are supplied at init:
  #   terraform init -backend-config=backend.hcl
  backend "s3" {
    key          = "platform/staging.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = local.tags
  }
}
