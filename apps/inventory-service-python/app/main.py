"""inventory-service: the innermost hop of the demo's request chain.

Kong -> edge-api (Node) -> order-service (Go) -> inventory-service (Python)

Deliberately the "noisy neighbor" of the three: latency varies per item and
~3% of requests to a low-stock item return a 500, specifically so the
golden-signals dashboard, Tempo traces, and the k6 benchmark all have real
signal to show instead of a flat line.
"""
import os
import random
import time

from fastapi import FastAPI, HTTPException, Response
from fastapi.responses import JSONResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

from app.logging_conf import configure_logging

logger = configure_logging()

# Instrumenting FastAPI is optional at import time so unit tests can run
# without a collector present; enabled for real via ENABLE_OTEL=true, which
# the Helm chart sets by default (see charts/service-template/values.yaml).
if os.environ.get("ENABLE_OTEL", "true").lower() == "true":
    from app.tracing import configure_tracing
    configure_tracing()

app = FastAPI(title="inventory-service")

if os.environ.get("ENABLE_OTEL", "true").lower() == "true":
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
    FastAPIInstrumentor.instrument_app(app)

# Simulated stock catalog. edge-api/order-service only ever ask "is there
# enough of X" - they never see this table.
CATALOG = {
    "widget": 500,
    "gadget": 120,
    "gizmo": 8,       # intentionally low stock -> demonstrates 409s upstream
    "doohickey": 75,
}

REQS = Counter(
    "http_server_requests_total", "Total HTTP requests",
    ["method", "route", "status", "service"],
)
ERRS = Counter(
    "http_server_requests_errors_total", "Total HTTP 5xx responses",
    ["method", "route", "service"],
)
DUR = Histogram(
    "http_server_duration_seconds", "HTTP request duration",
    ["method", "route", "service"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5),
)


def _record(method: str, route: str, status: int, elapsed: float) -> None:
    REQS.labels(method, route, str(status), "inventory-service").inc()
    DUR.labels(method, route, "inventory-service").observe(elapsed)
    if status >= 500:
        ERRS.labels(method, route, "inventory-service").inc()


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/readyz")
def readyz():
    return {"status": "ready"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/inventory/{item}")
def get_inventory(item: str):
    start = time.time()
    route = "/inventory/:item"

    # Simulated variable "database" latency - a bit slower for items with
    # smaller/rarer stock, so the p95/p99 panels aren't flat.
    base_latency = random.uniform(0.01, 0.05)
    if item not in CATALOG:
        base_latency += random.uniform(0.02, 0.08)
    time.sleep(base_latency)

    # ~3% synthetic error rate on any lookup, to keep the error-rate panel
    # and alert rule (HighErrorRate in gitops/infra-values/prometheus/values.yaml)
    # meaningfully non-zero during a demo.
    if random.random() < 0.03:
        elapsed = time.time() - start
        _record("GET", route, 500, elapsed)
        logger.error("simulated inventory backend failure", extra={"item": item})
        raise HTTPException(status_code=500, detail="inventory backend error")

    available = CATALOG.get(item)
    if available is None:
        elapsed = time.time() - start
        _record("GET", route, 404, elapsed)
        return JSONResponse(status_code=404, content={"error": f"unknown item '{item}'"})

    elapsed = time.time() - start
    _record("GET", route, 200, elapsed)
    logger.info("inventory lookup", extra={"item": item, "available": available})
    return {"item": item, "available": available}
