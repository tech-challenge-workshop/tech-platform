# ADR 0004 — Kong routing expressed as Ingress, not Gateway API

**Status:** accepted · 2026-07-28
**Supersedes:** the Gateway API manifests written on 2026-07-27

## Context

Kong is the single entry point. Its routes can be declared either as Gateway API
resources (`Gateway` + `HTTPRoute`) or as plain `Ingress`. Gateway API is the
newer model and was the first choice.

## Decision

Plain `Ingress` with Kong annotations.

## Rationale

Gateway API did not work, and the failure gave nothing to act on:

- the Gateway API CRDs are not installed by the Kong chart and had to be applied
  separately — a prerequisite that is easy to miss and fails with
  `no matches for kind "HTTPRoute"`
- the controller starts its Gateway informers only if the CRDs exist at boot, so
  installing them afterwards requires restarting it
- after that, the controller **accepted the GatewayClass** and still left every
  `Gateway` at `Accepted=Unknown · Waiting for controller`, with correct RBAC
  (verified with `kubectl auth can-i`), a correct publish service, and **no
  error in its logs**

Ingress is KIC's primary and best-tested mode, needs no extra CRDs, and
expresses exactly the same path-based routing with the same plugin annotations.
The routing model was not what the project was demonstrating, and it was
consuming time on a cluster billing by the hour.

## Consequences

Routing is described with an older API. The rules, the plugins and the public
and private split are identical, so nothing about the system's behaviour
changed — only the resource kind.

`konghq.com/preserve-host: "false"` had to be set on `/auth`: API Gateway
rejects any Host that is not its own `execute-api` domain, so forwarding the
load balancer's hostname returned 403 before the Lambda was invoked. Gateway API
would have needed the same thing under a different name.

## Alternatives

**Keep debugging Gateway API.** Possible, and would likely have been a
misconfiguration or a version mismatch. Not worth the time given no functional
difference at the end of it.
