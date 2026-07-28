region      = "us-east-1"
project     = "tech-challenge"
environment = "dev"

az_count = 2
vpc_cidr = "10.0.0.0/16"

kubernetes_version  = "1.35"
node_instance_types = ["t3.medium", "t3a.medium"]
node_capacity_type  = "SPOT"
node_min_size       = 2
node_max_size       = 4
node_desired_size   = 2

postgres_version           = "17.10"
postgres_instance_class    = "db.t4g.micro"
postgres_allocated_storage = 20

documentdb_version        = "5.0.1"
documentdb_instance_class = "db.t4g.medium"
documentdb_instance_count = 1

rabbitmq_version       = "4.2"
rabbitmq_instance_type = "mq.t3.micro"
rabbitmq_username      = "tech_challenge"
