# ADR 0003 — Horizontal autoscaling on CPU and memory

**Status:** accepted · 2026-07-27

## Context

The workshop's load is bursty: mornings concentrate vehicle intake, and each
opened order fans out into messages across three services. The deployment has to
absorb peaks without running peak capacity all day.

## Decision

An `HorizontalPodAutoscaler` per in-cluster service, scaling on **CPU at 70%**
and **memory at 75%**, from 1 replica to 5 (3 for auth-related workloads).

## Rationale

**Both metrics, not just CPU.** The services are Node processes holding
connection pools and message buffers. A backlog on the broker grows memory well
before it shows as CPU, so a CPU-only policy would scale late on exactly the
kind of burst worth scaling for.

**70% and 75%** leave room for a new pod to start. Node images take a few
seconds to become ready, and a threshold near 90% means the existing pods are
already saturated by the time a replacement is scheduled.

**Minimum of 1, not 2.** This is a single environment that is created and
destroyed around demos; paying for idle redundancy is not worth it. Production
would set 2.

## Consequences

`metrics-server` becomes a hard dependency. EKS does not ship it, and without it
**every HPA reports `cpu: <unknown>` and never scales** — manifests that look
correct and do nothing. This was true of the cluster for its first hour, and is
why `bootstrap-cluster.sh` installs it and the README calls it out.

Scaling on memory can also mask a leak: a process that grows without bound gets
more replicas instead of an alert. The Datadog monitors cover the symptom from
the other side.

## Alternatives

**Custom metrics** (RabbitMQ queue depth) would scale on the real signal, but
needs an external metrics adapter and a Datadog or Prometheus pipeline — more
infrastructure than this workload justifies.

**Vertical autoscaling** does not help with bursts: it resizes pods, and
resizing means a restart.
