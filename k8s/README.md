# Kubernetes manifests — Tech Challenge (Phase 4)

Single-environment deployment for EKS (also works on any Kubernetes cluster with the Kong Ingress Controller + Datadog Agent installed).

## Layout

```
k8s/
├── namespaces/tech-challenge.yaml
├── shared/
│   ├── kong/               ← Helm values + Gateway API + KongPlugin + KongConsumer
│   └── datadog/            ← Helm values for the datadog-agent DaemonSet
├── work-order-service/     ← configmap + deployment + service + hpa + secret.example
├── execution-service/      ← same structure
├── billing-service/        ← same structure
├── auth-service/           ← same structure (container, not Lambda)
└── kustomization.yaml      ← root — `kubectl apply -k .` deploys everything
```

## Deploy order (once per cluster)

**1. Install Kong Ingress Controller (Helm)**

```bash
helm repo add kong https://charts.konghq.com && helm repo update
helm install kong kong/ingress -n kong --create-namespace -f shared/kong/values.yaml
kubectl apply -f shared/kong/gateway.yaml   # Gateway CR that HTTPRoutes bind to
```

**2. Install Datadog Agent (Helm)**

```bash
helm repo add datadog https://helm.datadoghq.com && helm repo update
kubectl create namespace datadog
kubectl create secret generic datadog-api -n datadog --from-literal api-key="$DD_API_KEY"
helm install datadog datadog/datadog -n datadog -f shared/datadog/values.yaml
```

**3. Provision backing services**

Terraform provisions RDS (Postgres for work-order + billing), DocumentDB or Mongo Atlas (execution), and Amazon MQ (RabbitMQ). See `tech-database/terraform/` — endpoints go into the per-service `Secret`.

For a quick dev cluster, install in-cluster charts: `bitnami/postgresql`, `bitnami/mongodb`, `bitnami/rabbitmq`.

## Deploy the applications

**1. Fill in the secrets (never commit these)**

```bash
for svc in work-order-service billing-service execution-service auth-service; do
  cp $svc/secret.example.yaml $svc/secret.yaml
  # edit $svc/secret.yaml with real DATABASE_URL / JWT_SECRET / DD_API_KEY / etc
  kubectl apply -f $svc/secret.yaml
done
```

**2. Fill in the Kong JWT credential secret**

```bash
cp shared/kong/kong-consumer.example.yaml shared/kong/kong-consumer.yaml
# edit secret value with the same JWT_SECRET used by the services
kubectl apply -f shared/kong/kong-consumer.yaml
```

**3. Apply everything else**

```bash
kubectl apply -k .
```

## Routing table (edge → service)

Same policy as `../local/kong/kong.yml` — Kong validates JWT at the edge, Nest guards re-validate + enforce role/ownership.

| Path | Method | JWT at edge? | Upstream |
|---|---|:---:|---|
| `POST /auth` · `POST /auth/admin` | POST | ❌ public | `auth-service:3003` |
| `GET /customers/lookup` | GET | ❌ public | `work-order-service:3000` |
| `/customers/*` · `/vehicles/*` · `/repair-services/*` · `/work-orders/*` | * | ✅ | `work-order-service:3000` |
| `GET /parts/prices` | GET | ❌ public | `execution-service:3002` |
| `/parts/*` · `/executions/*` | * | ✅ | `execution-service:3002` |
| `/quotes/*` · `/payments/*` | * | ✅ | `billing-service:3001` |

Rate limit `60/min` (per Kong node) on every JWT route.

## Validation locally

Without needing a real cluster:

```bash
# render everything, count resources
kubectl kustomize . | grep -c '^kind:'

# schema validation against upstream K8s + skip Kong CRDs
kubectl kustomize . | kubeconform -summary -strict \
  -ignore-missing-schemas -schema-location default
```

Expected: 26 resources total, 17 valid (standard K8s types), 9 skipped (Gateway API + Kong CRDs — no offline schemas), 0 errors.

## What's NOT here yet

- `PodDisruptionBudget` — nice-to-have; add if you want stricter voluntary-disruption guarantees.
- `NetworkPolicy` — for cluster-wide east-west traffic restriction; requires the CNI to support it (EKS with VPC CNI does).
- Multi-env overlays (`overlays/qa`, `overlays/staging`, `overlays/prod`) — single env for this deliverable; add later if promotion is needed.
- Real `terraform apply` for RDS/DocumentDB/etc — happens in `tech-database`.
