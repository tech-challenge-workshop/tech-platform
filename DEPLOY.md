# Deploy runbook

Everything needed to take the platform from an empty AWS account to a working
cluster running the four services, and to tear it back down.

Written after doing it for real on 2026-07-28. Every "gotcha" below is
something that actually broke during that run — not a hypothetical.

---

## Before you start

| Requirement | Notes |
| --- | --- |
| AWS account with credentials | profile `free-tier` by default; see the Free Plan warning below |
| `mise` | installs the pinned OpenTofu from `terraform/mise.toml` |
| `kubectl`, `helm`, `jq`, `aws` | |
| GHCR token | classic, scope `read:packages` only — the packages are private |
| MongoDB Atlas API key | organisation key with **Project Creator**, plus your IP in its API Access List |
| Datadog API key | in `local/.env` |

### The AWS Free Plan restricts services and instance types

The new Free Tier has a **Free Plan** and a **Paid Plan**. On the Free Plan any
resource outside the free-tier-eligible list is rejected, sometimes with a clear
error and sometimes by hanging:

- **DocumentDB is unavailable entirely** — `FreeTierRestrictionError: the
  specified cluster engine type is not available with free plan accounts`. This
  is why the document store is MongoDB Atlas.
- **EC2 instance types are filtered.** A node group asking for `t3.medium`
  never launches: the ASG retries silently and the node group sits in
  `CREATING` for 20+ minutes with an empty health issue list. The reason is only
  visible in the ASG's scaling activities.

Check what the account allows:

```sh
aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true \
  --query 'InstanceTypes[*].{type:InstanceType,vcpu:VCpuInfo.DefaultVCpus,memMiB:MemoryInfo.SizeInMiB}' \
  --output table
```

`c7i-flex.large` (2 vCPU / 4 GiB) and `m7i-flex.large` (2 vCPU / 8 GiB) are both
eligible and larger than the `t3.medium` that is not.

---

## 1. State bucket — once per account

```sh
cd terraform
export AWS_PROFILE=free-tier
make bootstrap
```

Creates a versioned, encrypted, private S3 bucket. Costs nothing while empty.

## 2. Infrastructure

```sh
export MONGODB_ATLAS_PUBLIC_KEY=...
export MONGODB_ATLAS_PRIVATE_KEY=...

make init
make plan     # review: ~91 resources
make apply
```

**The billing clock starts here** — roughly **$0.43/h**. Expect 15–25 minutes;
EKS and Amazon MQ dominate.

> **Atlas 401.** If the Atlas resources fail with `HTTP 401 Unauthorized`, the
> cause is almost always the API key's **API Access List**, not the key itself.
> Add your current IP in Atlas under `Organization → Applications → your key`.

Take note of the outputs:

```sh
tofu output github_actions_role_arn
tofu output kubeconfig_command
```

## 3. Cluster access

```sh
make kubeconfig
kubectl get nodes     # expect 2 Ready
```

## 4. Prerequisites the charts do not install

Both are easy to forget and both fail confusingly.

```sh
# Gateway API CRDs — only needed if you route with Gateway API rather than
# Ingress. This platform uses Ingress; see k8s/shared/kong/ingresses.yaml.
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

# metrics-server — EKS does not ship it
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.2/components.yaml
```

> **Without metrics-server every HPA reports `cpu: <unknown>` and never
> scales.** The manifests look correct and do nothing. Verify with
> `kubectl get hpa -n tech-challenge` — `TARGETS` must show percentages.

## 5. Secrets

```sh
export GHCR_PAT=ghp_...            # classic token, read:packages only
kubectl apply -f k8s/namespaces/tech-challenge.yaml
k8s/secrets-from-tofu.sh
kubectl apply -f k8s/ghcr-pull-secret.yaml \
              -f k8s/work-order-service/secret.yaml \
              -f k8s/billing-service/secret.yaml \
              -f k8s/execution-service/secret.yaml \
              -f k8s/auth-service/secret.yaml \
              -f k8s/shared/kong/kong-consumer.yaml
```

The script reads every database and broker credential from Secrets Manager and
percent-encodes them: RDS generates passwords containing `#`, `<`, `>` and
friends, and an unencoded `#` truncates the connection string into a fragment.

## 6. Kong

```sh
helm repo add kong https://charts.konghq.com && helm repo update
helm install kong kong/ingress -n kong --create-namespace \
  -f k8s/shared/kong/values.yaml --wait --timeout 8m
```

> **The admin API must stay enabled.** The controller pushes configuration
> through it. Disabling it deadlocks the install: the gateway never turns Ready
> without config and the controller never finds an endpoint to send it to. Keep
> it a headless `ClusterIP` — only the proxy gets a LoadBalancer. It also has to
> be the **TLS** listener; the controller talks to `:8444`.

## 7. Datadog

```sh
kubectl create namespace datadog
kubectl create secret generic datadog-api \
  --from-literal api-key="$DD_API_KEY" -n datadog
helm install datadog datadog/datadog -n datadog \
  -f k8s/shared/datadog/values.yaml --wait --timeout 8m
```

The agent's service is `datadog`, not `datadog-agent`. The Deployments do not
rely on the name at all: they set `DD_AGENT_HOST` from `status.hostIP` so each
pod talks to the agent on its own node.

## 8. Database migrations

The runtime images are slim — no Prisma CLI, no `migrations/` directory — so
migrations cannot be run from a running pod.

**This is a known gap:** it should be a Kubernetes Job, applied by the deploy
pipeline and waited on before the rollout. Until that exists, tunnel to RDS and
run them from the repository:

```sh
EP=$(cd terraform && tofu output -json postgres_endpoints | jq -r '."work-order"')
kubectl run rds-tunnel -n tech-challenge --image=alpine/socat --restart=Never -- \
  tcp-listen:5432,fork,reuseaddr "tcp-connect:${EP}"
kubectl port-forward -n tech-challenge pod/rds-tunnel 15432:5432 &

# from work-order-service/, with the credentials from Secrets Manager
DATABASE_URL="postgresql://USER:PASS@localhost:15432/workorder?sslmode=no-verify" \
  npx prisma migrate deploy
```

Repeat for `billing`. Delete the tunnel pod afterwards.

## 9. Services

```sh
kubectl apply -k k8s
kubectl get pods -n tech-challenge -w
```

## 10. Deploy pipeline

```sh
ROLE=$(cd terraform && tofu output -raw github_actions_role_arn)
for repo in work-order-service billing-service execution-service auth-service; do
  gh secret set AWS_DEPLOY_ROLE_ARN --repo tech-challenge-workshop/$repo --body "$ROLE"
done
```

From then on a push to `main` builds, tests, pushes the image and rolls it out.
Without the secret the deploy job skips itself, which keeps `main` green while
no cluster exists.

---

## Validating

```sh
NLB=$(kubectl get svc -n kong kong-gateway-proxy \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl -o /dev/null -w '%{http_code}\n' "http://$NLB/work-orders"              # 401
curl -o /dev/null -w '%{http_code}\n' "http://$NLB/parts/prices?ids=x"       # 200

ADMIN=$(curl -s -X POST "http://$NLB/auth/admin" -H "X-Api-Key: $ADMIN_API_KEY" | jq -r .token)
curl -o /dev/null -w '%{http_code}\n' "http://$NLB/work-orders" -H "Authorization: Bearer $ADMIN"  # 200
```

Then run a full work order through the gateway and check that it reaches
`FINISHED`, that the quote is `APPROVED`, and that the part's reserved quantity
went back to zero after consumption.

---

## Tearing down

```sh
cd terraform
make destroy
```

**Do this when you stop working.** At ~$0.43/h an idle cluster is about
$10/day. The stack is designed to be recreated: no final snapshots, no deletion
protection, no backup retention.

The Atlas project and cluster are destroyed too. The state bucket and the GHCR
images survive, so the next `apply` starts from step 2.

---

## Everything that broke on the first run

| Symptom | Cause |
| --- | --- |
| Node group `CREATING` for 20+ min, no instances | `t3.medium` not free-tier eligible; visible only in ASG scaling activities |
| `FreeTierRestrictionError` on DocumentDB | not available on the Free Plan at all |
| `Broker engine type [RabbitMQ] does not support host instance type [mq.t3.micro]` | RabbitMQ's smallest is `mq.m7g.medium` |
| Atlas `HTTP 401` | provider had no credentials — needs an explicit `provider "mongodbatlas" {}` block, and the IP must be in the key's access list |
| Kong install times out, controller `CrashLoopBackOff` | admin API disabled |
| Controller `connection refused :8444` | admin listener had HTTP enabled instead of TLS |
| `no matches for kind "HTTPRoute"` | Gateway API CRDs not installed |
| Gateway stuck at `Waiting for controller` | never resolved; routing moved to Ingress |
| `ImagePullBackOff` on one service | its `imagePullSecrets` had been removed by an over-greedy edit |
| `CrashLoopBackOff`, `Invalid URL at DATABASE_URL` | RDS password contained `#`; the connection string was not percent-encoded |
| `self-signed certificate in certificate chain` | RDS presents the Amazon RDS CA; needs the bundle and `sslrootcert` |
| `TableDoesNotExist` | migrations never ran against RDS |
| `getaddrinfo ENOTFOUND datadog-agent.datadog...` | wrong service name; use `status.hostIP` instead |
| HPAs at `cpu: <unknown>`, k9s without metrics | metrics-server not installed |
