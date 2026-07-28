// One PostgreSQL instance per owning service. The master password is generated
// and rotated by RDS itself into Secrets Manager (manage_master_user_password),
// so no credential ever passes through the Terraform state as plaintext.

module "postgres" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 7.2"

  for_each = local.postgres_databases

  identifier = "${local.name}-${each.key}"

  engine               = "postgres"
  engine_version       = var.postgres_version
  family               = "postgres${split(".", var.postgres_version)[0]}"
  major_engine_version = split(".", var.postgres_version)[0]
  instance_class       = var.postgres_instance_class

  allocated_storage = var.postgres_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name                     = each.value.database
  username                    = each.value.username
  manage_master_user_password = true
  port                        = 5432

  multi_az               = false
  create_db_subnet_group = false
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.postgres.id]

  # Ephemeral environment: no backups to pay for, no snapshot blocking destroy.
  backup_retention_period     = 0
  skip_final_snapshot         = true
  deletion_protection         = false
  create_cloudwatch_log_group = false
  create_monitoring_role      = false

  tags = merge(local.tags, { Service = each.key })
}
