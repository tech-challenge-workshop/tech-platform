#!/usr/bin/env bash
#
# Takes a freshly applied stack to a working platform: everything between
# `tofu apply` and a green smoke test.
#
#   cd terraform && make apply
#   ./scripts/bootstrap-cluster.sh
#   ./scripts/smoke-test.sh
#
# Idempotent by design — safe to rerun against a cluster that is already up,
# which is also how it gets tested without tearing anything down.
#
# Requires: kubectl, helm, jq, aws, tofu, and in the environment:
#   GHCR_PAT                 classic token, read:packages   (cached after the first run)
#   MERCADO_PAGO_ACCESS_TOKEN  optional; empty means the sandbox adapter

set -euo pipefail

cd "$(dirname "$0")/.."

METRICS_SERVER_VERSION="v0.7.2"
AUTH_SERVICE_DIR="${AUTH_SERVICE_DIR:-../auth-service}"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
note() { printf '  %s\n' "$1"; }

for cmd in kubectl helm jq aws tofu; do
  command -v "$cmd" >/dev/null || { echo "missing required command: $cmd" >&2; exit 1; }
done

step "Cluster credentials"
CLUSTER="$(tofu -chdir=terraform output -raw cluster_name)"
REGION="$(tofu -chdir=terraform output -raw region)"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
note "$CLUSTER in $REGION"
kubectl get nodes --no-headers | awk '{print "  " $1 " " $2}'

step "metrics-server"
# EKS does not ship it, and without it every HPA reports cpu: <unknown> and
# never scales — the autoscaling requirement would be satisfied on paper only.
if kubectl get deploy metrics-server -n kube-system >/dev/null 2>&1; then
  note "already installed"
else
  kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml" >/dev/null
  kubectl rollout status deployment/metrics-server -n kube-system --timeout=4m >/dev/null
  note "installed ${METRICS_SERVER_VERSION}"
fi

step "Namespace and secrets"
kubectl apply -f k8s/namespaces/tech-challenge.yaml >/dev/null
./scripts/../k8s/secrets-from-tofu.sh >/dev/null
kubectl apply \
  -f k8s/ghcr-pull-secret.yaml \
  -f k8s/work-order-service/secret.yaml \
  -f k8s/billing-service/secret.yaml \
  -f k8s/execution-service/secret.yaml \
  -f k8s/shared/kong/kong-consumer.yaml >/dev/null
note "rendered from the OpenTofu outputs and applied"

step "Kong"
helm repo add kong https://charts.konghq.com >/dev/null 2>&1 || true
helm repo add datadog https://helm.datadoghq.com >/dev/null 2>&1 || true
# Updated one at a time and allowed to fail: `helm repo update` aborts on the
# first unreachable index, and a transient fetch error should not stop a deploy
# when the cached index is good enough. A chart that is genuinely missing still
# fails loudly at `helm upgrade`.
for repo in kong datadog; do
  helm repo update "$repo" >/dev/null 2>&1 || note "could not refresh the $repo index, using the cached one"
done
helm upgrade --install kong kong/ingress -n kong --create-namespace \
  -f k8s/shared/kong/values.yaml --wait --timeout 10m >/dev/null
note "installed"

step "Waiting for the load balancer"
GATEWAY_HOST=""
for _ in $(seq 1 60); do
  GATEWAY_HOST="$(kubectl get svc -n kong kong-gateway-proxy \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "$GATEWAY_HOST" ]] && break
  sleep 5
done
[[ -z "$GATEWAY_HOST" ]] && { echo "the Kong service never got an address" >&2; exit 1; }
note "$GATEWAY_HOST"

step "Datadog"
if [[ -f local/.env ]]; then
  DD_API_KEY="${DD_API_KEY:-$(grep '^DD_API_KEY=' local/.env | cut -d= -f2-)}"
fi
if [[ -z "${DD_API_KEY:-}" ]]; then
  note "DD_API_KEY not set — skipping. Traces and dashboards will be empty."
else
  kubectl create namespace datadog --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create secret generic datadog-api --from-literal api-key="$DD_API_KEY" \
    -n datadog --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  helm upgrade --install datadog datadog/datadog -n datadog \
    -f k8s/shared/datadog/values.yaml --wait --timeout 10m >/dev/null
  note "agent running"
fi

step "auth-service Lambda"
# The Lambda calls back through the gateway to look a customer up, and a new
# cluster means a new load balancer hostname — so the function has to be
# redeployed with the address that exists now. This is the step most likely to
# be forgotten, and it fails silently: /auth simply stops issuing tokens.
if [[ ! -d "$AUTH_SERVICE_DIR" ]]; then
  note "repository not found at $AUTH_SERVICE_DIR — skipping"
  note "redeploy it manually with CUSTOMER_LOOKUP_URL=http://$GATEWAY_HOST/customers/lookup"
else
  # shellcheck source=/dev/null
  source k8s/.secrets.env
  (
    cd "$AUTH_SERVICE_DIR"
    JWT_SECRET="$JWT_SECRET" \
    ADMIN_API_KEY="$ADMIN_API_KEY" \
    CUSTOMER_LOOKUP_URL="http://$GATEWAY_HOST/customers/lookup" \
      npx serverless deploy --stage dev 2>&1 | grep -E 'endpoint|deployed|Error' || true
  )
  API_HOST="$(aws cloudformation describe-stacks --stack-name auth-service-dev \
    --query 'Stacks[0].Outputs[?OutputKey==`HttpApiUrl`].OutputValue' --output text 2>/dev/null \
    | sed 's|https://||')"
  if [[ -n "$API_HOST" && "$API_HOST" != "None" ]]; then
    note "API Gateway: $API_HOST"
    # The ExternalName has the previous host baked in; point it at this one.
    kubectl -n tech-challenge patch service auth-service --type merge -p "$(
      jq -nc --arg h "$API_HOST" '{
        metadata: { annotations: { "konghq.com/host-header": $h } },
        spec: { externalName: $h }
      }')" >/dev/null 2>&1 || true
  fi
fi

step "Services"
kubectl apply -k k8s >/dev/null
note "applied"

step "Schema migrations"
# The pipeline normally runs these, but a fresh cluster has no push to trigger
# it, and the services crash-loop on a database with no tables.
for svc in work-order-service billing-service; do
  kubectl -n tech-challenge delete job "${svc}-migrate" --ignore-not-found >/dev/null
  kubectl -n tech-challenge create -f "k8s/${svc}/migration-job.yaml" >/dev/null
done
for svc in work-order-service billing-service; do
  if kubectl -n tech-challenge wait --for=condition=complete "job/${svc}-migrate" --timeout=5m >/dev/null 2>&1; then
    note "$svc migrated"
  else
    echo "  $svc migration failed — kubectl logs -n tech-challenge job/${svc}-migrate" >&2
    exit 1
  fi
done

step "Waiting for the services"
kubectl -n tech-challenge rollout status deployment/work-order-service --timeout=5m >/dev/null
kubectl -n tech-challenge rollout status deployment/billing-service --timeout=5m >/dev/null
kubectl -n tech-challenge rollout status deployment/execution-service --timeout=5m >/dev/null
kubectl get pods -n tech-challenge --no-headers | awk '{print "  " $1 " " $2 " " $3}'

cat <<EOF

Platform ready.

  Gateway   http://$GATEWAY_HOST
  Verify    ./scripts/smoke-test.sh

Point the deploy pipeline at this cluster, if it is not already:

  ROLE=\$(tofu -chdir=terraform output -raw github_actions_role_arn)
  for repo in work-order-service billing-service execution-service auth-service; do
    gh secret set AWS_DEPLOY_ROLE_ARN --repo tech-challenge-workshop/\$repo --body "\$ROLE"
  done
EOF
