# RFC 0003 — Authentication strategy

**Status:** implemented · 2026-07-28

## Problem

Customers authenticate with nothing but their CPF — there is no password,
because the workshop never collects one. Staff need administrative access. Both
must reach protected APIs across three services, and the challenge requires a
serverless function to issue the credential.

## Constraints

- No user store: a customer "exists" if there is a record in work-order-service
- Three services must verify the credential without calling back to the issuer
- Rotating the mechanism must not require touching three codebases
- The issuer must be a serverless function

## Options

**A. Session tokens in a shared store.** Every verification is a lookup, so the
store becomes a dependency of all three services and a single point of failure.
Rejected.

**B. Self-contained JWT, symmetric (HS256).** Verification is local: no network
call, no shared state. One secret is shared by the issuer and the verifiers.

**C. Self-contained JWT, asymmetric (RS256) with a JWKS endpoint.** Verifiers
hold only the public key, so a leak on a verifier cannot mint tokens. Costs a
JWKS endpoint and key rotation machinery.

## Decision

**Option B**, HS256, with the secret distributed as a Kubernetes Secret rendered
from AWS Secrets Manager.

Asymmetric signing is the better answer at a scale where verifiers are operated
by different teams. Here all four components are deployed by the same pipeline
from the same secret store, so the extra machinery buys separation that does not
exist in practice. Recorded as a deliberate simplification, not an oversight.

## Design

```
POST /auth        { document }        → validate check digits
                                      → GET /customers/lookup
                                      → JWT { sub: <customerId>, role: customer }

POST /auth/admin  X-Api-Key: <key>    → constant-time comparison
                                      → JWT { sub: "admin", role: admin }
```

Both are public routes: they are how a caller obtains a credential.

**The `iss` claim is load-bearing.** Kong matches its consumer credential by
reading `iss: "auth-service"`, and a token without it is rejected at the edge
even with a valid signature.

**Verification happens twice.** Kong rejects unsigned or malformed tokens before
they reach a pod; the service's guards then enforce role and ownership. A
misrouted request never reaches an unauthenticated handler, and a request that
passes the edge is still checked against the rule that matters — a customer
reading someone else's order gets 403 from the service, not from the gateway.

**The admin key is compared in constant time**, checking length first, so the
comparison itself leaks neither the key nor its size.

## Consequences

The shared secret is the system's most sensitive value. It is generated once,
cached, and reused across deployments: rotating it invalidates every live token
*and* desynchronises the Kong consumer credential in the same moment.

The customer lookup means auth-service depends on work-order-service being
reachable. It calls through the gateway rather than the pod, which also means a
new cluster gives it a new hostname — the function must be redeployed with the
current address, or `/auth` silently stops issuing customer tokens.
`scripts/bootstrap-cluster.sh` does this.

## Deployment

The function is deployed by CI on every push to `main`: the workflow assumes an
AWS role through OIDC and runs `serverless deploy`. Kong routes `/auth` to the
API Gateway endpoint in front of it through an `ExternalName` service, so the
gateway stays the single entry point.

Handlers are `async`. The Lambda Node runtime reads a handler that returns a
Promise or one that calls the callback, and a synchronous return value is not
read at all.
