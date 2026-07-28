# RFC 0001 — Cloud provider and compute platform

**Status:** implemented · 2026-07-28

## Problem

Four services need somewhere to run, with managed databases, managed messaging,
and a spend ceiling appropriate to a student project.

## Constraints

- Free choice of cloud, per the challenge
- A previous phase already used AWS, so accounts and familiarity exist
- The budget is the account's **$200 credit**, and it must not be exceeded
- The environment is created and destroyed around demos, not run continuously

## Options

**A. AWS + EKS.** Managed Kubernetes, RDS, Amazon MQ, Lambda, all in one
account. Control plane costs $0.10/h whether or not anything runs on it.

**B. AWS + ECS Fargate.** No control plane charge, pay per task. But the
challenge explicitly requires Kubernetes manifests and an HPA — Fargate would
mean not meeting the requirement.

**C. GCP + GKE Autopilot.** No control plane charge on the free tier, and
autoscaling is simpler. New account, new credits, and every other phase's work
would not carry over.

**D. Local Kubernetes** (kind, k3s). Free, but nothing about managed databases,
load balancers or cloud IAM would be exercised, and the challenge asks for
managed cloud databases.

## Decision

**Option A.** The requirement names Kubernetes, and the account and credits
already exist.

## Consequences and mitigation

The EKS control plane bills whether idle or not, so the environment is treated
as **ephemeral**: `make apply` before working, `make destroy` after. At roughly
$0.43/h the full stack costs about $10/day, and a test-and-record session is
under $15.

`scripts/bootstrap-cluster.sh` exists to make that cycle cheap — it takes a
fresh stack to a working platform in about eight minutes, so destroying is not
a decision to agonise over.

## What the AWS Free Plan changed

The account is on the new Free Tier's **Free Plan**, which restricts which
services and instance types may be used. Two design choices were forced:

- **DocumentDB is unavailable outright** (`FreeTierRestrictionError`), so the
  document store is MongoDB Atlas — see [RFC 0002](0002-database-selection.md)
- **`t3.medium` is not free-tier eligible**, and a node group asking for it hangs
  in `CREATING` for twenty minutes with an empty health list. The reason appears
  only in the Auto Scaling group's scaling activities. Nodes are
  `c7i-flex.large`, which is eligible and larger

Both are recorded in [`DEPLOY.md`](../../DEPLOY.md), because neither failure
explains itself.
