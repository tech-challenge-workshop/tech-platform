# Architecture documentation

**[ENTREGA.md](ENTREGA.md)** — the delivery document for the portal, in Portuguese:
participants, repository links, architecture, saga strategy and the reasoning
behind the service split.

| Document | Contents |
| --- | --- |
| [architecture.md](architecture.md) | Component diagram, sequence diagrams for authentication, opening a work order and compensation, and the deployment pipeline |
| [databases.md](databases.md) | Why each store is what it is, ER diagrams, and the reasoning behind each modelling choice |
| [security.md](security.md) | Vulnerability analysis: SAST, SCA and DAST results, mapped against the OWASP Top 10 |

## Decisions

**ADRs** record architectural decisions that are expensive to reverse.

| # | Decision |
| --- | --- |
| [0001](adr/0001-orchestrated-saga.md) | Orchestrated saga, coordinator in work-order-service |
| [0002](adr/0002-messaging-over-rest.md) | Messaging between services, REST only for the price snapshot |
| [0003](adr/0003-hpa-on-cpu-and-memory.md) | Horizontal autoscaling on CPU and memory |
| [0004](adr/0004-ingress-over-gateway-api.md) | Kong routing as Ingress, not Gateway API |
| [0005](adr/0005-centralised-platform-repository.md) | Kubernetes manifests in the platform repository |
| [0006](adr/0006-clean-architecture-with-ports.md) | Clean Architecture with explicit ports |

**RFCs** record technical choices where alternatives were weighed.

| # | Topic |
| --- | --- |
| [0001](rfc/0001-cloud-and-compute.md) | Cloud provider and compute platform |
| [0002](rfc/0002-database-selection.md) | Database selection per service |
| [0003](rfc/0003-authentication.md) | Authentication strategy |

## Operational documents

| Document | Use it when |
| --- | --- |
| [../DEPLOY.md](../DEPLOY.md) | Building or rebuilding the environment, or when a deploy fails |
| [../README.md](../README.md) | Local development and the routing table |
