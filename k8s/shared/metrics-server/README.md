# metrics-server

EKS does not ship `metrics-server`, and nothing else installs it. Without it
the Metrics API does not exist, which means:

- `kubectl top nodes` / `kubectl top pods` fail with "Metrics API not available"
- k9s shows no CPU or memory columns
- **every HPA reports `cpu: <unknown>` and never scales**

That last one matters: the requirements ask for an HPA scaling on CPU and
memory, and an HPA without a metrics source is a manifest that looks right and
does nothing.

It is applied straight from upstream rather than vendored, so the version is
explicit and upgrades are a one-line change:

```sh
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.2/components.yaml
```

Verify:

```sh
kubectl top nodes
kubectl get hpa -n tech-challenge     # TARGETS must show a percentage, not <unknown>
```

Metrics take about a minute to appear after the pod becomes ready — the HPA
needs at least one scrape interval before it reports anything.
