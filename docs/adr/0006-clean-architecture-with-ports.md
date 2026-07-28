# ADR 0006 — Clean Architecture with explicit ports in every service

**Status:** accepted · 2026-07-10

## Context

Three services, each with a database, a message broker, an HTTP API and at least
one external integration. The challenge requires Clean Architecture or Hexagonal
and a ubiquitous language.

## Decision

Four layers per bounded context, with dependencies pointing inward:

```
domain/        entities, value objects, business rules — no framework
application/   use cases and the ports they depend on
presentation/  HTTP controllers, DTOs, message subscribers
infra/         port implementations: repositories, gateways, publishers
```

Use cases receive dependencies through injection tokens for ports, never
concrete adapters. DTOs never cross into `application`.

## Rationale

**The rules are the asset.** CPF and CNPJ check digits, the status machine, the
reservation arithmetic — none of it should know that Prisma or RabbitMQ exist.
Domain and application are tested with fakes, in milliseconds, with no
container running.

**Ports made real substitutions possible**, repeatedly and cheaply:

- `PaymentGateway` — a sandbox adapter auto-approves without Mercado Pago
  credentials, so the whole saga runs locally
- `NotificationPort` — currently a structured-log adapter; swapping in e-mail is
  one class
- `TracingPort` — Datadog behind an interface, so the orchestrator is not
  importing `dd-trace`
- `MetricsPort` — added later for the business metrics without touching a use
  case

**It is what made the BDD suite possible.** Six Cucumber scenarios drive the
real orchestrator through the entire distributed transaction using in-memory
fakes — no broker, no database, 0.2 seconds. That only works because the
orchestrator depends on ports.

## Consequences

More files and more indirection than a layered CRUD service. A repository is an
interface in `application` and a class in `infra`, and adding an operation
touches both.

Accepted: the cost is per-operation and small, the benefit shows every time an
adapter has to change.

## Alternatives

**Layered with direct ORM access in services.** Fewer files, but the domain
becomes untestable without a database, and the sandbox payment adapter and the
in-memory saga tests would not exist.
