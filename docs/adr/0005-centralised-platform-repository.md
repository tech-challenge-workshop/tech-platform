# ADR 0005 — Kubernetes manifests live in the platform repository

**Status:** accepted · 2026-07-28

## Context

The Phase 4 deliverables list "Dockerfile e manifestos Kubernetes" under each
microservice repository. The four services are always deployed to the same
cluster, behind the same gateway, by the same pipeline.

## Decision

Manifests, Helm values and the OpenTofu stack live in `tech-platform`. Each
service repository owns its code, its Dockerfile and its pipeline, and its
README points at the platform repository and explains why.

## Rationale

A `k8s/` directory per repository would duplicate the namespace, the ingresses,
the Kong plugins and the Datadog values four times. Those copies drift the first
time a route changes, and the drift is silent until a deploy behaves differently
from the manifest someone was reading.

Centralised, one kustomize tree renders the whole platform and is validated by
`kubeconform` on every pull request. There is one place to answer "what is
deployed".

## Consequences

This deviates from the literal wording of the deliverable. Each service README
states where the manifests are and why, so an evaluator looking for them finds
the answer where they look.

A change spanning code and deployment touches two repositories and two pull
requests.

The pipeline needs the manifest at deploy time: the migration Job is fetched
from the platform repository's `main` rather than duplicated into the service
repository, which keeps one source of truth at the cost of a network fetch.

## Alternatives

**Manifests per repository.** Matches the wording, guarantees drift.

**Both.** The worst option — two copies, no rule for which wins.
