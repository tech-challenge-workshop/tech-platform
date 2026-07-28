# ADR 0004 — Kong routing expressed as Ingress, not Gateway API

**Status:** accepted · 2026-07-28

## Context

Kong is the single entry point. Its routes can be declared either as Gateway API
resources (`Gateway` + `HTTPRoute`) or as plain `Ingress`.

The routing needs are path-based: six route groups, a JWT plugin and a rate
limit on the private ones, nothing on the three public ones. No traffic
splitting, no header matching, no cross-namespace delegation.

## Decision

Plain `Ingress` with Kong annotations.

## Rationale

Ingress is the Kong Ingress Controller's primary and best-tested mode. It
expresses exactly the routing this system needs, with the same plugin
annotations, and requires no CRDs beyond the ones the Kong chart installs.

Gateway API is the newer and more expressive model, and it is the right choice
when routes are delegated across teams and namespaces or when traffic splitting
matters. Neither applies here: one team owns every route, and they are a flat
list of paths. The extra moving parts — a separate CRD bundle that must be
installed before the controller starts — buy nothing at this scale.

## Consequences

Routing is described with an older API. The rules, the plugins and the
public/private split are identical, so nothing about the system's behaviour
depends on the choice.

`/auth` carries `konghq.com/preserve-host: "false"` because its upstream is API
Gateway, which only accepts its own `execute-api` domain in the Host header.
Gateway API would need the same thing under a different name.

## Alternatives

**Gateway API.** Worth revisiting if routes ever need to be delegated to
separate teams or namespaces, which is where its model pays for itself.
