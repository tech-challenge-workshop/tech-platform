// MongoDB-compatible store for execution-service. DocumentDB has no managed
// master password, so the credential is generated here and pushed to Secrets
// Manager, which is what External Secrets reads from inside the cluster.

resource "random_password" "documentdb" {
  length  = 32
  special = false
}

resource "aws_docdb_subnet_group" "main" {
  name       = "${local.name}-documentdb"
  subnet_ids = module.vpc.database_subnets

  tags = local.tags
}

resource "aws_docdb_cluster" "main" {
  cluster_identifier = "${local.name}-documentdb"
  engine             = "docdb"
  engine_version     = var.documentdb_version

  master_username = "execution"
  master_password = random_password.documentdb.result

  db_subnet_group_name   = aws_docdb_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.documentdb.id]
  port                   = 27017

  storage_encrypted = true

  backup_retention_period = 1
  preferred_backup_window = "03:00-04:00"
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  tags = local.tags
}

resource "aws_docdb_cluster_instance" "main" {
  count = var.documentdb_instance_count

  identifier         = "${local.name}-documentdb-${count.index}"
  cluster_identifier = aws_docdb_cluster.main.id
  instance_class     = var.documentdb_instance_class

  tags = local.tags
}

resource "aws_secretsmanager_secret" "documentdb" {
  name                    = "${local.name}/documentdb"
  description             = "DocumentDB credentials for execution-service"
  recovery_window_in_days = 0

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "documentdb" {
  secret_id = aws_secretsmanager_secret.documentdb.id

  secret_string = jsonencode({
    username = aws_docdb_cluster.main.master_username
    password = random_password.documentdb.result
    host     = aws_docdb_cluster.main.endpoint
    port     = aws_docdb_cluster.main.port
    # tlsCAFile points at the bundle the execution-service pod's init container
    # downloads: DocumentDB's CA is not in the public trust store.
    uri = "mongodb://${aws_docdb_cluster.main.master_username}:${random_password.documentdb.result}@${aws_docdb_cluster.main.endpoint}:${aws_docdb_cluster.main.port}/execution?tls=true&tlsCAFile=/etc/ssl/docdb/global-bundle.pem&replicaSet=rs0&retryWrites=false&authSource=admin"
  })
}
