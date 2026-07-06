"""Same structured-JSON-plus-trace_id logging pattern as inventory-service -
kept as a near-duplicate on purpose (each service owns its own code, no
shared library) rather than sharing library, mirroring how independent
teams' services would actually look in this platform.
"""
import logging
import sys

from opentelemetry import trace
from pythonjsonlogger import jsonlogger


class TraceContextFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        span = trace.get_current_span()
        ctx = span.get_span_context()
        if ctx and ctx.is_valid:
            record.trace_id = format(ctx.trace_id, "032x")
            record.span_id = format(ctx.span_id, "016x")
        return True


def configure_logging() -> logging.Logger:
    logger = logging.getLogger("queue-bridge")
    logger.setLevel(logging.INFO)
    handler = logging.StreamHandler(sys.stdout)
    fmt = jsonlogger.JsonFormatter(
        "%(asctime)s %(levelname)s %(name)s %(message)s %(trace_id)s %(span_id)s"
    )
    handler.setFormatter(fmt)
    handler.addFilter(TraceContextFilter())
    logger.handlers = [handler]
    logger.propagate = False
    return logger
