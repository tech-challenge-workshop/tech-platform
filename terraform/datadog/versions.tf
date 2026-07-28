terraform {
  required_version = ">= 1.11.1"

  required_providers {
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.60"
    }
  }

  # Shares the bucket created by ../bootstrap under a separate key, so this
  # stack can be applied and destroyed independently of the AWS platform.
  backend "s3" {
    bucket       = "tech-challenge-fase4-tfstate"
    key          = "datadog/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
