# Testing & Benchmarking Strategy

## The pyramid, mapped to this repo

| Level | What it proves | Where | Needs a cluster? |
|---|---|---|---|
| Unit | Each service's own logic (request validation, error handling, retry/timeout behavior) in isolation, with upstreams stubbed | `apps/*/tests` (or `apps/*/handlers_test.go`, `apps/notify-function-dotnet/tests`) | No |
| Helm render | Every values file in the catalog produces valid Kubernetes manifests | `helm template` in `ci/pre-pr-check.sh` and `.github/workflows/pr-validate.yml` | No |
| Server-side smoke | The API server accepts every rendered manifest (catches schema drift, missing CRDs, etc.) | `ephemeral-smoke-test` job in `pr-validate.yml`, disposable kind cluster | Yes (ephemeral, per-PR) |
| Integration | One real request produces one real trace spanning all synchronous services | `tests/integration/run.sh` | Yes (the demo cluster) |
| E2E smoke | The whole platform is healthy after a deploy: mesh, gateway, GitOps sync, telemetry pipeline | `tests/e2e/smoke.sh` | Yes |
| Load/benchmark | The system holds its SLOs (p95 < 500ms, error rate < 5%) under realistic concurrent load | `tests/load/` (k6) | Yes |

Run the whole pyramid except benchmarking with `make test`; benchmarking
separately with `make bench` (it takes a few minutes and its own report).

## Why unit tests were run during generation but Go/.NET weren't compiled

This repo was built in an environment with Node.js and Python available
but no Go toolchain or .NET SDK. Every Node.js and Python test in
`apps/edge-api-node/tests`, `apps/inventory-service-python/tests`, and
`apps/queue-bridge-python/tests` was actually executed (all passing) as
part of generating this repo, including deliberately-induced failure
cases (unreachable upstream, malformed payloads, injected errors). The Go
tests (`apps/order-service-go/handlers_test.go`) and .NET tests
(`apps/notify-function-dotnet/tests/OrderNotificationTests.cs`) were
written with the same rigor and the same "test the failure paths, not
just the happy path" standard, but could not be compiled/run here - treat
them as a strong first draft, and run `go test ./...` /
`dotnet test` as literally the first command after cloning. `ci/pre-pr-check.sh`
does this automatically and tells you what's missing from your machine.

## Benchmark thresholds are alert thresholds

`tests/load/k6-order-flow.js`'s thresholds (`p(95)<500`, error rate `<5%`)
are the same numbers as the `HighP95Latency`/`HighErrorRate` Prometheus
alert rules in `gitops/infra-values/prometheus/values.yaml`. Running the
benchmark and asking "would this have paged us" is a good way to find out
whether your SLOs are real numbers or aspirational ones - if the
benchmark passes comfortably under your alert thresholds, either your
alerts are too loose or your system has real headroom; if it's a photo
finish, you've just found your actual capacity ceiling.

## What the benchmark report shows

`make bench` produces `tests/results/benchmark-report-<timestamp>.md`
with three things side by side: k6's client-side view of latency/errors,
Prometheus' server-side p95 for the same time window (pulled via the
Prometheus HTTP API), and pod-level CPU usage during the run. Comparing
client-side vs. server-side latency is a quick sanity check on whether
your observability pipeline is trustworthy - if they disagree by a lot,
something between your laptop and Kong (or a slow dashboard query) is
lying to you.
