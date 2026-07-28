# tech-platform

Cross-cutting infrastructure for the Tech Challenge (Phase 4) — the pieces that don't belong to any single microservice.

| Directory | Purpose |
|---|---|
| `local/` | docker-compose booting the API gateway (Kong) and the shared Datadog Agent for local development. Every dev on the team runs the same setup. |
| `k8s/` | Kustomize manifest set for the services, the Kong ingresses and the Datadog Helm values. |
| `terraform/` | OpenTofu stack provisioning the platform: VPC, EKS, RDS, Amazon MQ, MongoDB Atlas, and the GitHub OIDC deploy role. |
| `scripts/` | `bootstrap-cluster.sh` takes a fresh stack to a working platform; `smoke-test.sh` proves it. |
| `docs/` | Architecture and database diagrams, ADRs and RFCs. |

## Documentation

| Read | For |
| --- | --- |
| [docs/](docs/) | Component and sequence diagrams, ER diagrams, ADRs, RFCs, vulnerability analysis |
| [postman/](postman/) | Collection covering the whole flow through the gateway |
| [DEPLOY.md](DEPLOY.md) | Building or rebuilding the environment |
| [DEMO.md](DEMO.md) | Walking the system as a user, or recording the demo |

## Repositories in the ecosystem

| Repo | Role |
|---|---|
| [`work-order-service`](https://github.com/tech-challenge-workshop/work-order-service) | Work-order lifecycle, master data (customers/vehicles/services), saga orchestrator. |
| [`execution-service`](https://github.com/tech-challenge-workshop/execution-service) | Parts inventory + execution queue + diagnostics. |
| [`billing-service`](https://github.com/tech-challenge-workshop/billing-service) | Quote + payment (Mercado Pago). |
| [`auth-service`](https://github.com/tech-challenge-workshop/auth-service) | Lambda that issues JWTs (CPF/CNPJ → customer; API key → admin). |
| **`tech-platform`** (this repo) | Gateway, observability, Kubernetes and AWS infrastructure. |

## Local development

### 1. Boot the shared platform

```bash
cd local
cp .env.example .env       # optionally set DD_API_KEY
docker compose up -d
```

That gives you:

- **Kong** on `http://localhost:8000` (proxy) and `http://localhost:8001` (admin, read-only inspection).
- **Datadog Agent** on `localhost:8126` (APM/traces) and `localhost:8125/udp` (dogstatsd). Every service points `DD_AGENT_HOST=localhost` at this shared agent — no need to run one per repo.

### 2. Boot each application on the host

Each service repo has its own compose for its infra (Postgres, MongoDB, RabbitMQ). Run the apps on the host with `pnpm start:dev`:

| Service | Local port |
|---|---|
| work-order-service | `3000` |
| billing-service | `3001` |
| execution-service | `3002` |
| auth-service | `3003` |

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

Kong validates the token at the edge (`jwt` plugin) and routes to the upstream service; the service's own Nest guards validate it again (defence in depth) and enforce role and ownership rules.

The complete saga walkthrough — seed data, open an order, approve the quote, run the repair — is in the [work-order-service README](https://github.com/tech-challenge-workshop/work-order-service#run-the-full-system-distributed-saga-demo).

### End-to-end validation (run 2026-07-27)

| # | Scenario | Expected | Got |
|---|---|:---:|:---:|
| 1 | `GET /work-orders` without token | 401 | 401 (blocked at Kong edge) |
| 2 | `GET /work-orders` with admin token | 200 | 200 (Kong validates, service accepts) |
| 3 | `POST /customers` with admin token | 201 | 201 (id returned) |
| 4 | `GET /customers/lookup?document=…` without token | 200 | 200 (public route, JWT bypassed) |
| 5 | `GET /work-orders/:id` with the OWNING customer's token | 200 | 200 (Nest guard allows owner) |
| 6 | `GET /work-orders/:id` with a DIFFERENT customer's token | 403 | 403 (Nest guard rejects non-owner) |
| 7 | `GET /parts/prices` without token | 200 | 200 (public, service-to-service) |
| 8 | JWT with wrong `iss` claim | 401 | 401 (Kong can't match KongConsumer) |
| 9 | JWT with wrong signature | 401 | 401 (Kong rejects HS256 verify) |

Same-shape tokens produced by hand (`{ iss: "auth-service", sub, role, exp }` signed HS256 with the shared secret) are accepted by Kong. The `auth-service` unit suite (30/30, 94.7% coverage) proves the service emits tokens with that exact shape.

## Routing table (local compose)

Declarative config in `local/kong/kong.yml`. In the cluster the same paths are
expressed as Ingress in `k8s/shared/kong/ingresses.yaml`, and `/auth` points at
the Lambda instead of a local process:

| Path | Method | Auth (Kong JWT plugin) | Upstream |
|---|---|:---:|---|
| `/auth` | POST | public | auth-service :3003 |
| `/auth/admin` | POST | public | auth-service :3003 |
| `/customers/lookup` | GET | public (service-to-service) | work-order-service :3000 |
| `/customers/*` | * | JWT | work-order-service :3000 |
| `/vehicles/*` | * | JWT | work-order-service :3000 |
| `/repair-services/*` | * | JWT | work-order-service :3000 |
| `/work-orders/*` | * | JWT | work-order-service :3000 |
| `/parts/prices` | GET | public (service-to-service) | execution-service :3002 |
| `/parts/*` | * | JWT | execution-service :3002 |
| `/executions/*` | * | JWT | execution-service :3002 |
| `/quotes/*` | * | JWT | billing-service :3001 |
| `/payments/*` | * | JWT | billing-service :3001 |

## Consumer JWT

A single `KongConsumer` (`auth-service`) represents "tokens issued by our auth service". Its JWT credential uses `key: auth-service`, HS256, and the secret shared with the services' `JWT_SECRET`. Kong matches the consumer by reading the token's `iss` claim.

**Requirement:** tokens must carry `iss: "auth-service"`. Without it Kong's JWT plugin rejects the request with `Bad token`, however valid the signature.

Locally the secret is a literal in `kong.yml`. In the cluster it comes from a Kubernetes `Secret` (`k8s/shared/kong/kong-consumer.example.yaml` shows the shape; the real file is gitignored).

## Kubernetes

`k8s/` renders to **22 resources** through Kustomize:

```
k8s/
├── namespaces/           tech-challenge namespace
├── work-order-service/   Deployment, Service, ConfigMap, HPA, migration Job
├── billing-service/      idem
├── execution-service/    Deployment, Service, ConfigMap, HPA
├── auth-service/         ExternalName only — the service is a Lambda
└── shared/
    ├── kong/             Helm values, Ingresses, KongPlugins, KongConsumer
    ├── datadog/          Helm values for the Agent
    └── metrics-server/   why it is a prerequisite
```

Each of the three in-cluster services gets a `Deployment` with liveness and
readiness probes on `/health`, a `ClusterIP` `Service`, and an `HPA` scaling on
CPU (70%) and memory (75%).

Routing is **Ingress**, not Gateway API. The Kong controller accepted the
GatewayClass but left every Gateway at `Waiting for controller`, with correct
RBAC and no error in the logs; Ingress is KIC's primary mode and needs no extra
CRDs. Private routes carry `konghq.com/plugins: jwt-hs256,rate-limit-60rpm`;
the public ones carry no JWT plugin.

Validate without a cluster:

```bash
kubectl kustomize k8s | kubeconform -summary -strict \
  -ignore-missing-schemas -schema-location default
```

CI runs exactly that on every PR touching `k8s/`. Two Kong CRDs are reported as
skipped: their schemas are not in the default store.

> **metrics-server is a prerequisite.** EKS does not ship it, and without it
> every HPA reports `cpu: <unknown>` and never scales.

### Deploy order

```bash
# 1. cluster credentials
cd terraform && make kubeconfig && cd ..

# 2. Kong Ingress Controller and the Datadog Agent (Helm)
kubectl create namespace datadog
kubectl create secret generic datadog-api --from-literal api-key="$DD_API_KEY" -n datadog
helm install kong kong/ingress -n kong --create-namespace -f k8s/shared/kong/values.yaml
helm install datadog datadog/datadog -n datadog -f k8s/shared/datadog/values.yaml

# 3. render and apply the secrets (see below)
k8s/secrets-from-tofu.sh
kubectl apply -f k8s/work-order-service/secret.yaml \
              -f k8s/billing-service/secret.yaml \
              -f k8s/execution-service/secret.yaml \
              -f k8s/auth-service/secret.yaml \
              -f k8s/shared/kong/kong-consumer.yaml

# 4. everything else
kubectl apply -k k8s
```

### Secrets

`k8s/secrets-from-tofu.sh` renders every gitignored `secret.yaml` from the
OpenTofu outputs. Database and broker credentials are read straight out of
Secrets Manager, so no connection string is ever typed by hand.

`JWT_SECRET` and `ADMIN_API_KEY` are generated on the first run and cached in
`k8s/.secrets.env` (gitignored, mode 600). Reruns reuse them — rotating either
would invalidate every issued token and desynchronise the Kong consumer
credential at the same time.

Two values the script cannot derive:

| Value | Where it goes |
|---|---|
| `MERCADO_PAGO_ACCESS_TOKEN` | export it before running the script; empty means the sandbox adapter auto-approves |
| `DD_API_KEY` | **not a service secret** — it belongs to the Datadog Agent only (step 2 above). `dd-trace` in the apps ships to the Agent over `DD_AGENT_HOST`, so no application pod ever needs the key. Locally the same key goes in `local/.env`. |

### Database TLS

RDS presents the Amazon RDS CA, which is not publicly trusted, so
work-order-service and billing-service run an init container that downloads the
bundle into `/etc/ssl/rds` and connect with `sslmode=verify-full`. Keeping it
out of the images means the same image still runs against a plain PostgreSQL
container locally.

MongoDB Atlas needs none of this — it serves a publicly trusted certificate.

## AWS infrastructure

`terraform/` is an OpenTofu stack built on `terraform-aws-modules/{vpc,eks,rds}`: a VPC across 2 AZs with one NAT gateway, EKS 1.35, one RDS PostgreSQL instance per owning service, and an Amazon MQ RabbitMQ broker for the saga. The document store is MongoDB Atlas, provisioned by the same stack — the AWS Free Plan refuses DocumentDB outright.

Full detail, cost breakdown and the destroy-when-idle workflow are in [`terraform/README.md`](terraform/README.md).

```bash
cd terraform
make validate    # offline, no credentials needed
make plan
```

## Local compose vs. cluster

The local compose is the dev-mode version of what runs on EKS. The conceptual structure — consumer, routes, plugins — is identical; only the installation and service discovery change:

| Local | Cluster |
|---|---|
| Kong compose container | Kong Ingress Controller via the `kong/ingress` Helm chart |
| declarative `kong.yml` | `Ingress` + `KongPlugin` + `KongConsumer` |
| literal secret in yaml | `KongConsumer` credential referencing a Kubernetes `Secret` |
| `host.docker.internal` | `ClusterIP` Services |
| Datadog Agent container | Datadog Agent DaemonSet (official chart) |
| Postgres / Mongo / RabbitMQ containers | RDS / MongoDB Atlas / Amazon MQ |
