#!/usr/bin/env bash
#
# Renders every gitignored secret.yaml from the OpenTofu outputs.
#
# Database and broker credentials are read from Secrets Manager, never typed by
# hand. JWT_SECRET and ADMIN_API_KEY are generated on first run and cached in
# .secrets.env so repeated runs keep issuing tokens the services still accept.
#
#   ./secrets-from-tofu.sh              # write the files
#   ./secrets-from-tofu.sh | kubectl apply -f -   # not supported: files only
#
# Requires: tofu, aws, jq.

set -euo pipefail

cd "$(dirname "$0")"

K8S_DIR="$PWD"
TOFU_DIR="$PWD/../terraform"
CACHE="$PWD/.secrets.env"

for cmd in tofu aws jq; do
  command -v "$cmd" >/dev/null || { echo "missing required command: $cmd" >&2; exit 1; }
done

tofu_out() { tofu -chdir="$TOFU_DIR" output -raw "$1"; }
tofu_json() { tofu -chdir="$TOFU_DIR" output -json "$1"; }

secret_json() {
  aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text
}

# Generated once, then reused: rotating these would invalidate every live token
# and break the Kong consumer credential at the same time.
if [[ -f "$CACHE" ]]; then
  # shellcheck source=/dev/null
  source "$CACHE"
  echo "reusing JWT_SECRET and ADMIN_API_KEY from .secrets.env"
else
  JWT_SECRET="$(openssl rand -hex 32)"
  ADMIN_API_KEY="$(openssl rand -hex 24)"
  printf 'JWT_SECRET=%s\nADMIN_API_KEY=%s\n' "$JWT_SECRET" "$ADMIN_API_KEY" > "$CACHE"
  chmod 600 "$CACHE"
  echo "generated JWT_SECRET and ADMIN_API_KEY into .secrets.env"
fi

MERCADO_PAGO_ACCESS_TOKEN="${MERCADO_PAGO_ACCESS_TOKEN:-}"

echo "reading OpenTofu outputs..."

RABBITMQ_URL="$(secret_json "$(tofu_out rabbitmq_secret_arn)" | jq -r .uri)"
MONGODB_URL="$(secret_json "$(tofu_out documentdb_secret_arn)" | jq -r .uri)"

pg_url() {
  local service="$1" database="$2"
  local endpoint arn creds user pass
  endpoint="$(tofu_json postgres_endpoints | jq -r --arg s "$service" '.[$s]')"
  arn="$(tofu_json postgres_secret_arns | jq -r --arg s "$service" '.[$s]')"
  creds="$(secret_json "$arn")"
  user="$(jq -r .username <<<"$creds")"
  pass="$(jq -r .password <<<"$creds")"
  printf 'postgresql://%s:%s@%s/%s?schema=public&sslmode=require' \
    "$user" "$pass" "$endpoint" "$database"
}

WORK_ORDER_DATABASE_URL="$(pg_url work-order workorder)"
BILLING_DATABASE_URL="$(pg_url billing billing)"

write_secret() {
  local path="$1"
  cat > "$path"
  echo "wrote ${path#"$K8S_DIR"/}"
}

write_secret "$K8S_DIR/work-order-service/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: work-order-service
  namespace: tech-challenge
type: Opaque
stringData:
  DATABASE_URL: "$WORK_ORDER_DATABASE_URL"
  RABBITMQ_URL: "$RABBITMQ_URL"
  JWT_SECRET: "$JWT_SECRET"
EOF

write_secret "$K8S_DIR/billing-service/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: billing-service
  namespace: tech-challenge
type: Opaque
stringData:
  DATABASE_URL: "$BILLING_DATABASE_URL"
  RABBITMQ_URL: "$RABBITMQ_URL"
  JWT_SECRET: "$JWT_SECRET"
  MERCADO_PAGO_ACCESS_TOKEN: "$MERCADO_PAGO_ACCESS_TOKEN"
EOF

write_secret "$K8S_DIR/execution-service/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: execution-service
  namespace: tech-challenge
type: Opaque
stringData:
  MONGODB_URL: "$MONGODB_URL"
  RABBITMQ_URL: "$RABBITMQ_URL"
  JWT_SECRET: "$JWT_SECRET"
EOF

write_secret "$K8S_DIR/auth-service/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: auth-service
  namespace: tech-challenge
type: Opaque
stringData:
  JWT_SECRET: "$JWT_SECRET"
  ADMIN_API_KEY: "$ADMIN_API_KEY"
EOF

# Kong verifies incoming tokens with the same shared secret, matching the
# consumer by the token's iss claim.
write_secret "$K8S_DIR/shared/kong/kong-consumer.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: auth-service-jwt
  namespace: tech-challenge
  labels:
    konghq.com/credential: jwt
type: Opaque
stringData:
  kongCredType: jwt
  key: auth-service
  algorithm: HS256
  secret: "$JWT_SECRET"
---
apiVersion: configuration.konghq.com/v1
kind: KongConsumer
metadata:
  name: auth-service
  namespace: tech-challenge
  annotations:
    kubernetes.io/ingress.class: kong
username: auth-service
credentials:
  - auth-service-jwt
EOF

cat <<'EOF'

Done. Apply them with:

  kubectl apply -f work-order-service/secret.yaml \
                -f billing-service/secret.yaml \
                -f execution-service/secret.yaml \
                -f auth-service/secret.yaml \
                -f shared/kong/kong-consumer.yaml

The Datadog API key is not handled here — it belongs to the Agent, not to the
services. Create it separately:

  kubectl create secret generic datadog-api \
    --from-literal api-key="$DD_API_KEY" -n datadog
EOF
