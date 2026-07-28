# Architecture

The system that runs, as of 2026-07-28. Diagrams are Mermaid, so they render on
GitHub and change in the same pull request as the code they describe.

## Components

```mermaid
flowchart TB
    subgraph internet[" "]
        client([Customer / Workshop])
    end

    subgraph aws["AWS · us-east-1"]
        subgraph edge["Edge"]
            nlb[Network Load Balancer]
            apigw[API Gateway]
            lambda["auth-service<br/>Lambda"]
        end

        subgraph eks["EKS · namespace tech-challenge"]
            kong[Kong Ingress Controller<br/>JWT + rate limit]
            wo[work-order-service<br/>saga orchestrator]
            ex[execution-service]
            bi[billing-service]
        end

        subgraph data["Managed data"]
            rdswo[(RDS PostgreSQL<br/>work-order)]
            rdsbi[(RDS PostgreSQL<br/>billing)]
            mq{{Amazon MQ<br/>RabbitMQ}}
        end

        subgraph obs["Observability"]
            dd[Datadog Agent<br/>DaemonSet]
        end
    end

    atlas[(MongoDB Atlas<br/>execution)]
    mp[Mercado Pago]
    ddcloud[Datadog]

    client --> nlb --> kong
    kong -->|/auth| apigw --> lambda
    lambda -->|lookup| nlb
    kong --> wo & ex & bi

    wo <--> mq
    ex <--> mq
    bi <--> mq

    wo --> rdswo
    bi --> rdsbi
    ex --> atlas
    wo -->|prices, REST| ex
    bi --> mp

    wo & ex & bi -.traces.-> dd --> ddcloud
```

Every request enters through Kong. No service is reachable from outside the
cluster, and no service reads another service's database — the only paths
between them are RabbitMQ messages and one synchronous REST call for prices.

## Opening a work order

The saga in full, including where each service writes.

```mermaid
sequenceDiagram
    autonumber
    participant C as Workshop
    participant K as Kong
    participant W as work-order
    participant E as execution
    participant B as billing
    participant Q as RabbitMQ

    C->>K: POST /work-orders (Bearer admin)
    K->>K: verify JWT
    K->>W: proxy
    W->>E: GET /parts/prices (REST)
    E-->>W: price snapshot
    W->>W: persist order · RECEIVED
    W->>Q: work-order.opened
    W-->>C: 201 { id }

    Q->>W: work-order.opened
    W->>Q: parts.reserve
    Q->>E: parts.reserve
    E->>E: available → reserved
    E->>Q: parts.reserved
    Q->>W: parts.reserved
    W->>W: IN_DIAGNOSIS
    W->>Q: quote.generate
    Q->>B: quote.generate
    B->>B: persist quote from the snapshot
    B->>Q: quote.generated
    Q->>W: quote.generated
    W->>W: AWAITING_APPROVAL
```

The order now waits. Nothing advances until the customer decides.

```mermaid
sequenceDiagram
    autonumber
    participant C as Customer
    participant K as Kong
    participant B as billing
    participant W as work-order
    participant E as execution
    participant Q as RabbitMQ

    C->>K: POST /quotes/:id/approve (Bearer customer)
    K->>B: proxy
    B->>Q: quote.approved
    Q->>W: quote.approved
    W->>Q: payment.confirm
    Q->>B: payment.confirm
    B->>B: charge via Mercado Pago
    B->>Q: payment.confirmed
    Q->>W: payment.confirmed
    W->>W: IN_EXECUTION
    W->>Q: execution.start
    Q->>E: execution.start

    Note over E: mechanic works the queue
    C->>K: POST /executions/:id/complete
    K->>E: proxy
    E->>E: reserved → consumed
    E->>Q: execution.completed
    Q->>W: execution.completed
    W->>W: FINISHED
```

## Authentication

```mermaid
sequenceDiagram
    autonumber
    participant C as Customer
    participant K as Kong
    participant A as auth-service (Lambda)
    participant W as work-order

    C->>K: POST /auth { document }
    K->>A: proxy (public route, no JWT plugin)
    A->>A: validate CPF/CNPJ check digits
    A->>K: GET /customers/lookup?document=
    K->>W: proxy (public route)
    W-->>A: 200 { id } · 404
    A-->>C: { token, expiresIn }

    Note over C,K: later requests
    C->>K: GET /work-orders/:id (Bearer)
    K->>K: jwt plugin · match consumer by iss
    K->>W: proxy
    W->>W: JwtAuthGuard + RolesGuard
    W-->>C: 200 · 403
```

The token is verified twice on purpose: Kong rejects anything unsigned at the
edge, and the service enforces role and ownership. A misrouted request never
reaches an unauthenticated handler.

`iss: "auth-service"` is not decorative — Kong matches the consumer credential
by that claim, and a token without it is rejected even with a valid signature.

## Compensation

```mermaid
flowchart LR
    A[parts reserved] --> B[quote generated]
    B --> C[payment confirmed]
    C --> D[execution started]

    D -.fails.-> R1[refund payment]
    R1 --> R2[cancel quote]
    R2 --> R3[release parts]
    R3 --> R4[order CANCELLED]

    C -.fails.-> R2
    B -.fails.-> R3
    A -.fails.-> R4
```

Compensation runs in reverse and only undoes steps that happened. `SagaInstance`
records which ones did, so a reservation failure cancels the order without
refunding a payment that was never taken. The branches are specified as
executable scenarios in
[work-order-service's feature file](https://github.com/tech-challenge-workshop/work-order-service/blob/main/tests/bdd/features/work-order-saga.feature).

## Deployment pipeline

```mermaid
flowchart LR
    push[push to main] --> build[build]
    build --> test["unit + e2e<br/>80% gate"]
    test --> bdd[BDD scenarios]
    bdd --> sonar[SonarCloud]
    sonar --> img["image → GHCR<br/>main + SHA"]
    img --> oidc[assume role via OIDC]
    oidc --> mig[migration Job]
    mig --> roll["kubectl set image<br/>+ rollout status"]

    mig -.fails.-> stop([release stops])
```

The rollout is pinned to the commit SHA, not to a mutable tag, so "redeploy the
previous version" names exactly one commit. `rollout status` fails the job if
the new pods never become ready.
