# k8s-platform-demo

A near-complete, laptop-runnable Kubernetes platform, built to show a small
IT team what "modern container infrastructure" actually looks like day to
day: service mesh, API gateway, full-stack observability (metrics, logs,
traces - all correlated), GitOps deployment with PR-gated promotion between
environments, CI-driven testing, and both a synchronous microservices
request chain and an event-driven serverless piece. Everything here runs
entirely on your machine, no cloud account or cluster required.

This repo is the artifact; `docs/` explains the reasoning you'd want when
presenting it.

## What's in the box

| Layer | Tool | Why |
|---|---|---|
| Local cluster | [k3d](https://k3d.io/) (k3s-in-Docker) | Real Kubernetes, disposable, scriptable, simple single-process bootstrap |
| Service mesh | [Linkerd](https://linkerd.io/) | mTLS everywhere, golden metrics, retries, per-route SLOs |
| API gateway | [Kong](https://konghq.com/) (Gateway API mode) | Single front door, gateway-level metrics, the "edge" |
| GitOps | [ArgoCD](https://argo-cd.readthedocs.io/) | App-of-apps per environment, automated + PR-gated sync |
| Metrics | [Prometheus](https://prometheus.io/) + kube-state-metrics | Golden signals, alerting, SLO rules |
| Logs | [Loki](https://grafana.com/oss/loki/) + Grafana Alloy | Structured JSON logs, trace_id-correlated |
| Traces | [Tempo](https://grafana.com/oss/tempo/) + [OpenTelemetry Collector](https://opentelemetry.io/) | One trace per request, across every hop |
| Dashboards | [Grafana](https://grafana.com/) | Metrics/logs/traces in one pane, click-through correlation |
| Event-driven scaling | [KEDA](https://keda.sh/) + [Azurite](https://github.com/Azure/Azurite) | Local Azure Queue Storage + scale-to-zero Azure Function |
| Packaging | [Helm](https://helm.sh/) | One templated chart, every service, every environment |
| CI/CD | GitHub Actions | Pre-PR checks, PR validation, dev auto-deploy, PR-gated promotion |

Four sample services demonstrate the platform, each in a different
language on purpose - proving the platform is language-agnostic, not
framework-specific:

```
Kong (edge)
  -> edge-api          Node.js / Express      synchronous, edge-facing
       -> order-service     Go                synchronous, business logic
            -> inventory-service  Python / FastAPI   synchronous, "database"
       -> queue-bridge       Python / FastAPI  writes to Azurite queue (fire-and-forget)
            -> notify-function    .NET 8 (Azure Functions, isolated worker)
                                  KEDA-scaled 0->N, triggered by queue depth
```

A single customer-facing HTTP request produces ONE Tempo trace across all
four synchronous+async hops, correlated logs in Loki, and RED metrics in
Prometheus - see [`docs/request-lineage.md`](docs/request-lineage.md) for
the full walkthrough.

## Quickstart

### Prerequisites

Docker Desktop (or equivalent) with **at least 4 CPUs / 8-10GB RAM**
allocated, plus: `k3d`, `kubectl`, `helm`, `linkerd` CLI, `argocd` CLI,
`k6`. On macOS:

```bash
brew install k3d kubectl helm linkerd argocd k6
make prereqs   # verifies all of the above and checks Docker's resource allocation
```

**Alternative: devcontainer.** `.devcontainer/` pins every runtime and CLI
tool this repo touches (Node 20, Go 1.22, Python 3.12, .NET 8, k3d, kubectl,
helm, linkerd CLI, argocd CLI, k6, yamllint, shellcheck, gh) at known-good
versions, and installs each app's dependencies automatically on first build -
open the repo in VS Code and choose "Reopen in Container." Note that k3d's
published ports (`localhost:8080`, etc.) are bound on your actual Mac, not
inside the devcontainer - `curl` those from a regular terminal, or use
`host.docker.internal` from inside the devcontainer's terminal.

> **Note on cluster tooling:** this repo uses [k3d](https://k3d.io/)
> (k3s-in-Docker) rather than kind. k3d's single-process bootstrap sidesteps
> a kind-specific failure mode we hit on corporate-managed Macs, where
> VPN/EDR software intercepting Docker's internal network caused kind's
> multi-phase kubeadm bootstrap to time out on a hardcoded RBAC setup step -
> even with ample CPU/RAM available. See
> [`docs/troubleshooting.md`](docs/troubleshooting.md) if you hit cluster
> creation issues.

### Stand it up

```bash
make up          # k3d cluster + Linkerd + Kong + ArgoCD + Prometheus/Loki/Tempo/Grafana/OTel Collector  (~10-15 min)
make build        # builds and pushes edge-api/order-service/inventory-service/queue-bridge/load-generator images
make gitops        # bootstraps ArgoCD app-of-apps for dev/test/prod - this is the "flip the switch to GitOps" moment
make traffic         # starts the load generator so dashboards aren't empty
make urls              # prints Grafana / ArgoCD / Linkerd viz / Kong URLs + credentials
```

Optional: the event-driven Azure Functions piece (see
[`docs/azure-functions-locally.md`](docs/azure-functions-locally.md)):

```bash
make azure-demo    # KEDA + Azurite + .NET Azure Function, wired to order-service
```

### Verify it

```bash
make test     # unit + integration (proves one trace spans all 3 sync services) + e2e smoke tests
make bench    # k6 load test + a report correlating client-side and server-side latency
```

### Tear down

```bash
make down
```

## What to actually show your team

1. **Open Grafana** (`make urls` for the password) → the "Service Golden
   Signals" dashboard. Traffic is already flowing from the load generator.
2. **Place one order** (`curl -X POST http://localhost:8080/orders -d
   '{"item":"widget","quantity":2}' -H 'content-type: application/json'
   -i`), grab the `x-trace-id` response header, and paste it into Grafana's
   Tempo Explore view. Watch the single trace fan out across three
   languages and (if `make azure-demo` was run) into an async queue and a
   serverless function.
3. **Open ArgoCD** → show the app-of-apps structure, then make a trivial
   change to `gitops/services/catalog/edge-api/values-dev.yaml` (e.g. bump
   `replicaCount`), commit it, and watch ArgoCD reconcile it live with no
   `kubectl` involved.
4. **Open a PR** that changes `charts/service-template` or a `values-test.yaml`
   and show `.github/workflows/pr-validate.yml` running lint, unit tests,
   a Helm render, and a live smoke-deploy to a throwaway kind cluster on
   GitHub's own runners (CI still uses kind there - no local VPN/EDR
   involved, so its simpler bootstrap has never been an issue)
   *before* a human ever reviews it - then show `.github/CODEOWNERS`
   forcing platform-team review on anything touching `test`/`prod`.
5. **Kill a pod** (`kubectl -n dev delete pod -l app=order-service`) and
   watch Linkerd's automatic retries + the golden-signals dashboard absorb
   it without a customer-visible error spike.

## Repository layout

```
.devcontainer/        pinned Node/Go/Python/.NET/k3d/kubectl/helm/linkerd/argocd/k6 dev environment
clusters/            historical kind config (deprecated - see clusters/kind-config.yaml);
                      the live k3d cluster definition is CLI flags in scripts/01-create-cluster.sh
scripts/              numbered, idempotent setup scripts (also what Makefile calls)
charts/service-template/   the ONE Helm chart every service uses
gitops/
  bootstrap/              ArgoCD app-of-apps root template
  apps/{dev,test,prod}/   ArgoCD Application manifests, one per service per env
  services/catalog/       per-service, per-env values files - THE file app teams edit
  infra-values/           Helm values for mesh/gateway/observability/gitops/keda
apps/                 sample service source code (one dir per service, one Dockerfile each)
tests/                unit (co-located in apps/*), integration, e2e, load/benchmark
.github/workflows/    pre-PR, PR-validation, dev auto-deploy, and promotion pipelines
docs/                 the "why", written for presenting this to a team
```

## What's simulated vs. what's real

Being upfront about this matters if you're using this to make a technical
case to your team:

- **Real**: every piece of infrastructure (Linkerd, Kong, ArgoCD,
  Prometheus, Loki, Tempo, Grafana, KEDA, OTel Collector) is the actual
  open-source project, actually running, actually processing real
  requests/traces/logs/metrics. Nothing is mocked or faked.
- **Simplified for a laptop**: dev/test/prod are namespaces on one k3d
  cluster instead of three separate clusters, to fit realistic Docker
  Desktop resource limits. The GitOps repo layout is already fully
  environment-separated, so moving to real per-cluster isolation is a
  `--kubeconfig`/destination-server change, not a redesign - see
  [`docs/scaling-to-multi-cluster.md`](docs/scaling-to-multi-cluster.md).
- **Local emulation**: Azure Queue Storage is provided by Azurite
  (Microsoft's official local emulator), not a real Azure subscription.
  The connection string is a fixed, publicly documented development
  key that only works against a local emulator - swapping in a real
  Storage Account for AKS is a one-line change (see
  [`docs/azure-functions-locally.md`](docs/azure-functions-locally.md)).
- **In-memory demo data**: order-service and inventory-service hold data
  in memory (no real database) - intentional, to keep the demo's moving
  parts focused on the platform, not persistence.

## Toolchain caveat

This repo was generated in an environment without Docker, `k3d`, `helm`,
Go, or a .NET SDK available to compile/run against - the Node.js and
Python services were fully unit-tested during generation (all passing; see
`apps/*/tests`), but the Go and .NET services could not be locally
compiled and should be verified with `go build ./... && go test ./...`
(in `apps/order-service-go`) and `dotnet test` (in
`apps/notify-function-dotnet/tests`) as your first step after cloning.
`ci/pre-pr-check.sh` runs all of this automatically and tells you what's
missing from your machine.