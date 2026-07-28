# ADR 0002 — Asynchronous messaging between services, REST only for the price snapshot

**Status:** accepted · 2026-07-14

## Context

Services need to exchange information. The saga steps are inherently
event-driven, but opening a work order also needs part prices from
execution-service *before* the order can be persisted.

## Decision

All saga communication goes through a RabbitMQ topic exchange (`saga`). One
synchronous REST call remains: `GET /parts/prices` while opening an order.

## Rationale

**Messaging for the saga.** Each step is a fact that already happened
(`parts.reserved`) or a command to act (`quote.generate`). Neither caller needs
an answer within the request, and a participant being briefly down must not fail
the transaction — the broker holds the message. Handlers are idempotent because
redelivery is normal, not exceptional.

**REST for the price snapshot.** The order cannot be persisted without prices,
so the caller genuinely blocks on the answer. Modelling it as a request/reply
over the broker would mean correlation ids and a timeout for something HTTP does
natively.

The prices are then **copied into the order** as a snapshot. After that moment
no service depends on another's live data: billing computes the quote from what
was recorded, so a later catalogue change cannot rewrite history.

## Consequences

Opening a work order fails if execution-service is unreachable. That is the
correct behaviour — an order with no prices is not an order.

Everything else survives a participant being down, at the cost of eventual
consistency: for a second or two the order is `RECEIVED` while parts are already
reserved.

## Alternatives

**REST everywhere.** Simpler to trace, but a failed step leaves the caller
holding a half-finished transaction, and every service must be up at once.

**Messaging everywhere**, including prices. Would need request/reply plumbing to
answer a question HTTP already answers.
