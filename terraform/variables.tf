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
    error_message = "EKS, RDS and DocumentDB all require at least two availability zones."
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

variable "node_instance_types" {
  description = "Instance types the managed node group may pick from"
  type        = list(string)
  default     = ["t3.medium", "t3a.medium"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT for the managed node group"
  type        = string
  default     = "SPOT"

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

variable "documentdb_version" {
  description = "DocumentDB engine version (MongoDB-compatible API)"
  type        = string
  default     = "5.0.1"
}

variable "documentdb_instance_class" {
  description = "Instance class for the DocumentDB cluster instances"
  type        = string
  default     = "db.t4g.medium"
}

variable "documentdb_instance_count" {
  description = "Number of instances in the DocumentDB cluster"
  type        = number
  default     = 1
}

variable "rabbitmq_version" {
  description = "RabbitMQ engine version on Amazon MQ"
  type        = string
  default     = "4.2"
}

variable "rabbitmq_instance_type" {
  description = "Amazon MQ broker host instance type"
  type        = string
  default     = "mq.t3.micro"
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
