terraform {
  # OpenTofu. terraform-aws-modules/rds 7.x requires >= 1.11.1.
  required_version = ">= 1.11.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.56"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    mongodbatlas = {
      source  = "mongodb/mongodbatlas"
      version = "~> 1.30"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # State lives in the bucket created by ./bootstrap.
  # use_lockfile replaces the legacy DynamoDB lock table.
  backend "s3" {
    bucket       = "tech-challenge-fase4-tfstate"
    key          = "platform/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
