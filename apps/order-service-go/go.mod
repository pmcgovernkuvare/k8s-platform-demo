module github.com/example/platform-demo/order-service

go 1.22

require (
	github.com/prometheus/client_golang v1.19.1
	go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp v0.53.0
	go.opentelemetry.io/otel v1.28.0
	go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc v1.28.0
	go.opentelemetry.io/otel/sdk v1.28.0
	go.opentelemetry.io/otel/trace v1.28.0
)

// After cloning: `go mod tidy` will resolve transitive deps and generate
// go.sum. Not vendored here to keep the repo small; CI runs `go mod tidy`
// as part of the build step and fails the PR if go.mod/go.sum drift.
