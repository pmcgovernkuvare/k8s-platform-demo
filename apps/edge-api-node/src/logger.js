'use strict';
// Structured JSON logging with the active trace_id/span_id stamped into
// every line. Grafana Alloy ships these to Loki; the trace_id field is what
// lets you jump from a Tempo trace straight to the matching log lines
// across all three services (see gitops/infra-values/grafana/datasources-configmap.yaml).
const pino = require('pino');
const { trace } = require('@opentelemetry/api');

const logger = pino({
  mixin() {
    const span = trace.getActiveSpan();
    if (!span) return {};
    const ctx = span.spanContext();
    return { trace_id: ctx.traceId, span_id: ctx.spanId };
  },
});

module.exports = logger;
