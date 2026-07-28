// MongoDB Atlas replaces Amazon DocumentDB, which the AWS Free Plan refuses to
// provision. Atlas is still a managed cloud database declared as code, so the
// requirement is met in full — and the M0 tier costs nothing, which leaves the
// whole $200 credit for the rest of the platform.
//
// Credentials come from MONGODB_ATLAS_PUBLIC_KEY and MONGODB_ATLAS_PRIVATE_KEY
// in the environment, so no key reaches a tfvars file or the state.

resource "mongodbatlas_project" "main" {
  name   = local.name
  org_id = var.mongodbatlas_org_id
}

resource "mongodbatlas_cluster" "main" {
  project_id = mongodbatlas_project.main.id
  name       = var.mongodbatlas_cluster_name

  provider_name               = "TENANT"
  backing_provider_name       = "AWS"
  provider_region_name        = var.mongodbatlas_region
  provider_instance_size_name = "M0"
}

resource "random_password" "mongodbatlas" {
  length  = 32
  special = false
}

resource "mongodbatlas_database_user" "execution" {
  project_id         = mongodbatlas_project.main.id
  username           = "execution"
  password           = random_password.mongodbatlas.result
  auth_database_name = "admin"

  roles {
    role_name     = "readWrite"
    database_name = "execution"
  }
}

// Every pod leaves the VPC through the single NAT gateway, so the cluster has
// exactly one egress address. Allowing that one address is what keeps an M0
// cluster — which has no VPC peering on the free tier — effectively private.
resource "mongodbatlas_project_ip_access_list" "nat" {
  project_id = mongodbatlas_project.main.id
  ip_address = module.vpc.nat_public_ips[0]
  comment    = "EKS egress via the NAT gateway"
}

resource "aws_secretsmanager_secret" "mongodbatlas" {
  name                    = "${local.name}/mongodbatlas"
  description             = "MongoDB Atlas credentials for execution-service"
  recovery_window_in_days = 0

  tags = local.tags
}

locals {
  # srv_address arrives as mongodb+srv://<host>, with no credentials and no
  # database, so both are spliced in here.
  atlas_host = replace(mongodbatlas_cluster.main.srv_address, "mongodb+srv://", "")

  atlas_uri = join("", [
    "mongodb+srv://",
    mongodbatlas_database_user.execution.username,
    ":",
    random_password.mongodbatlas.result,
    "@",
    local.atlas_host,
    "/execution?retryWrites=true&w=majority",
  ])
}

resource "aws_secretsmanager_secret_version" "mongodbatlas" {
  secret_id = aws_secretsmanager_secret.mongodbatlas.id

  secret_string = jsonencode({
    username = mongodbatlas_database_user.execution.username
    password = random_password.mongodbatlas.result
    host     = local.atlas_host
    uri      = local.atlas_uri
  })
}
