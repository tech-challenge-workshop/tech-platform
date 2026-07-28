AWS_PROFILE ?= free-tier
export AWS_PROFILE

.PHONY: bootstrap init fmt validate plan apply destroy kubeconfig cost

## Create the S3 state bucket. Run once, ever.
bootstrap:
	cd bootstrap && tofu init && tofu apply

init:
	tofu init

## Offline checks: no AWS credentials and no state bucket required.
fmt:
	tofu fmt -recursive -check -diff

validate:
	tofu init -backend=false -upgrade
	tofu validate

plan:
	tofu plan -out=tfplan

apply:
	tofu apply tfplan

## The cluster bills by the hour. Destroy it when you stop working.
destroy:
	tofu destroy

kubeconfig:
	aws eks update-kubeconfig --region $$(tofu output -raw region) --name $$(tofu output -raw cluster_name)

cost:
	@echo "Hourly burn while this stack is up:"
	@echo "  EKS control plane      \$$0.100/h"
	@echo "  DocumentDB t4g.medium  \$$0.078/h"
	@echo "  NAT gateway            \$$0.045/h  (+ \$$0.045/GB processed)"
	@echo "  2x RDS db.t4g.micro    \$$0.032/h"
	@echo "  2x t3.medium SPOT      \$$0.025/h  (approx, varies)"
	@echo "  Amazon MQ mq.t3.micro  \$$0.020/h"
	@echo "  ------------------------------"
	@echo "  Total                  ~\$$0.30/h  (~\$$7.20/day if left running)"
