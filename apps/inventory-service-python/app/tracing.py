"""OTel SDK setup for inventory-service - the third and final hop in the
request lineage (edge-api -> order-service -> inventory-service). This is
also deliberately the service where we inject a small amount of latency
variance and a small error rate, so the golden-signals dashboard and the
benchmark suite have something real to show.
"""
import os

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import SERVICE_NAME, Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor


def configure_tracing() -> None:
    endpoint = os.environ.get(
        "OTEL_EXPORTER_OTLP_ENDPOINT",
        "http://otel-collector.platform-observability.svc.cluster.local:4317",
    )
    service_name = os.environ.get("OTEL_SERVICE_NAME", "inventory-service")

    provider = TracerProvider(resource=Resource.create({SERVICE_NAME: service_name}))
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=endpoint)))
    trace.set_tracer_provider(provider)
