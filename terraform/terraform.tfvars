region      = "us-east-1"
project     = "tech-challenge"
environment = "dev"

az_count = 2
vpc_cidr = "10.0.0.0/16"

kubernetes_version  = "1.35"
node_instance_types = ["c7i-flex.large", "m7i-flex.large"]
node_capacity_type  = "ON_DEMAND"
node_min_size       = 2
node_max_size       = 4
node_desired_size   = 2

postgres_version           = "17.10"
postgres_instance_class    = "db.t4g.micro"
postgres_allocated_storage = 20


rabbitmq_version       = "4.2"
rabbitmq_instance_type = "mq.m7g.medium"
rabbitmq_username      = "tech_challenge"
