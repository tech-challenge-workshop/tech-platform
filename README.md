# tech-platform

Cross-cutting infrastructure for the Tech Challenge (Phase 4) — the pieces that don't belong to any single microservice.

| Directory | Purpose |
|---|---|
| `local/` | docker-compose that boots the API gateway (Kong) and the shared Datadog Agent for local development. Every dev in the team uses the same setup. |
| `k8s/` | (upcoming) Helm values for the Kong Ingress Controller and manifest set (`HTTPRoute`, `KongPlugin`, `KongConsumer`) for the EKS environment. |

## Repositories in the ecosystem

| Repo | Role |
|---|---|
| [`work-order-service`](https://github.com/tech-challenge-workshop/work-order-service) | Work-order lifecycle, master data (customers/vehicles/services), saga orchestrator. |
| [`execution-service`](https://github.com/tech-challenge-workshop/execution-service) | Parts inventory + execution queue + diagnostics. |
| [`billing-service`](https://github.com/tech-challenge-workshop/billing-service) | Quote + payment (Mercado Pago). |
| [`auth-service`](https://github.com/tech-challenge-workshop/auth-service) | Serverless Framework Lambda that issues JWTs (CPF/CNPJ → customer; API key → admin). |
| **`tech-platform`** (this repo) | Gateway (Kong) + observability + shared infra. |

## Local development

### 1. Boot the shared platform

```bash
cd local
cp .env.example .env       # optionally set DD_API_KEY
docker compose up -d
```

That gives you:

- **Kong** on `http://localhost:8000` (proxy) and `http://localhost:8001` (admin, read-only inspection).
- **Datadog Agent** on `localhost:8126` (APM/traces) and `localhost:8125/udp` (dogstatsd). Every service in the team points `DD_AGENT_HOST=localhost` at this shared agent — no need to run one per repo.

### 2. Boot each application on the host

Each service repo has its own compose for its infra (Postgres, MongoDB, RabbitMQ). Run the apps on the host with `pnpm start:dev`:

| Service | Local port |
|---|---|
| work-order-service | `3000` |
| billing-service | `3001` |
| execution-service | `3002` |
| auth-service (`serverless offline`) | `3003` |

Kong reaches all four via `host.docker.internal` (`extra_hosts` in the compose maps it to `host-gateway` on Linux).

### 3. Try the full flow through Kong

Login as customer:

```bash
curl -s -X POST http://localhost:8000/auth \
  -H 'content-type: application/json' \
  -d '{"document":"39053344705"}'
# {"token":"eyJ...","expiresIn":86400}
```

Login as admin:

```bash
curl -s -X POST http://localhost:8000/auth/admin \
  -H "X-Api-Key: $ADMIN_API_KEY"
```

Call a protected route through Kong:

```bash
TOKEN="eyJ..."   # from the login above
curl -s http://localhost:8000/work-orders/<id> \
  -H "Authorization: Bearer $TOKEN"
```

Kong validates the token at the edge (`jwt` plugin), routes to the upstream service; the service's own Nest guards validate the token again (defence in depth) and enforce role/ownership rules.

## Routing table (Kong → services)

Config declarative em `local/kong/kong.yml`. Resumo:

| Path | Método | Auth (Kong JWT plugin) | Upstream |
|---|---|:---:|---|
| `/auth` | POST | ❌ público | auth-service :3003 |
| `/auth/admin` | POST | ❌ público | auth-service :3003 |
| `/customers/lookup` | GET | ❌ público (service-to-service) | work-order-service :3000 |
| `/customers/*` | * | ✅ JWT | work-order-service :3000 |
| `/vehicles/*` | * | ✅ JWT | work-order-service :3000 |
| `/repair-services/*` | * | ✅ JWT | work-order-service :3000 |
| `/work-orders/*` | * | ✅ JWT | work-order-service :3000 |
| `/parts/prices` | GET | ❌ público (service-to-service) | execution-service :3002 |
| `/parts/*` | * | ✅ JWT | execution-service :3002 |
| `/executions/*` | * | ✅ JWT | execution-service :3002 |
| `/quotes/*` | * | ✅ JWT | billing-service :3001 |
| `/payments/*` | * | ✅ JWT | billing-service :3001 |

## Consumer JWT

Um único `KongConsumer` (`auth-service`) representa "tokens emitidos pela nossa Lambda". A credential JWT tem `key: auth-service`, HS256, secret compartilhado com `JWT_SECRET` dos serviços. O Kong casa o consumer olhando o claim `iss` do token.

**Requer:** os tokens emitidos pelo `auth-service` precisam trazer `iss: "auth-service"` na assinatura. Sem isso, o plugin JWT do Kong rejeita o token com `Bad token`.

## Notes for production (EKS)

O compose local é o "modo dev" do que vai virar `Helm chart` + manifestos K8s no `k8s/` deste repo:

- Kong compose container → Kong Ingress Controller (KIC) via Helm chart `kong/ingress`.
- `kong.yml` declarativo → `HTTPRoute` + `KongPlugin` + `KongConsumer` (Gateway API + CRDs).
- Secret literal no yaml → `KongConsumer` credential referenciando um `Secret` do Kubernetes (idealmente vindo de AWS Secrets Manager via External Secrets Operator).
- `host.docker.internal` → `ClusterIP` Service dos apps.
- Datadog Agent como container → DaemonSet do Datadog Agent (chart oficial).

O ganho é que a estrutura conceitual (consumer + rotas + plugins) permanece a mesma; só muda como o Kong é instalado e como ele conhece os backends.
