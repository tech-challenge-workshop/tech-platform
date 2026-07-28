# OpenTofu — AWS platform

Provisions everything the four services run on: network, Kubernetes cluster, and
the three managed data stores. The Kubernetes workloads themselves live in
[`../k8s`](../k8s) and are applied after this stack is up.

Built with [OpenTofu](https://opentofu.org). The directory keeps the `terraform/`
name and the `.tf` extension, which OpenTofu uses unchanged — only the CLI
differs (`tofu` instead of `terraform`).

## What it creates

| Layer | Resource | Notes |
| --- | --- | --- |
| Network | VPC, 2 AZs, 6 subnets, 1 NAT gateway | public / private / database tiers |
| Compute | EKS `1.35`, managed node group | 2–4 × `t3.medium` SPOT, AL2023 |
| Relational | 2 × RDS PostgreSQL `17.10` | `db.t4g.micro`, one per owning service |
| Document | DocumentDB `5.0.1` | `db.t4g.medium`, single instance |
| Messaging | Amazon MQ RabbitMQ `4.2` | `mq.t3.micro`, single instance |
| Secrets | Secrets Manager | RDS passwords are RDS-managed; DocumentDB and MQ are generated here |

`tofu plan` produces **85 resources**.

## Design decisions

**Ready-made modules, single root module.** `terraform-aws-modules/{vpc,eks,rds}`
carry the boilerplate. There is no hand-rolled `modules/` directory: with one
environment, a local module layer would be indirection without payoff.

**Database per service.** `work-order` and `billing` get separate RDS instances
rather than two schemas on one box. Neither service's credentials can reach the
other's data — the isolation that makes them independently deployable is real,
not a naming convention.

**One NAT gateway.** Worker nodes sit in private subnets and still need egress
for `ghcr.io` pulls, Datadog and Mercado Pago. One NAT is the cheapest way to
provide it. `single_nat_gateway = false` plus `one_nat_gateway_per_az = true` in
[`vpc.tf`](vpc.tf) upgrades this to an AZ-fault-tolerant setup.

**No EBS CSI driver.** Every workload is stateless; all persistence is in the
managed stores above. Skipping it removes an addon and an IRSA role.

**State in S3 with native locking.** `use_lockfile = true` replaces the legacy
DynamoDB lock table.

**No secret in state as plaintext.** RDS uses `manage_master_user_password`, so
the credential is created and rotated by RDS directly into Secrets Manager.
DocumentDB and Amazon MQ have no such feature, so those two are generated with
`random_password` and written to Secrets Manager explicitly.

## Requirements

- OpenTofu ≥ 1.11.1 — `mise install` picks up the pinned 1.12.5 from `mise.toml`
  (`terraform-aws-modules/rds` 7.x sets that floor)
- An AWS profile with administrative rights — the `Makefile` defaults to `free-tier`

## Usage

```sh
# once per account: create the S3 bucket that holds the state
make bootstrap

make init
make plan
make apply
make kubeconfig      # points the local kubeconfig at the new cluster
```

Offline checks, no credentials required:

```sh
make fmt
make validate
```

## Cost

Everything here bills **by the hour**, so the number that matters is how long
the stack stays up, not the monthly rate:

```
make cost
```

Roughly **$0.30/h**, dominated by the EKS control plane ($0.10/h) and
DocumentDB ($0.078/h). A full test-and-record session of ~30 hours costs about
$9. Left running for a month it would be ~$220 — so:

```sh
make destroy
```

Run it when you stop working. The stack is designed to be recreated from
scratch: no final snapshots, no deletion protection, no backup retention on RDS.

## Files

| File | Contents |
| --- | --- |
| `bootstrap/` | one-off stack creating the S3 state bucket |
| `versions.tf` | OpenTofu and provider constraints, S3 backend |
| `locals.tf` | naming, tags, AZ selection, the per-service database map |
| `vpc.tf` | network |
| `eks.tf` | cluster, addons, node group |
| `security-groups.tf` | data-store ingress, all sourced from the node security group |
| `rds.tf` | the two PostgreSQL instances |
| `documentdb.tf` | DocumentDB cluster and its secret |
| `mq.tf` | RabbitMQ broker and its secret |
| `outputs.tf` | endpoints and secret ARNs consumed by the K8s layer |
