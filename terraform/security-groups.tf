// Every data store accepts traffic from the EKS worker nodes only. There is no
// path from the internet, and no path between the data stores themselves.

resource "aws_security_group" "postgres" {
  name        = "${local.name}-postgres"
  description = "PostgreSQL access from the EKS worker nodes"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.tags, { Name = "${local.name}-postgres" })
}

resource "aws_vpc_security_group_ingress_rule" "postgres_from_nodes" {
  security_group_id            = aws_security_group.postgres.id
  description                  = "PostgreSQL from EKS worker nodes"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.eks.node_security_group_id
}

resource "aws_security_group" "documentdb" {
  name        = "${local.name}-documentdb"
  description = "DocumentDB access from the EKS worker nodes"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.tags, { Name = "${local.name}-documentdb" })
}

resource "aws_vpc_security_group_ingress_rule" "documentdb_from_nodes" {
  security_group_id            = aws_security_group.documentdb.id
  description                  = "DocumentDB from EKS worker nodes"
  from_port                    = 27017
  to_port                      = 27017
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.eks.node_security_group_id
}

resource "aws_security_group" "rabbitmq" {
  name        = "${local.name}-rabbitmq"
  description = "Amazon MQ access from the EKS worker nodes"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.tags, { Name = "${local.name}-rabbitmq" })
}

resource "aws_vpc_security_group_ingress_rule" "rabbitmq_amqps_from_nodes" {
  security_group_id            = aws_security_group.rabbitmq.id
  description                  = "AMQPS from EKS worker nodes"
  from_port                    = 5671
  to_port                      = 5671
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.eks.node_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "rabbitmq_console_from_nodes" {
  security_group_id            = aws_security_group.rabbitmq.id
  description                  = "Management console from EKS worker nodes"
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.eks.node_security_group_id
}
