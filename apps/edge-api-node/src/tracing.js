// Loaded via `node --require` before the app starts, so every module
// (express, node-fetch/http) gets auto-instrumented and every outbound
// call to order-service carries the W3C traceparent header, which is how
// Linkerd + the OTel Collector stitch edge-api -> order-service ->
// inventory-service into ONE trace.
'use strict';
const { NodeSDK } = require('@opentelemetry/sdk-node');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-grpc');

const endpoint = process.env.OTEL_EXPORTER_OTLP_ENDPOINT || 'http://localhost:4317';
const serviceName = process.env.OTEL_SERVICE_NAME || 'edge-api';

const sdk = new NodeSDK({
  serviceName,
  traceExporter: new OTLPTraceExporter({ url: endpoint }),
  instrumentations: [getNodeAutoInstrumentations({
    '@opentelemetry/instrumentation-fs': { enabled: false },
  })],
});

sdk.start();

process.on('SIGTERM', () => sdk.shutdown().finally(() => process.exit(0)));
