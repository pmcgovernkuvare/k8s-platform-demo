# service-template

The one chart every team's service uses. Infra/devops owns this chart
(changes go through PR review here, same as everything else). App teams
never touch templates/ - they only ever write a values file:

    gitops/services/catalog/<service>/values-<env>.yaml

That's the entire "shift-left" contract: a developer who wants to ship a new
service adds one small values file (image, port, resources, route, team
label) and one ArgoCD Application pointing at it (see
gitops/apps/<env>/<service>.yaml). No YAML wrangling, no copy-pasted
Deployment boilerplate, no forgetting a NetworkPolicy or a ServiceMonitor -
this chart supplies all of it consistently, and CI (see ci/) proves the
values file is valid before a human ever reviews the PR.

Render locally to see what a service gets, without a cluster:

    helm template demo . -f ../../gitops/services/catalog/edge-api/values-dev.yaml \
      --namespace dev

What you get per service, for free:
- Deployment with liveness/readiness probes, resource requests/limits
- HorizontalPodAutoscaler + PodDisruptionBudget
- NetworkPolicy scoped to only the namespaces that should reach it
- ServiceMonitor (Prometheus scrape config)
- Linkerd mesh injection + optional ServiceProfile for per-route metrics/retries
- OTel env vars pre-wired to the shared collector
- Optional Kong HTTPRoute for edge-facing services
