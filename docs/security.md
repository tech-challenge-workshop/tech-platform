# Vulnerability analysis

Scans run on 2026-07-28 against the code and against the running environment.
Findings are real. Five open items are listed with what was decided about
each.

## What was scanned, and how

| Layer | Tool | Scope |
| --- | --- | --- |
| Static code analysis (SAST) | SonarCloud | the three microservices, on every push |
| Dependency analysis (SCA) | `pnpm audit` | all four repositories |
| Running application (DAST) | OWASP ZAP baseline | the live gateway on EKS |

SAST reads the source, SCA reads the dependency tree, DAST attacks the deployed
system. They find different classes of problem, which is why all three are here.

## Results

### SonarCloud

| Service | Vulnerabilities | Security hotspots | Coverage |
| --- | :---: | :---: | :---: |
| work-order-service | 0 | 0 | 94.5% |
| execution-service | 0 | 0 | 93.8% |
| billing-service | 0 | 0 | 94.8% |

Runs on every push and gates the pipeline. Live reports:
[work-order](https://sonarcloud.io/summary/new_code?id=tech-challenge-workshop_work-order-service) ·
[execution](https://sonarcloud.io/summary/new_code?id=tech-challenge-workshop_execution-service) ·
[billing](https://sonarcloud.io/summary/new_code?id=tech-challenge-workshop_billing-service)

`auth-service` has no SonarCloud project: the requirements scope code-quality
analysis to the microservices, and the challenge classifies the serverless
authentication function as an edge component. Its 80% coverage gate still runs.

### Dependencies

The runtime images are built from production dependencies only — `pnpm prune
--prod` in the Dockerfile, and an esbuild bundle for the Lambda — so a CVE in
the build toolchain cannot reach a deployed artifact. The two scopes are
reported separately because they mean different things.

**What ships — clean, and gated in CI:**

| Repository | Production dependencies |
| --- | --- |
| work-order-service | no known vulnerabilities |
| billing-service | no known vulnerabilities |
| execution-service | no known vulnerabilities |
| auth-service | no known vulnerabilities |

Getting there took four `pnpm` overrides. The first scan found **7
vulnerabilities in the three microservices, 4 of them high**, all reaching
production through one chain — `@prisma/client → prisma → @prisma/dev`:

| Package | Severity | Issue | Pinned to |
| --- | :---: | --- | --- |
| `fast-uri` | high | host confusion via a literal | `>=3.1.4` |
| `@hono/node-server` | moderate | middleware bypass via repeated headers | `>=2.0.5` |
| `@hono/node-server` | moderate | path traversal | `>=2.0.5` |
| `valibot` | moderate | `flatten()` throws on a `record()` issue path | `>=1.4.2` |
| `brace-expansion` | high | denial of service via unbounded expansion | `>=5.0.8` |

**Build toolchain — reported, not enforced:**

`auth-service` carries **22 findings, 2 critical**, every one from the Serverless
Framework v3 dependency tree (`decompress`, `tar` and others). None of them ship:
the Lambda is an esbuild bundle of `src/` plus production dependencies, and
`pnpm audit --prod` on that repository is clean.

They cannot be fixed with an override — the fix is Serverless Framework v4,
which is a migration rather than a version bump, and out of scope here.

**Recorded as an open item, not as "no vulnerabilities".**

### OWASP ZAP baseline

```
FAIL: 0    WARN: 2    PASS: 65
```

Two findings, both accepted:

**1 · Server leaks version information — Low**
`Server: kong/3.9.3` on every response. An attacker learns the gateway version
and can look up known issues for it. Kong can suppress the header with
`headers = off`, at the cost of losing a diagnostic that has been useful all
through this project. **Accepted for this environment; suppress it before any
real exposure.**

**2 · Storable and cacheable content — Informational**
Reported on the 404 responses for `/`, `/robots.txt` and `/sitemap.xml`. No API
route returns cacheable content, and none of those paths exists. **No action.**

The scan ran unauthenticated, so it exercised the public surface: the auth
endpoints and the two service-to-service routes. Everything else answered 401,
which is the intended behaviour and is what the 65 passes reflect.

---

## OWASP Top 10 (2021)

What the system does about each category.

### A01 · Broken Access Control

Two independent checks. Kong's `jwt` plugin rejects unsigned or malformed tokens
at the edge, before a request reaches a pod. Each service then applies
`JwtAuthGuard` and `RolesGuard` and enforces the rule that matters:

- administrative routes require `role: admin`
- approving or rejecting a quote requires `role: customer` — an admin token gets
  **403**, because accepting a quote is the customer's decision
- a customer reading a work order gets **403** if it is not theirs

Verified in [`scripts/smoke-test.sh`](../scripts/smoke-test.sh): 401 without a
token on four routes, 403 for the admin approving.

**Residual risk:** the two public service-to-service routes
(`/customers/lookup`, `/parts/prices`) are reachable by anyone who knows the
gateway address. Both return existence or price only — no personal data, no
stock levels. They are public because they are called before a token exists in
that flow.

### A02 · Cryptographic Failures

TLS on every hop that leaves the cluster: `amqps` to Amazon MQ,
`sslmode=verify-full` to RDS against the Amazon CA bundle, TLS to Atlas.

Database passwords are generated by RDS into Secrets Manager and never appear in
the OpenTofu state as plaintext. Atlas and MQ credentials are generated with
`random_password` and written to Secrets Manager.

JWTs are HS256. Asymmetric signing would be better where verifiers are operated
by different teams; here all four components come from the same pipeline and the
same secret store. Recorded as a deliberate trade-off in
[RFC 0003](rfc/0003-authentication.md).

**Gap:** the gateway serves **HTTP, not HTTPS**. There is no domain and no
certificate, so tokens travel in clear between client and load balancer. This is
the most significant open item and would be fixed with ACM plus a Route 53
record before any real use.

### A03 · Injection

Prisma and Mongoose parameterise every query; no string concatenation reaches a
database. Input is validated twice: `class-validator` on the DTO and again in
the domain, where CPF, CNPJ and plate are value objects that refuse to exist in
an invalid state. Environment variables are parsed with Zod at boot, so a
misconfigured service fails to start instead of failing at the first request.

### A04 · Insecure Design

The saga is the design answer to partial failure: every step has a compensating
action, and `SagaInstance` records which steps ran so nothing is undone twice or
undone when it never happened. The branches are executable
[BDD scenarios](https://github.com/tech-challenge-workshop/work-order-service/blob/main/tests/bdd/features/work-order-saga.feature).

Rate limiting (60 rpm) is applied at the gateway on every private route.

### A05 · Security Misconfiguration

Infrastructure is code and reviewed in pull requests. Data stores accept traffic
only from the EKS node security group — no path from the internet. Atlas allows
exactly one address, the cluster's NAT gateway. The Kong admin API is a headless
`ClusterIP`; only the proxy gets a load balancer. The state bucket blocks public
access and is encrypted.

**Finding:** the `Server` header exposes the Kong version. See above.

### A06 · Vulnerable and Outdated Components

`pnpm audit --prod --audit-level=high` gates every pipeline, so a CVE in
anything that ships stops the release. The first run found seven, four of them
high; all are pinned out with overrides and the production trees are clean.

The full audit runs alongside without blocking, so the build toolchain stays
visible. `auth-service` has 22 findings there, 2 critical, all from Serverless
Framework v3 and none of them shipped.

Dependencies are pinned and lock files committed. Renovate or Dependabot is
**not** configured — a gap for a long-lived project, less so for one with a
fixed delivery date.

### A07 · Identification and Authentication Failures

There are no passwords to leak: customers authenticate with a CPF that is
verified against existing data, and the admin key is compared in **constant
time**, checking length first so the comparison leaks neither the key nor its
size.

Tokens expire in 24h and carry `iss: "auth-service"`, which Kong uses to match
its consumer credential — a token without it is rejected at the edge even with a
valid signature.

**Fixed during this work.** The admin handler was synchronous, and the Lambda
Node runtime only reads a handler that returns a Promise or calls the callback.
Its return value was discarded and **every request resolved to HTTP 200 with a
null body — including requests carrying the wrong API key**. A silent
authentication bypass, with no error and no log. It was invisible while the
service ran as a container, because that path calls the function directly and
reads the return. Found by comparing the two endpoints: `/auth` is async and
worked, `/auth/admin` did not.

### A08 · Software and Data Integrity Failures

Images are pinned to the commit SHA, not to a mutable tag, so a rollback names
exactly one commit. The registry is private and pulled with a token scoped to
`read:packages` only. CI authenticates to AWS through **OIDC** — there is no
long-lived access key anywhere in the pipeline — and the role's trust policy
only accepts the default branch of the four repositories. In AWS it can do
exactly one thing, `eks:DescribeCluster`; everything inside the cluster comes
from an access entry scoped to a single namespace.

`main` is protected on all five repositories: no direct pushes, pull request
with checks required.

### A09 · Security Logging and Monitoring Failures

Structured JSON logs correlated by `dd.trace_id`, a distributed trace spanning
all three services, three dashboards and seven monitors — error rate and uptime
per service, plus a business-level alert on saga compensations.

**Gap:** no alert on authentication failures specifically. A burst of 401s at
the gateway is the signal that would catch credential stuffing, and it is not
being watched.

### A10 · Server-Side Request Forgery

The only outbound call driven by input is `auth-service` reaching the customer
lookup, and its URL is fixed configuration — no part of the request body reaches
it. Workloads sit in private subnets and leave through one NAT gateway.

---

## Open items

| # | Finding | Severity | Decision |
| --- | --- | :---: | --- |
| 1 | Gateway serves HTTP, not HTTPS | **High** | Needs a domain and an ACM certificate. Blocking for real use, accepted for a demo environment. |
| 2 | `Server` header exposes the Kong version | Low | Accepted; suppress with `headers = off` before real exposure. |
| 3 | No alert on authentication failures | Low | Worth adding to the Datadog stack — a 401 burst is the credential-stuffing signal. |
| 4 | No automated dependency updates | Low | Renovate or Dependabot. Matters for a long-lived project. |
| 5 | 22 CVEs in the Serverless Framework v3 toolchain, 2 critical | Low | None ship — the Lambda bundle carries production dependencies only. The fix is migrating to Serverless v4, out of scope here. |

## Reproducing

```sh
# SCA — what ships (this is what CI gates on)
pnpm audit --prod --audit-level=high

# SCA — everything, including the build toolchain
pnpm audit

# DAST — against the live gateway
docker run --rm -v "$PWD:/zap/wrk/:rw" -t ghcr.io/zaproxy/zaproxy:stable \
  zap-baseline.py -t "http://$GATEWAY" -r zap.html -I
```

SAST runs on every push; see the SonarCloud links above.
