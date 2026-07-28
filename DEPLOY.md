# Deploy runbook

Everything needed to take the platform from an empty AWS account to a working
cluster running the four services, and to tear it back down.

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

The new Free Tier has a **Free Plan** and a **Paid Plan**. On the Free Plan only
free-tier-eligible services and instance types may be used, which shapes two
choices in this stack:

- the document store is **MongoDB Atlas**, because DocumentDB is not available
  on the plan at all
- nodes are **`c7i-flex.large`**, which is eligible; `t3.medium` is not

Check what the account allows:

```sh
aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true \
  --query 'InstanceTypes[*].{type:InstanceType,vcpu:VCpuInfo.DefaultVCpus,memMiB:MemoryInfo.SizeInMiB}' \
  --output table
```

`c7i-flex.large` (2 vCPU / 4 GiB) and `m7i-flex.large` (2 vCPU / 8 GiB) are both
eligible.

---

## The short version

Steps 4 to 9 are automated:

```sh
cd terraform && make apply
../scripts/bootstrap-cluster.sh
../scripts/smoke-test.sh          # 23 checks, end to end
```

The rest of this document explains what that script does and why each step is
there — read it when something fails, not before.

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

> **The Atlas API key needs your IP in its access list**, under
> `Organization → Applications → your key`. Calls from anywhere else are
> rejected with `401 Unauthorized`.

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

## 4. The prerequisite the charts do not install

```sh
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.2/components.yaml
```

> metrics-server is what feeds the HPAs. Verify with
> `kubectl get hpa -n tech-challenge` — `TARGETS` must show percentages, not
> `<unknown>`.

## 5. Secrets

```sh
export GHCR_PAT=ghp_...            # classic token, read:packages only
kubectl apply -f k8s/namespaces/tech-challenge.yaml
k8s/secrets-from-tofu.sh
kubectl apply -f k8s/ghcr-pull-secret.yaml \
              -f k8s/work-order-service/secret.yaml \
              -f k8s/billing-service/secret.yaml \
              -f k8s/execution-service/secret.yaml \
              -f k8s/shared/kong/kong-consumer.yaml
```

The script reads every database and broker credential from Secrets Manager and
percent-encodes them, since RDS generates passwords containing characters that
are reserved in a URL.

## 6. Kong

```sh
helm repo add kong https://charts.konghq.com && helm repo update
helm install kong kong/ingress -n kong --create-namespace \
  -f k8s/shared/kong/values.yaml --wait --timeout 8m
```

> **The admin API must stay enabled, as TLS on `:8444`.** The controller pushes
> configuration through it. It is a headless `ClusterIP` — only the proxy gets a
> LoadBalancer, so the admin API is never exposed outside the cluster.

## 7. Datadog

```sh
kubectl create namespace datadog
kubectl create secret generic datadog-api \
  --from-literal api-key="$DD_API_KEY" -n datadog
helm install datadog datadog/datadog -n datadog \
  -f k8s/shared/datadog/values.yaml --wait --timeout 8m
```

The Deployments set `DD_AGENT_HOST` from `status.hostIP`, so each pod talks to
the agent on its own node rather than through a service name.

## 8. Database migrations

Run as a Kubernetes Job, from an image built off the `migrator` target — the
runtime images are slim and carry neither the Prisma CLI nor `migrations/`.

The deploy pipeline recreates the Job against the image of that release and
waits for it before rolling out, so a failed migration stops the release.
`bootstrap-cluster.sh` does the same for a fresh cluster, which has had no push
to trigger a pipeline.

By hand:

```sh
kubectl -n tech-challenge delete job work-order-service-migrate --ignore-not-found
kubectl -n tech-challenge create -f k8s/work-order-service/migration-job.yaml
kubectl -n tech-challenge wait --for=condition=complete job/work-order-service-migrate --timeout=5m
```

> Prisma 7 reads `datasource.url` from `prisma.config.ts`, which is why the
> migrator image carries it alongside the schema.

## 9. Services

```sh
kubectl apply -k k8s
kubectl get pods -n tech-challenge -w
```

## 10. Deploy pipeline

The three in-cluster services need the deploy role:

```sh
ROLE=$(cd terraform && tofu output -raw github_actions_role_arn)
for repo in work-order-service billing-service execution-service; do
  gh secret set AWS_DEPLOY_ROLE_ARN --repo tech-challenge-workshop/$repo --body "$ROLE"
  gh variable set EKS_CLUSTER_NAME --repo tech-challenge-workshop/$repo --body "tech-challenge-dev-eks"
  gh variable set AWS_REGION --repo tech-challenge-workshop/$repo --body "us-east-1"
done
```

`auth-service` deploys a Lambda instead of a workload, so it needs a different
set — see its README. Its pipeline runs `serverless deploy`, not `kubectl`.

From then on a push to `main` builds, tests, pushes the image, runs the
migration Job and rolls out. Without the secret the deploy job skips itself,
which keeps `main` green while no cluster exists.

> GitHub resolves secrets when a run is created, so a newly added secret only
> applies to runs started afterwards. Every workflow accepts `workflow_dispatch`
> to trigger one.

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

Or run the whole thing:

```sh
./scripts/smoke-test.sh
```

23 checks: routing, edge authentication, role enforcement, a full saga, and the
resulting state in RDS and Atlas. It is re-runnable and takes about 40 seconds.

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

