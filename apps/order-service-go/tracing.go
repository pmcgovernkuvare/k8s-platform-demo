package main

import (
	"context"
	"log/slog"
	"os"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
	"go.opentelemetry.io/otel/sdk/resource"
)

// setupTracing wires up the OTel SDK to export spans to the shared
// collector. Combined with otelhttp (see main.go), every inbound request
// AND every outbound call to inventory-service gets a span, and the
// traceparent header is propagated automatically - this is the middle hop
// of the edge-api -> order-service -> inventory-service lineage.
func setupTracing(ctx context.Context) (func(context.Context) error, error) {
	endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if endpoint == "" {
		endpoint = "otel-collector.platform-observability.svc.cluster.local:4317"
	}

	exporter, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithEndpoint(stripScheme(endpoint)),
		otlptracegrpc.WithInsecure(),
		otlptracegrpc.WithTimeout(5*time.Second),
	)
	if err != nil {
		return nil, err
	}

	serviceName := os.Getenv("OTEL_SERVICE_NAME")
	if serviceName == "" {
		serviceName = "order-service"
	}

	res, err := resource.New(ctx,
		resource.WithAttributes(semconv.ServiceName(serviceName)),
	)
	if err != nil {
		return nil, err
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{},
	))

	slog.Info("tracing initialized", "endpoint", endpoint, "service", serviceName)
	return tp.Shutdown, nil
}

func stripScheme(s string) string {
	for _, p := range []string{"http://", "https://"} {
		if len(s) >= len(p) && s[:len(p)] == p {
			return s[len(p):]
		}
	}
	return s
}
