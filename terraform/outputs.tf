output "region" {
  description = "Region every resource was created in"
  value       = var.region
}

output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "API server endpoint of the EKS cluster"
  value       = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Command that points the local kubeconfig at this cluster"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "github_actions_role_arn" {
  description = "Role the deploy workflows assume — set it as the AWS_DEPLOY_ROLE_ARN secret in each service repository"
  value       = aws_iam_role.github_actions.arn
}

output "postgres_endpoints" {
  description = "Connection endpoint of each PostgreSQL instance, keyed by service"
  value       = { for k, m in module.postgres : k => m.db_instance_endpoint }
}

output "postgres_secret_arns" {
  description = "Secrets Manager ARN holding the master credentials of each PostgreSQL instance"
  value       = { for k, m in module.postgres : k => m.db_instance_master_user_secret_arn }
}

output "mongodbatlas_secret_arn" {
  description = "Secrets Manager ARN holding the Atlas credentials and connection URI"
  value       = aws_secretsmanager_secret.mongodbatlas.arn
}

output "rabbitmq_endpoint" {
  description = "AMQPS endpoint of the Amazon MQ broker"
  value       = aws_mq_broker.rabbitmq.instances[0].endpoints[0]
}

output "rabbitmq_console_url" {
  description = "Management console URL of the Amazon MQ broker"
  value       = aws_mq_broker.rabbitmq.instances[0].console_url
}

output "rabbitmq_secret_arn" {
  description = "Secrets Manager ARN holding the RabbitMQ credentials and connection URI"
  value       = aws_secretsmanager_secret.rabbitmq.arn
}
