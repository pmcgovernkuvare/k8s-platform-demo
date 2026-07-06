"""Structured JSON logging with the active trace_id/span_id stamped into
every line - the third and final piece of the log-correlation story
(edge-api and order-service do the same thing in their own languages).
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
    logger = logging.getLogger("inventory-service")
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
