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

# Values already in the cache win over the environment: rotating JWT_SECRET
# would invalidate every live token and desynchronise the Kong consumer
# credential at the same time.
if [[ -f "$CACHE" ]]; then
  # shellcheck source=/dev/null
  source "$CACHE"
fi

JWT_SECRET="${JWT_SECRET:-$(openssl rand -hex 32)}"
ADMIN_API_KEY="${ADMIN_API_KEY:-$(openssl rand -hex 24)}"
GHCR_USER="${GHCR_USER:-${GITHUB_USER:-figueiredoleo}}"
MERCADO_PAGO_ACCESS_TOKEN="${MERCADO_PAGO_ACCESS_TOKEN:-}"

if [[ -z "${GHCR_PAT:-}" ]]; then
  cat >&2 <<'EOT'
GHCR_PAT is not set and .secrets.env has none.

The GHCR packages are private, so the cluster needs a token to pull them.
Create a classic one carrying only the read:packages scope and export it:

  export GHCR_PAT=ghp_...    # https://github.com/settings/tokens/new
EOT
  exit 1
fi

# Rewritten in full rather than appended, so repeated runs cannot accumulate
# duplicate lines.
umask 077
cat > "$CACHE" <<EOF
JWT_SECRET=$JWT_SECRET
ADMIN_API_KEY=$ADMIN_API_KEY
GHCR_PAT=$GHCR_PAT
GHCR_USER=$GHCR_USER
EOF
echo "credentials cached in .secrets.env"

# Everything below reads the platform outputs, so fail here with something
# actionable instead of letting a backend or "no outputs" error surface.
if ! tofu -chdir="$TOFU_DIR" output -raw cluster_name >/dev/null 2>&1; then
  cat >&2 <<'EOT'

The platform stack has no outputs yet — this script runs *after* the
infrastructure exists. From ../terraform:

  make bootstrap    # once per account: creates the state bucket
  make init
  make plan
  make apply

Then run this script again.
EOT
  exit 1
fi

echo "reading OpenTofu outputs..."

RABBITMQ_URL="$(secret_json "$(tofu_out rabbitmq_secret_arn)" | jq -r .uri)"
MONGODB_URL="$(secret_json "$(tofu_out mongodbatlas_secret_arn)" | jq -r .uri)"

# RDS generates master passwords containing characters that are reserved in a
# URL — '#' alone truncates everything after it into a fragment — so both parts
# of the userinfo are percent-encoded before being spliced in.
urlencode() { jq -sRr @uri; }

pg_url() {
  local service="$1" database="$2"
  local endpoint arn creds user pass
  endpoint="$(tofu_json postgres_endpoints | jq -r --arg s "$service" '.[$s]')"
  arn="$(tofu_json postgres_secret_arns | jq -r --arg s "$service" '.[$s]')"
  creds="$(secret_json "$arn")"
  user="$(jq -r .username <<<"$creds" | tr -d '\n' | urlencode)"
  pass="$(jq -r .password <<<"$creds" | tr -d '\n' | urlencode)"
  # verify-full with the Amazon RDS bundle the init container fetches: plain
  # sslmode=require still validates the chain and fails on the RDS CA.
  printf 'postgresql://%s:%s@%s/%s?schema=public&sslmode=verify-full&sslrootcert=/etc/ssl/rds/global-bundle.pem' \
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

# One pull secret for the whole namespace, referenced by every Deployment.
# `auth` is what the Docker credential helper actually reads; username and
# password are kept for tools that inspect the file.
GHCR_AUTH="$(printf '%s:%s' "$GHCR_USER" "$GHCR_PAT" | base64 -w0)"
GHCR_DOCKERCONFIG="$(
  printf '{"auths":{"ghcr.io":{"username":"%s","password":"%s","auth":"%s"}}}' \
    "$GHCR_USER" "$GHCR_PAT" "$GHCR_AUTH" | base64 -w0
)"

write_secret "$K8S_DIR/ghcr-pull-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ghcr-pull
  namespace: tech-challenge
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: "$GHCR_DOCKERCONFIG"
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

  kubectl apply -f ghcr-pull-secret.yaml \
                -f work-order-service/secret.yaml \
                -f billing-service/secret.yaml \
                -f execution-service/secret.yaml \
                -f auth-service/secret.yaml \
                -f shared/kong/kong-consumer.yaml

The Datadog API key is not handled here — it belongs to the Agent, not to the
services. Create it separately:

  kubectl create secret generic datadog-api \
    --from-literal api-key="$DD_API_KEY" -n datadog
EOF
