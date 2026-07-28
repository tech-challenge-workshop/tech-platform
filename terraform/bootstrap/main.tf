// One-off stack that creates the S3 bucket backing the root module's remote
// state. Runs with a local state file, because the bucket it creates is the
// very thing a remote backend would need. Apply this once, then never again.

terraform {
  required_version = ">= 1.11.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.56"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  description = "AWS region that hosts the state bucket"
  type        = string
  default     = "us-east-1"
}

variable "state_bucket" {
  description = "Name of the S3 bucket holding the Terraform state"
  type        = string
  default     = "tech-challenge-fase4-tfstate"
}

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket

  tags = {
    Project   = "tech-challenge"
    ManagedBy = "terraform"
    Purpose   = "terraform-remote-state"
  }
}

# Versioning is what makes a corrupted or truncated state recoverable.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "state_bucket" {
  description = "Name of the bucket to reference in the root module's backend block"
  value       = aws_s3_bucket.state.id
}
