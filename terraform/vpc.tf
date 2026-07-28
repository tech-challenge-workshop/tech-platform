module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "${local.name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  # Public: NAT gateway and the Kong NLB.
  # Private: EKS worker nodes and the Amazon MQ broker.
  # Database: RDS and DocumentDB, no route to the internet at all.
  public_subnets   = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 4)]
  database_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 128)]

  create_database_subnet_group = true

  # A single NAT gateway is the cheapest way to give private nodes egress
  # (ghcr.io pulls, Datadog, Mercado Pago). Flip to one_nat_gateway_per_az
  # for a production-grade, AZ-fault-tolerant setup.
  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Consumed by the AWS Load Balancer Controller when Kong requests an NLB.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = local.tags
}
