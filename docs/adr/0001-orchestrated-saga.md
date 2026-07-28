# ADR 0001 — Orchestrated saga, coordinator in work-order-service

**Status:** accepted · 2026-07-12

## Context

Opening a work order spans three services: parts are reserved in
execution-service, a quote is generated and paid in billing-service, and the
order's own status advances in work-order-service. There is no distributed
transaction available, and any step can fail.

The challenge allows either orchestration or choreography.

## Decision

Orchestration, with the coordinator in **work-order-service**.

## Rationale

**It follows data ownership.** A work order's status *is* the state of the
distributed transaction: `AWAITING_APPROVAL` means the quote step is pending,
`IN_EXECUTION` means payment cleared. work-order-service already owns that
status and its history, and no other service may write it. Putting the
coordinator elsewhere would separate the component that decides the next step
from the one that owns the state that step depends on.

**Compensation is asymmetric and central.** When execution fails we refund the
payment, cancel the quote and release the parts — in that order, and only the
steps that actually ran. Under choreography that ordering lives implicitly in
who subscribes to what, spread across three codebases. Here it is one
`compensate()` method, and `SagaInstance` records which steps completed so
nothing is undone twice or undone when it never happened.

**It is testable.** The whole transaction — happy path and four failure
branches — is exercised by replaying messages against the orchestrator, with no
broker and no database. That is only possible because the decisions live in one
place.

## Consequences

The orchestrator is a coupling point: adding a saga step means changing
work-order-service, and it is a single point of failure for coordination.

Accepted, because the alternative is debugging an emergent ordering bug across
three services. The participants stay decoupled regardless — they receive
commands and reply with events, and none knows the others exist.

## Alternatives

**Choreography.** Fewer moving parts and no central component, but the
compensation order becomes implicit in the event subscriptions. Rejected on
debuggability.

**Two-phase commit.** Not available across PostgreSQL, MongoDB and a payment
provider, and would couple availability of every service to every other.
