provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

# Declared explicitly so the provider is configured even though every attribute
# comes from the environment: MONGODB_ATLAS_PUBLIC_KEY and
# MONGODB_ATLAS_PRIVATE_KEY. Without the block OpenTofu reports "with no
# configuration" and the calls go out unauthenticated, surfacing as a 401.
provider "mongodbatlas" {}
