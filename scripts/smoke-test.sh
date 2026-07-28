#!/usr/bin/env bash
#
# Exercises the whole platform through Kong: routing, authentication,
# authorisation and a complete saga across the three services.
#
#   ./scripts/smoke-test.sh                 # against the cluster (default)
#   BASE_URL=http://localhost:8000 ./scripts/smoke-test.sh    # against local compose
#
# Reads ADMIN_API_KEY from k8s/.secrets.env unless it is already exported.
# Every request goes through the gateway — nothing talks to a service directly.

set -uo pipefail

cd "$(dirname "$0")/.."

pass=0
fail=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  \033[32m✓\033[0m %-46s %s\n' "$label" "$actual"
    pass=$((pass + 1))
  else
    printf '  \033[31m✗\033[0m %-46s got %s, expected %s\n' "$label" "$actual" "$expected"
    fail=$((fail + 1))
  fi
}

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 25 "$@"; }
body() { curl -s --max-time 25 "$@"; }

if [[ -z "${BASE_URL:-}" ]]; then
  host="$(kubectl get svc -n kong kong-gateway-proxy \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
  [[ -z "$host" ]] && { echo "No Kong LoadBalancer found. Is the cluster up?" >&2; exit 1; }
  BASE_URL="http://$host"
fi

if [[ -z "${ADMIN_API_KEY:-}" && -f k8s/.secrets.env ]]; then
  ADMIN_API_KEY="$(grep '^ADMIN_API_KEY=' k8s/.secrets.env | cut -d= -f2-)"
fi
[[ -z "${ADMIN_API_KEY:-}" ]] && { echo "ADMIN_API_KEY is not set." >&2; exit 1; }

echo "Gateway: $BASE_URL"
echo

echo "Routing and public endpoints"
check "GET /parts/prices                (public)" 200 "$(code "$BASE_URL/parts/prices?ids=none")"
check "GET /customers/lookup            (public)" 404 "$(code "$BASE_URL/customers/lookup?document=00000000191")"

echo
echo "Authentication is enforced at the edge"
check "GET /work-orders                 (no token)" 401 "$(code "$BASE_URL/work-orders")"
check "GET /quotes/x                    (no token)" 401 "$(code "$BASE_URL/quotes/x")"
check "GET /parts                       (no token)" 401 "$(code "$BASE_URL/parts")"
check "GET /executions                  (no token)" 401 "$(code "$BASE_URL/executions")"

echo
echo "Tokens"
ADMIN="$(body -X POST "$BASE_URL/auth/admin" -H "X-Api-Key: $ADMIN_API_KEY" | jq -r '.token // empty')"
check "POST /auth/admin                 (issues token)" "yes" "$([[ -n "$ADMIN" ]] && echo yes || echo no)"
check "POST /auth/admin                 (wrong key)" 401 "$(code -X POST "$BASE_URL/auth/admin" -H 'X-Api-Key: wrong')"
[[ -z "$ADMIN" ]] && { echo "Cannot continue without an admin token." >&2; exit 1; }
AUTH="Authorization: Bearer $ADMIN"
check "GET /work-orders                 (admin token)" 200 "$(code "$BASE_URL/work-orders" -H "$AUTH")"

echo
echo "Seeding"
DOC="390.533.447-05"
# A plate is unique per vehicle, so a rerun would collide on it.
PLATE="SMK$((RANDOM % 10))A$(printf '%02d' $((RANDOM % 100)))"

PART="$(body -X POST "$BASE_URL/parts" -H "$AUTH" -H 'content-type: application/json' \
  -d '{"name":"Brake pad","priceCents":5000,"initialQuantity":100}' | jq -r '.id // empty')"

# The customer survives previous runs — the document is unique, so creating it
# again conflicts. Fall back to the lookup, which is the same endpoint
# auth-service uses before issuing a token.
CUS="$(body -X POST "$BASE_URL/customers" -H "$AUTH" -H 'content-type: application/json' \
  -d "{\"name\":\"Smoke Test\",\"document\":\"$DOC\"}" | jq -r '.id // empty')"
if [[ -z "$CUS" ]]; then
  CUS="$(body "$BASE_URL/customers/lookup?document=$DOC" | jq -r '.id // empty')"
fi

VEH="$(body -X POST "$BASE_URL/vehicles" -H "$AUTH" -H 'content-type: application/json' \
  -d "{\"customerId\":\"$CUS\",\"plate\":\"$PLATE\",\"brand\":\"Toyota\",\"model\":\"Corolla\",\"year\":2024}" | jq -r '.id // empty')"
SVC="$(body -X POST "$BASE_URL/repair-services" -H "$AUTH" -H 'content-type: application/json' \
  -d '{"name":"Oil change","priceCents":15000}' | jq -r '.id // empty')"

check "part created"     "yes" "$([[ -n "$PART" ]] && echo yes || echo no)"
check "customer ready"   "yes" "$([[ -n "$CUS" ]] && echo yes || echo no)"
check "vehicle created"  "yes" "$([[ -n "$VEH" ]] && echo yes || echo no)"
check "service created"  "yes" "$([[ -n "$SVC" ]] && echo yes || echo no)"
[[ -n "$PART" && -n "$CUS" && -n "$VEH" && -n "$SVC" ]] || {
  echo "Seeding failed — cannot run the saga." >&2; exit 1; }

echo
echo "Saga"
WO="$(body -X POST "$BASE_URL/work-orders" -H "$AUTH" -H 'content-type: application/json' \
  -d "{\"customerId\":\"$CUS\",\"vehicleId\":\"$VEH\",\"serviceIds\":[\"$SVC\"],\"parts\":[{\"partId\":\"$PART\",\"quantity\":3}]}" | jq -r '.id // empty')"
echo "  work order: $WO"

status() { body "$BASE_URL/work-orders/$WO" -H "$AUTH" | jq -r '.status // empty'; }
await() {
  local want="$1" tries=0
  until [[ "$(status)" == "$want" ]]; do
    tries=$((tries + 1)); [[ $tries -gt 20 ]] && return 1; sleep 3
  done
}

await AWAITING_APPROVAL && check "parts reserved, quote generated" AWAITING_APPROVAL "$(status)" \
  || check "parts reserved, quote generated" AWAITING_APPROVAL "$(status)"

CUSTOMER="$(body -X POST "$BASE_URL/auth" -H 'content-type: application/json' \
  -d "{\"document\":\"$DOC\"}" | jq -r '.token // empty')"
check "POST /auth                       (customer by CPF)" "yes" "$([[ -n "$CUSTOMER" ]] && echo yes || echo no)"

# Approving is the customer's decision — an admin must not be able to do it.
check "POST /quotes/:id/approve         (admin → forbidden)" 403 \
  "$(code -X POST "$BASE_URL/quotes/$WO/approve" -H "$AUTH")"
check "POST /quotes/:id/approve         (customer)" 201 \
  "$(code -X POST "$BASE_URL/quotes/$WO/approve" -H "Authorization: Bearer $CUSTOMER")"

await IN_EXECUTION && check "payment confirmed" IN_EXECUTION "$(status)" \
  || check "payment confirmed" IN_EXECUTION "$(status)"

curl -s -o /dev/null --max-time 25 -X POST "$BASE_URL/executions/$WO/start-repair" -H "$AUTH"
curl -s -o /dev/null --max-time 25 -X POST "$BASE_URL/executions/$WO/complete" -H "$AUTH"

await FINISHED && check "repair completed" FINISHED "$(status)" \
  || check "repair completed" FINISHED "$(status)"

echo
echo "Persistence in the managed stores"
check "work order history has 5 transitions" 5 \
  "$(body "$BASE_URL/work-orders/$WO" -H "$AUTH" | jq '.history | length')"
check "quote approved                   (billing RDS)" APPROVED \
  "$(body "$BASE_URL/quotes/$WO" -H "$AUTH" | jq -r '.status')"
check "execution completed              (Atlas)" COMPLETED \
  "$(body "$BASE_URL/executions/$WO" -H "$AUTH" | jq -r '.status')"
check "reservation consumed             (Atlas)" 0 \
  "$(body "$BASE_URL/parts/$PART" -H "$AUTH" | jq -r '.reservedQuantity')"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]] || exit 1
