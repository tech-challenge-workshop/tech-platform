# Demo playbook

A walkthrough of the system as a real workshop would use it, with the place to
watch each step actually happen. Doubles as the script for the demo video.

Two people appear in the story:

- the **workshop attendant** (`admin`) — registers data, runs the repair
- the **customer** — authenticates with their CPF and approves the quote

Everything goes through Kong. Nothing talks to a service directly.

---

## Before you begin

```sh
cd tech-platform
export AWS_PROFILE=free-tier

export GATEWAY="http://$(kubectl get svc -n kong kong-gateway-proxy \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
export ADMIN_API_KEY="$(grep '^ADMIN_API_KEY=' k8s/.secrets.env | cut -d= -f2-)"
echo "$GATEWAY"
```

### Windows to keep open

| Window | Command | Shows |
| --- | --- | --- |
| **1 — the story** | your shell | the curl commands below |
| **2 — the saga** | `kubectl logs -n tech-challenge -f deploy/work-order-service \| grep -E 'status_changed\|saga'` | each status transition as it happens |
| **3 — the participants** | `kubectl logs -n tech-challenge -f deploy/execution-service` | stock being reserved and consumed |
| **4 — the cluster** | `k9s -n tech-challenge` | pods, CPU, memory, restarts |
| **Browser** | [Datadog APM](https://app.datadoghq.com/apm/traces) | the distributed trace |

For the video, windows 1 and 2 side by side tell the story best: a command on
the left, the status changing on the right without anyone touching it.

---

## Act 1 — The workshop opens

The attendant authenticates. There is no user database: the key is a shared
secret and the response is a JWT carrying `role: admin`.

```sh
ADMIN=$(curl -s -X POST "$GATEWAY/auth/admin" \
  -H "X-Api-Key: $ADMIN_API_KEY" | jq -r .token)

echo "$ADMIN" | cut -d. -f2 | base64 -d 2>/dev/null | jq
```

**Watch:** the decoded payload shows `sub`, `role: admin` and `iss: auth-service`.
That `iss` is what lets Kong match the credential — a token without it is
rejected at the edge even with a valid signature.

Register the catalogue: a part, a service, a customer and their vehicle.

```sh
AUTH="Authorization: Bearer $ADMIN"

PART=$(curl -s -X POST "$GATEWAY/parts" -H "$AUTH" -H 'content-type: application/json' \
  -d '{"name":"Brake pad","priceCents":5000,"initialQuantity":100}' | jq -r .id)

SVC=$(curl -s -X POST "$GATEWAY/repair-services" -H "$AUTH" -H 'content-type: application/json' \
  -d '{"name":"Brake replacement","priceCents":25000}' | jq -r .id)

CUS=$(curl -s -X POST "$GATEWAY/customers" -H "$AUTH" -H 'content-type: application/json' \
  -d '{"name":"Maria Silva","document":"111.444.777-35"}' | jq -r .id)

VEH=$(curl -s -X POST "$GATEWAY/vehicles" -H "$AUTH" -H 'content-type: application/json' \
  -d "{\"customerId\":\"$CUS\",\"plate\":\"DEM2A34\",\"brand\":\"Honda\",\"model\":\"Civic\",\"year\":2023}" | jq -r .id)
```

**Watch:** the part lives in MongoDB Atlas, the customer in RDS. Two different
services, two different databases, neither reachable by the other.

### Worth showing: the door is closed

```sh
curl -s -o /dev/null -w '%{http_code}\n' "$GATEWAY/work-orders"          # 401
curl -s -o /dev/null -w '%{http_code}\n' "$GATEWAY/parts"                # 401
```

Kong rejects both before the request ever reaches a pod — confirm in window 2
that nothing is logged.

---

## Act 2 — A customer arrives

The attendant opens the work order. This one command starts the distributed
transaction.

```sh
WO=$(curl -s -X POST "$GATEWAY/work-orders" -H "$AUTH" -H 'content-type: application/json' \
  -d "{\"customerId\":\"$CUS\",\"vehicleId\":\"$VEH\",\"serviceIds\":[\"$SVC\"],\"parts\":[{\"partId\":\"$PART\",\"quantity\":2}]}" | jq -r .id)
echo "$WO"
```

**Watch window 2.** Within a couple of seconds, without any further command:

```
work_order.status_changed  RECEIVED
work_order.status_changed  IN_DIAGNOSIS        ← execution-service reserved the parts
work_order.status_changed  AWAITING_APPROVAL   ← billing-service generated the quote
```

Three services, three databases, one Amazon MQ broker, and nobody wrote to
anybody else's data.

**Watch window 3:** execution-service logs the reservation.

```sh
curl -s "$GATEWAY/parts/$PART" -H "$AUTH" | jq '{availableQuantity, reservedQuantity}'
# 98 available, 2 reserved — reserved, not yet consumed
```

```sh
curl -s "$GATEWAY/work-orders/$WO" -H "$AUTH" | jq '{status, history: [.history[].status]}'
curl -s "$GATEWAY/quotes/$WO" -H "$AUTH" | jq "{status, amountCents}"
```

---

## Act 3 — The customer approves

The customer authenticates with nothing but their CPF. Behind the scenes
`auth-service` calls `/customers/lookup` on work-order-service to confirm they
exist, then issues a token with `role: customer`.

```sh
CUSTOMER=$(curl -s -X POST "$GATEWAY/auth" -H 'content-type: application/json' \
  -d '{"document":"111.444.777-35"}' | jq -r .token)
```

**Worth showing:** the attendant cannot approve on the customer's behalf.

```sh
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$GATEWAY/quotes/$WO/approve" -H "$AUTH"
# 403 — the admin token is valid, the role is wrong
```

```sh
curl -s -X POST "$GATEWAY/quotes/$WO/approve" \
  -H "Authorization: Bearer $CUSTOMER" | jq
```

**Watch window 2:**

```
work_order.status_changed  IN_EXECUTION    ← payment confirmed, sent to the shop floor
```

---

## Act 4 — The repair

```sh
curl -s -X POST "$GATEWAY/executions/$WO/diagnostics" -H "$AUTH" \
  -H 'content-type: application/json' \
  -d '{
        "description": "Front brake pads worn below 2mm",
        "details": { "severity": "high", "measurements": { "padThicknessMm": 1.5 } }
      }' | jq

curl -s -X POST "$GATEWAY/executions/$WO/start-repair" -H "$AUTH" | jq -r .status
curl -s -X POST "$GATEWAY/executions/$WO/complete"     -H "$AUTH" | jq -r .status
```

**Watch window 2:**

```
work_order.status_changed  FINISHED
```

```sh
curl -s "$GATEWAY/parts/$PART" -H "$AUTH" | jq '{availableQuantity, reservedQuantity}'
# 98 available, 0 reserved — the reservation became a permanent deduction
```

The diagnostic is a free-form document — that is why execution-service uses a
document store while the other two use SQL.

---

## Act 5 — When it fails

The compensation path is the part worth showing. Open a second work order and
fail the repair instead of completing it.

```sh
WO2=$(curl -s -X POST "$GATEWAY/work-orders" -H "$AUTH" -H 'content-type: application/json' \
  -d "{\"customerId\":\"$CUS\",\"vehicleId\":\"$VEH\",\"serviceIds\":[\"$SVC\"],\"parts\":[{\"partId\":\"$PART\",\"quantity\":5}]}" | jq -r .id)

sleep 5
curl -s -X POST "$GATEWAY/quotes/$WO2/approve" -H "Authorization: Bearer $CUSTOMER" > /dev/null
sleep 5
curl -s -X POST "$GATEWAY/executions/$WO2/fail" -H "$AUTH" | jq -r .status
```

**Watch window 2.** The saga unwinds in reverse: the payment is refunded, the
quote cancelled, the reservation released, and the order ends `CANCELLED`.

```sh
curl -s "$GATEWAY/work-orders/$WO2" -H "$AUTH" | jq '{status, history: [.history[].status]}'
curl -s "$GATEWAY/parts/$PART" -H "$AUTH" | jq '{availableQuantity, reservedQuantity}'
# the 5 reserved units are back — nothing was consumed
```

Each compensating step only runs if its forward step actually happened, which
is why a failure at reservation cancels the order without refunding anything.

---

## Act 6 — Observability

### The distributed trace

[APM → Traces](https://app.datadoghq.com/apm/traces), filter
`service:work-order-service`, open a `POST /work-orders`.

**Show:** one trace containing spans from **all three services**. The saga steps
appear as `saga.parts_reserved`, `saga.quote_generated` and so on — custom spans
from the orchestrator. If these were three separate traces, the transaction
would be invisible; the context propagates through the RabbitMQ messages.

### Correlated logs

```sh
kubectl logs -n tech-challenge deploy/work-order-service --tail=5 | jq 'select(.["dd.trace_id"] != "")'
```

Every line carries `dd.trace_id`, so a log line links back to the trace it
belongs to.

### Dashboards

The three dashboards from `terraform/datadog` answer the questions the
requirements name: daily work-order volume, average time per status, and errors
across integrations.

### Autoscaling

```sh
kubectl get hpa -n tech-challenge -w
```

Show real percentages, then generate load:

```sh
for i in $(seq 1 300); do curl -s -o /dev/null "$GATEWAY/work-orders" -H "$AUTH" & done; wait
```

**Watch:** CPU climbs and the replica count follows.

### The message broker

The broker is private, so reach its console through a tunnel:

```sh
MQ=$(cd terraform && tofu output -raw rabbitmq_console_url | sed 's|https://||')
kubectl run mq-tunnel -n tech-challenge --image=alpine/socat --restart=Never -- \
  tcp-listen:443,fork,reuseaddr "tcp-connect:${MQ}:443"
kubectl port-forward -n tech-challenge pod/mq-tunnel 8443:443
# https://localhost:8443 — credentials are in Secrets Manager
```

Delete the pod afterwards: `kubectl delete pod mq-tunnel -n tech-challenge`.

---

## Act 7 — Automated deployment

Change something visible — a log message, a version string — and push to `main`.

**Watch:** the pipeline runs build → tests → coverage gate → SonarCloud → BDD →
image → deploy. The deploy job assumes an AWS role through OIDC, with no stored
access key, and rolls out the image built by that exact run, pinned to the
commit SHA.

```sh
kubectl rollout status deployment/work-order-service -n tech-challenge
kubectl get pods -n tech-challenge -w
```

The pipeline fails if the new pods never become ready, so a broken image never
silently stays broken.

---

## Reset between takes

The demo is re-runnable: the customer is looked up if it already exists, and
plates are the only value that must be unique.

```sh
./scripts/smoke-test.sh    # 23 checks, end to end, ~40 seconds
```

Use it as a dress rehearsal before recording — if it comes back green, every
piece the video shows is working.
