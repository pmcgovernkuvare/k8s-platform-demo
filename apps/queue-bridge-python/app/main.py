"""queue-bridge: the seam between the synchronous request-path services
(edge-api -> order-service -> inventory-service) and the event-driven side
of the demo (Azurite queue -> KEDA-scaled .NET Azure Function).

order-service calls POST /notifications after successfully creating an
order. This is a fire-and-forget side effect - a slow or failed queue
enqueue should never fail the customer's order, so failures here are
logged and swallowed (returned as 202 either way; see docs/request-lineage.md
for the reasoning).
"""
import base64
import json
import os
import time
from datetime import datetime, timezone

from fastapi import FastAPI, Response
from opentelemetry import trace
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel

from app.logging_conf import configure_logging
from app.queue_client import get_queue_client

logger = configure_logging()

if os.environ.get("ENABLE_OTEL", "true").lower() == "true":
    from app.tracing import configure_tracing
    configure_tracing()

app = FastAPI(title="queue-bridge")

if os.environ.get("ENABLE_OTEL", "true").lower() == "true":
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
    FastAPIInstrumentor.instrument_app(app)

REQS = Counter("http_server_requests_total", "Total HTTP requests", ["method", "route", "status", "service"])
ERRS = Counter("http_server_requests_errors_total", "Total HTTP 5xx responses", ["method", "route", "service"])
DUR = Histogram(
    "http_server_duration_seconds", "HTTP request duration", ["method", "route", "service"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5),
)
ENQUEUED = Counter("notifications_enqueued_total", "Notifications successfully enqueued to Azurite")
ENQUEUE_FAILURES = Counter("notifications_enqueue_failures_total", "Notifications that failed to enqueue")


class NotificationRequest(BaseModel):
    orderId: str
    item: str
    quantity: int


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/readyz")
def readyz():
    return {"status": "ready"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


def _current_trace_context() -> dict:
    """Pulls the active span's trace_id/span_id (hex, W3C-style) so the
    downstream .NET Azure Function can manually re-parent an Activity onto
    THIS trace, even though Azure Queue Storage messages don't carry HTTP
    trace headers. See apps/notify-function-dotnet/NotifyFunction.cs.
    """
    span = trace.get_current_span()
    ctx = span.get_span_context()
    if ctx and ctx.is_valid:
        return {"traceId": format(ctx.trace_id, "032x"), "spanId": format(ctx.span_id, "016x")}
    return {"traceId": "", "spanId": ""}


def enqueue_notification(payload: dict) -> None:
    client = get_queue_client()
    body = json.dumps(payload)
    # Azure Storage Queue messages are base64-encoded by convention (and
    # Azure Functions' queue trigger binding decodes them the same way).
    encoded = base64.b64encode(body.encode("utf-8")).decode("ascii")
    client.send_message(encoded)


@app.post("/notifications", status_code=202)
def create_notification(req: NotificationRequest):
    start = time.time()
    route = "/notifications"
    payload = {
        "orderId": req.orderId,
        "item": req.item,
        "quantity": req.quantity,
        "enqueuedAt": datetime.now(timezone.utc).isoformat(),
        **_current_trace_context(),
    }
    try:
        enqueue_notification(payload)
        ENQUEUED.inc()
        logger.info("notification enqueued", extra={"orderId": req.orderId})
        status = 202
    except Exception as exc:  # noqa: BLE001 - deliberately broad: never fail the caller
        ENQUEUE_FAILURES.inc()
        logger.error("failed to enqueue notification", extra={"orderId": req.orderId, "error": str(exc)})
        status = 202  # still 202: this is a best-effort side channel, not part of the order's critical path

    elapsed = time.time() - start
    REQS.labels("POST", route, str(status), "queue-bridge").inc()
    DUR.labels("POST", route, "queue-bridge").observe(elapsed)
    return {"status": "accepted"}
