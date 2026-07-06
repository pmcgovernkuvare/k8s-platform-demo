# Request Lineage: Following One Order End to End

This is the walkthrough to run live in front of your team - it's the
single best demonstration of "full observability across systems" because
it's not a dashboard, it's one real request.

## 1. Fire the request

```bash
curl -i -X POST http://localhost:8080/orders \
  -H 'content-type: application/json' \
  -d '{"item":"widget","quantity":2}'
```

Response headers include `x-trace-id: <32 hex chars>` - edge-api reads
this straight off the active OpenTelemetry span (see
`apps/edge-api-node/src/index.js`). Copy it.

## 2. What actually happened, hop by hop

1. **Kong** received the request on the `dev` HTTPRoute for edge-api,
   recorded a request-count/latency metric (`kong_http_requests_total`),
   and proxied it into the mesh.
2. **Linkerd's proxy sidecar** on the edge-api pod terminated mTLS,
   recorded a golden-signal metric (`response_total`), and forwarded the
   plaintext request to the edge-api container. It also emitted its own
   span.
3. **edge-api (Node)** validated the body, and via OpenTelemetry's
   auto-instrumentation, propagated the W3C `traceparent` header on its
   outbound call to order-service - this is what keeps everything below
   in the SAME trace instead of starting new ones.
4. **order-service (Go)**, wrapped by `otelhttp`, extracted that
   `traceparent`, created a child span, and called inventory-service to
   check stock (again through the mesh, again mTLS'd, again propagated).
5. **inventory-service (Python)**, instrumented by
   `opentelemetry-instrumentation-fastapi`, created another child span,
   simulated a bit of "database" latency, and returned availability.
   About 3% of the time it deliberately returns a 500, so error-rate
   panels and alert rules have something real to trigger on.
6. **order-service** recorded the order, then - separately from the
   customer-facing response, and without blocking it - POSTed to
   **queue-bridge (Python)**, which enqueued a message onto Azurite's
   `order-notifications` queue, stamping the current trace_id/span_id
   into the message body (Azure Queue Storage messages don't carry HTTP
   trace headers, so this is the hand-off point between synchronous and
   async tracing).
7. If `make azure-demo` has been run: **KEDA** notices the queue depth
   increase and scales the **notify-function** Deployment up from 0.
   The .NET Function's queue trigger fires, reads the trace_id/span_id
   out of the message, and manually re-parents a new `Activity` onto
   that exact trace (`NotifyFunction.cs::StartLinkedActivity`) before
   doing its (simulated) work. This is the async leg of the same trace.
8. **edge-api** returns the order confirmation to the client with the
   `x-trace-id` header.

## 3. See it in Grafana

Open Grafana (`make urls` for the password) → **Explore** → select the
**Tempo** datasource → paste the trace ID. You should see a single trace
with 5-6 spans (3-4 in-mesh HTTP hops, plus the async notify-function span
if deployed), each tagged with `service.name` for its language/service.

Click any span → **Logs for this span** - Tempo's `tracesToLogsV2`
wiring (see `gitops/infra-values/grafana/datasources-configmap.yaml`)
jumps straight into Loki filtered to that `trace_id`, showing the
structured JSON log lines each service wrote for this exact request.

Click **Node graph** on the trace view for a live service dependency
diagram derived from real traffic, not a static architecture doc.

## 4. See it as metrics

The same trace contributes to:

- `http_server_requests_total` / `http_server_duration_seconds` (each
  service's own RED metrics, all identically named across all four
  languages on purpose - the "Service Golden Signals" dashboard doesn't
  care what language emitted them)
- `response_total{classification="success"}` (Linkerd's mesh-level view of
  the same request, useful for spotting a mismatch between "the app thinks
  it succeeded" and "the network actually delivered it")
- Tempo's span-metrics generator also derives RED metrics *from the trace
  data itself* (`gitops/infra-values/tempo/values.yaml`,
  `metricsGenerator.enabled: true`) - a second, independent measurement of
  the same golden signals, useful for catching cases where an app's
  hand-rolled metrics code has a bug the trace data wouldn't share.

## Why this matters for the pitch

The point isn't "we have dashboards." It's that a single customer request,
touching four services in four languages plus an async queue and a
serverless function, produces ONE coherent, correlated record across
traces/logs/metrics with zero manual stitching - and that record exists
because of platform-level defaults (the shared chart, the mesh, the OTel
env vars), not because every team independently got observability right.
That consistency is what a platform team is actually selling.
