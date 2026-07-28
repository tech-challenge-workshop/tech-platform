# OpenTofu — Datadog dashboards and monitors

Everything REQUISITOS §3.8 asks for beyond instrumentation, as code. Nothing
here is clicked together in the UI, so the dashboards are reviewable in a pull
request and reproducible in a fresh organisation.

Separate root module from `../`: it touches no AWS resource and can be applied
and destroyed on its own, independently of the cluster's lifecycle.

## What it creates

**Dashboards**

| Dashboard | Answers |
| --- | --- |
| Work Orders | Daily volume, transitions by destination, average time spent in each status, cancellations |
| Service Health | p95 latency, request rate and errors per service, plus container CPU/memory once on Kubernetes |
| Saga & Integrations | Duration and throughput of each saga step, compensations, RabbitMQ and database span errors |

**Monitors**

| Monitor | Fires when |
| --- | --- |
| Error rate (one per service) | More than 5% of requests fail over 5 minutes |
| Uptime (one per service) | The deployment has no available replica for 5 minutes |
| Saga compensations | More than 3 work orders are cancelled in 15 minutes |

The uptime monitor covers the "healthchecks e uptime" item the requirements
list separately from latency: a pod can be running and still serve nothing if
its readiness probe fails, which the error-rate monitor never sees because no
request reaches it. It is also the only one with `notify_no_data` enabled —
absence of the deployment metric means the workload is gone, not idle. It
depends on `kubernetes_state` metrics, so it only reports once the cluster
exists.

Cancellation is the saga's compensation path, so the second monitor is the
business-level signal that orders are failing between parts reservation, quote
generation and payment — which is what "alertas para falhas no processamento de
ordens de serviço" actually means.

## Where the data comes from

| Query source | Emitted by |
| --- | --- |
| `trace.express.request.*` | `dd-trace` HTTP instrumentation, automatic |
| `trace.saga.*` | the orchestrator's custom spans via `TracingPort.withSpan()` |
| `trace.amqp.command.*`, `trace.pg.query.*` | `dd-trace` amqplib and pg integrations, automatic |
| `work_order.status_changed` | `MetricsPort` in work-order-service, one count per transition, tagged `from` and `to` |
| `work_order.status_duration` | same port, seconds spent in the status being left, tagged `status` |
| `container.cpu.usage`, `container.memory.usage` | Datadog Agent DaemonSet — **only once deployed to Kubernetes** |

The two `work_order.*` metrics exist because APM alone cannot answer "average
time per status": a span measures one request, while a work order sits in
`AWAITING_APPROVAL` across many requests, or none at all. They are emitted
through `tracer.dogstatsd`, so there is no extra dependency.

## Credentials

The provider reads `DD_API_KEY` and `DD_APP_KEY` straight from the environment.
They are deliberately **not** Terraform variables: that keeps them out of any
tfvars file and out of the state.

```sh
export DD_API_KEY=...   # Organization Settings -> API Keys
export DD_APP_KEY=...   # Organization Settings -> Application Keys
```

If the organisation is not on US1, set `datadog_api_url` accordingly
(`https://api.us5.datadoghq.com/`, `https://api.datadoghq.eu/`, …).

## Usage

```sh
# ../bootstrap must have run once — it creates the state bucket (costs nothing)
tofu init
tofu plan
tofu apply

tofu output dashboard_urls
```

Offline check, no credentials needed:

```sh
tofu init -backend=false && tofu validate
```

## Variables worth knowing

| Variable | Default | Purpose |
| --- | --- | --- |
| `env` | `development` | Scopes every query to the `env` tag the services report |
| `services` | the three Nest services | `auth-service` is excluded: it has no Express APM instrumentation |
| `error_rate_threshold` | `0.05` | Fraction of failing requests that trips the monitor |
| `cancellation_threshold` | `3` | Cancellations in 15 minutes that trip the saga monitor |
| `notification_handles` | `[]` | Appended to monitor messages, e.g. `["@slack-oficina"]` |

Set `env = "production"` when pointing this at the cluster.

## Local caveat

Locally the applications run on the host, not in containers, so the Agent
cannot collect their stdout — the JSON logs never reach Datadog and the
container CPU/memory widgets stay empty. Both start working on Kubernetes,
where the Agent runs as a DaemonSet with `containerCollectAll` enabled
(see `../../k8s/shared/datadog/values.yaml`). Traces and the custom metrics
work in both places.
