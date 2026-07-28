# RFC 0002 — Database selection per service

**Status:** implemented · 2026-07-28

## Problem

Each service owns its data. The challenge requires at least one relational and
at least one non-relational store, both managed in the cloud and provisioned as
code.

## Analysis by service

### work-order-service

Customers own vehicles; work orders reference both and have items and a status
history. Those relationships are traversed on every read and must hold —
referential integrity is the point, not a nicety. Status transitions write the
order and append to its history in one unit, and the average execution-time
metric is derived entirely from that history.

**Relational. PostgreSQL on RDS.**

### billing-service

Quotes and payments: small, fixed-shape records with exact integer amounts and
a short state machine. Low volume, no variability.

**Relational. PostgreSQL on RDS.** Consistent with work-order, one less
technology to operate.

### execution-service

Diagnostics are free-form. A brake inspection records pad thickness, an
electrical fault records resistance readings, and next month someone records
something nobody anticipated. Relationally that is a column per finding, a
key-value side table, or a JSON column — and the third is a document store with
extra steps.

Executions are read as whole aggregates: the execution with all its
diagnostics, always together.

**Document store. MongoDB.**

## Managed service options for MongoDB

**A. Amazon DocumentDB.** In-VPC, one AWS account, one Terraform provider. The
Free Plan refuses it:

```
FreeTierRestrictionError: The specified cluster engine type is not available
with free plan accounts. Available engine types: [aurora-postgresql]
```

Its smallest instance is also `db.t4g.medium` at $0.078/h.

**B. MongoDB Atlas M0.** Free permanently, genuinely managed, official Terraform
provider. Costs: an external account, and network access controlled by an IP
allow list rather than VPC peering (peering is not available on the free tier).

**C. MongoDB in-cluster as a StatefulSet.** Free and inside the VPC, but not a
managed cloud database — it fails the requirement, and someone has to operate it.

**D. Upgrade the account to a paid plan** and use DocumentDB. Keeps the design
intact and removes the spend ceiling that protects the project.

## Decision

**Option B, Atlas M0.**

The requirement is a *managed cloud database provisioned as code*, and Atlas is
all three. It costs nothing, which leaves the entire credit for the compute
that does have to be paid for.

The IP allow list turns out to fit the architecture: the cluster has a **single
NAT gateway**, so every pod leaves through one stable address. One entry in the
allow list makes the database reachable from the workloads and from nowhere
else — the same isolation VPC peering would provide.

## Consequences

One more provider and one more credential in the stack. `MONGODB_ATLAS_PUBLIC_KEY`
and `MONGODB_ATLAS_PRIVATE_KEY` are read from the environment by the provider,
so no key reaches a tfvars file or the state.

Atlas API keys enforce their own IP access list. A `401 Unauthorized` during
`tofu apply` is almost always the caller's IP missing from it, not a bad key —
noted in [`DEPLOY.md`](../../DEPLOY.md) because the message does not say so.

Recreating the environment recreates the Atlas project and cluster, so
execution data does not survive a `destroy`. Acceptable: neither does the RDS
data, and the environment is ephemeral by design.

## Related

Schemas, relationships and the reasoning behind each modelling choice are in
[`databases.md`](../databases.md).
