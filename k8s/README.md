# Kubernetes manifests

Everything that runs in the cluster. Rendered with Kustomize, validated with
`kubeconform` on every pull request.

```
k8s/
├── namespaces/             tech-challenge namespace
├── work-order-service/     Deployment, Service, ConfigMap, HPA, migration Job
├── billing-service/        idem
├── execution-service/      Deployment, Service, ConfigMap, HPA
├── auth-service/           ExternalName only — the service is a Lambda
├── shared/
│   ├── kong/               Helm values, Ingresses, KongPlugins, KongConsumer
│   ├── datadog/            Helm values for the Agent
│   └── metrics-server/     why it is a prerequisite
└── secrets-from-tofu.sh    renders every secret from the OpenTofu outputs
```

`kubectl kustomize .` renders **22 resources**: 6 Ingresses, 4 Services,
3 Deployments, 3 ConfigMaps, 3 HPAs, 2 KongPlugins and the Namespace.

Three things are deliberately **not** in the kustomization:

| Excluded | Why |
| --- | --- |
| `secret.yaml`, `kong-consumer.yaml`, `ghcr-pull-secret.yaml` | generated from the OpenTofu outputs, never committed |
| `migration-job.yaml` | belongs to a release, not to the desired state — the pipeline applies it |
| Kong and Datadog | installed with Helm; only their values live here |

## Routing

Kong routes by path, expressed as **Ingress** rather than Gateway API: the Kong
controller accepted the GatewayClass but left every Gateway at
`Waiting for controller`, with correct RBAC and no error in the logs. Ingress is
KIC's primary mode, needs no extra CRDs and expresses the same routing.

| Path | Auth | Upstream |
| --- | :---: | --- |
| `POST /auth`, `/auth/admin` | public | API Gateway → Lambda |
| `GET /customers/lookup` | public | work-order-service |
| `GET /parts/prices` | public | execution-service |
| `/customers`, `/vehicles`, `/repair-services`, `/work-orders` | JWT | work-order-service |
| `/parts`, `/executions` | JWT | execution-service |
| `/quotes`, `/payments` | JWT | billing-service |

Private routes carry `konghq.com/plugins: jwt-hs256,rate-limit-60rpm`. Paths are
never stripped — the services expect the path they publish.

The two public service-to-service routes are public because they are called
before a token exists in that flow: `auth-service` checks that a customer exists
before issuing one, and `work-order-service` snapshots part prices while opening
an order. Neither returns anything sensitive.

`/auth` additionally sets `konghq.com/preserve-host: "false"`. API Gateway
rejects any Host that is not its own `execute-api` domain, so forwarding the
load balancer's hostname returns 403 before the Lambda is ever invoked.

## Prerequisite the charts do not install

```sh
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.2/components.yaml
```

Without it every HPA reports `cpu: <unknown>` and never scales — the manifests
look correct and do nothing. See [`shared/metrics-server`](shared/metrics-server).

## Connectivity details worth knowing

**RDS TLS.** work-order-service and billing-service run an init container that
downloads the Amazon RDS CA bundle into `/etc/ssl/rds`, and connect with
`sslmode=verify-full`. Without it the handshake fails with "self-signed
certificate in certificate chain". Keeping the bundle out of the image means the
same image still runs against a plain PostgreSQL container locally.

**Private images.** The GHCR packages are private, so every pod references the
`ghcr-pull` secret. An expired token surfaces as `ImagePullBackOff` with empty
pod logs, because no container ever starts.

**Datadog.** `DD_AGENT_HOST` comes from `status.hostIP`, not a service name, so
each pod talks to the Agent on its own node.

## Applying

The whole sequence, including Helm and the prerequisite above, is
[`../scripts/bootstrap-cluster.sh`](../scripts/bootstrap-cluster.sh). By hand:

```sh
kubectl apply -f namespaces/tech-challenge.yaml
export GHCR_PAT=ghp_...
./secrets-from-tofu.sh
kubectl apply -f ghcr-pull-secret.yaml \
              -f work-order-service/secret.yaml \
              -f billing-service/secret.yaml \
              -f execution-service/secret.yaml \
              -f shared/kong/kong-consumer.yaml
kubectl apply -k .
```

Migrations are applied by the deploy pipeline, which recreates the Job against
the image of that release and waits for it before rolling out.

## Validating without a cluster

```sh
kubectl kustomize . | kubeconform -summary -strict \
  -ignore-missing-schemas -schema-location default
```

Expected: 22 resources, 20 valid, 2 skipped (the Kong CRDs have no offline
schema), 0 errors.
