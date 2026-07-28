// Managed RabbitMQ carrying the saga messages between the three services.
// SINGLE_INSTANCE takes exactly one subnet; CLUSTER_MULTI_AZ would take all of
// them and cost three times as much.

resource "random_password" "rabbitmq" {
  length  = 32
  special = false
}

resource "aws_mq_broker" "rabbitmq" {
  broker_name = "${local.name}-rabbitmq"

  engine_type        = "RabbitMQ"
  engine_version     = var.rabbitmq_version
  host_instance_type = var.rabbitmq_instance_type
  deployment_mode    = "SINGLE_INSTANCE"

  subnet_ids          = [module.vpc.private_subnets[0]]
  security_groups     = [aws_security_group.rabbitmq.id]
  publicly_accessible = false

  auto_minor_version_upgrade = true
  apply_immediately          = true

  user {
    username = var.rabbitmq_username
    password = random_password.rabbitmq.result
  }

  logs {
    general = true
  }

  tags = local.tags
}

resource "aws_secretsmanager_secret" "rabbitmq" {
  name                    = "${local.name}/rabbitmq"
  description             = "Amazon MQ RabbitMQ credentials for the saga bus"
  recovery_window_in_days = 0

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "rabbitmq" {
  secret_id = aws_secretsmanager_secret.rabbitmq.id

  secret_string = jsonencode({
    username = var.rabbitmq_username
    password = random_password.rabbitmq.result
    endpoint = aws_mq_broker.rabbitmq.instances[0].endpoints[0]
    uri      = replace(aws_mq_broker.rabbitmq.instances[0].endpoints[0], "amqps://", "amqps://${var.rabbitmq_username}:${random_password.rabbitmq.result}@")
  })
}
