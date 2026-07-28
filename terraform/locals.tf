data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name = "${var.project}-${var.environment}"

  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # One PostgreSQL instance per service that owns relational data.
  # Database-per-service: neither instance is reachable by the other's credentials.
  postgres_databases = {
    work-order = {
      database = "workorder"
      username = "workorder"
    }
    billing = {
      database = "billing"
      username = "billing"
    }
  }
}
