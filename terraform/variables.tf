variable "region" {
  description = "AWS region that hosts every resource in this stack"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Short project slug used as a prefix for every resource name"
  type        = string
  default     = "tech-challenge"
}

variable "environment" {
  description = "Environment slug appended to every resource name"
  type        = string
  default     = "dev"
}

variable "az_count" {
  description = "How many availability zones the subnets are spread across"
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "EKS and RDS both require at least two availability zones."
  }
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "kubernetes_version" {
  description = "EKS control plane version"
  type        = string
  default     = "1.35"
}

# The account is on the AWS Free Plan, which refuses any instance type outside
# the free-tier-eligible list — the node group hangs with "The specified
# instance type is not eligible for Free Tier" and never launches. Check the
# current list with:
#   aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true
variable "node_instance_types" {
  description = "Instance types the managed node group may pick from; must be free-tier eligible on the Free Plan"
  type        = list(string)
  default     = ["c7i-flex.large", "m7i-flex.large"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT for the managed node group"
  type        = string
  # Spot on the flex families reported UnfulfillableCapacity alongside the
  # free-tier rejection, so the demo does not depend on spare capacity.
  default = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be either ON_DEMAND or SPOT."
  }
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 4
}

variable "node_desired_size" {
  description = "Desired number of worker nodes at creation time"
  type        = number
  default     = 2
}

variable "postgres_version" {
  description = "PostgreSQL engine version for the RDS instances"
  type        = string
  default     = "17.10"
}

variable "postgres_instance_class" {
  description = "Instance class for the RDS instances"
  type        = string
  default     = "db.t4g.micro"
}

variable "postgres_allocated_storage" {
  description = "Allocated storage in GB for each RDS instance"
  type        = number
  default     = 20
}

variable "mongodbatlas_org_id" {
  description = "MongoDB Atlas organisation that owns the project"
  type        = string
  default     = "6a68cdb1beb3f137a7941efb"
}

variable "mongodbatlas_cluster_name" {
  description = "Name of the Atlas cluster; M0 allows exactly one per project"
  type        = string
  default     = "tech-challenge"
}

variable "mongodbatlas_region" {
  description = "Atlas region, in Atlas notation — kept in the same AWS region as the cluster"
  type        = string
  default     = "US_EAST_1"
}

variable "rabbitmq_version" {
  description = "RabbitMQ engine version on Amazon MQ"
  type        = string
  default     = "4.2"
}

# RabbitMQ on Amazon MQ does not accept mq.t3.micro — that size is ActiveMQ
# only, which is why the free tier never covered a managed RabbitMQ. m7g.medium
# is the smallest the engine supports:
#   aws mq describe-broker-instance-options --engine-type RABBITMQ
variable "rabbitmq_instance_type" {
  description = "Amazon MQ broker host instance type; RabbitMQ's smallest is mq.m7g.medium"
  type        = string
  default     = "mq.m7g.medium"
}

variable "github_org" {
  description = "GitHub organisation that owns the service repositories"
  type        = string
  default     = "tech-challenge-workshop"
}

variable "github_deploy_repositories" {
  description = "Repositories allowed to assume the deploy role, from their default branch only"
  type        = list(string)
  default = [
    "work-order-service",
    "billing-service",
    "execution-service",
    "auth-service",
  ]
}

variable "application_namespace" {
  description = "Kubernetes namespace the services run in, and the only one the deploy role may edit"
  type        = string
  default     = "tech-challenge"
}

variable "rabbitmq_username" {
  description = "Master username of the Amazon MQ RabbitMQ broker"
  type        = string
  default     = "tech_challenge"
}
