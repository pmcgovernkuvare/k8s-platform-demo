'use strict';
const express = require('express');
const fetch = require('node-fetch');
const pinoHttp = require('pino-http');
const client = require('prom-client');
const { trace } = require('@opentelemetry/api');
const logger = require('./logger');

const app = express();
app.use(express.json());
app.use(pinoHttp({ logger }));

// Surface the trace_id on every response. This is purely a demo/debugging
// convenience - `curl -i` (or the browser network tab) shows you exactly
// which Tempo trace a given request produced, no log-digging required:
//   curl -i http://localhost:8080/orders/... | grep x-trace-id
app.use((req, res, next) => {
  const span = trace.getActiveSpan();
  if (span) {
    res.setHeader('x-trace-id', span.spanContext().traceId);
  }
  next();
});

const PORT = process.env.PORT || 3000;
// Read at request time (not module-load time) so this module can safely be
// require()'d once and reused across tests that point at different stub
// upstreams via env var - and so a real pod picks up an env change on
// restart without any other code change.
const orderServiceUrl = () => process.env.ORDER_SERVICE_URL || 'http://localhost:8080';

// prom-client's default Registry is a module-level singleton, so guard
// metric registration to be idempotent - this module may legitimately be
// require()'d more than once in the same process (e.g. test suites).
client.collectDefaultMetrics({ register: client.register });
const metric = (Ctor, name, opts) =>
  client.register.getSingleMetric(name) || new Ctor({ name, ...opts });
const httpRequests = metric(client.Counter, 'http_server_requests_total', {
  help: 'Total HTTP requests', labelNames: ['method', 'route', 'status', 'service'],
});
const httpErrors = metric(client.Counter, 'http_server_requests_errors_total', {
  help: 'Total HTTP error responses (5xx)', labelNames: ['method', 'route', 'service'],
});
const httpDuration = metric(client.Histogram, 'http_server_duration_seconds', {
  help: 'HTTP request duration', labelNames: ['method', 'route', 'service'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
});

app.use((req, res, next) => {
  const end = httpDuration.startTimer({ method: req.method, route: req.path, service: 'edge-api' });
  res.on('finish', () => {
    httpRequests.inc({ method: req.method, route: req.path, status: res.statusCode, service: 'edge-api' });
    if (res.statusCode >= 500) httpErrors.inc({ method: req.method, route: req.path, service: 'edge-api' });
    end();
  });
  next();
});

app.get('/healthz', (_req, res) => res.status(200).json({ status: 'ok' }));
app.get('/readyz', (_req, res) => res.status(200).json({ status: 'ready' }));
app.get('/metrics', async (_req, res) => {
  res.set('Content-Type', client.register.contentType);
  res.end(await client.register.metrics());
});

// Entry point of the whole request lineage demo: a client hits Kong,
// Kong routes here, edge-api calls order-service, order-service calls
// inventory-service. Every hop is meshed by Linkerd and traced by OTel.
app.post('/orders', async (req, res) => {
  const { item, quantity } = req.body || {};
  if (!item || !quantity) {
    return res.status(400).json({ error: 'item and quantity are required' });
  }
  try {
    const upstream = await fetch(`${orderServiceUrl()}/orders`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ item, quantity }),
    });
    const body = await upstream.json();
    req.log.info({ item, quantity, upstreamStatus: upstream.status }, 'placed order');
    return res.status(upstream.status).json(body);
  } catch (err) {
    req.log.error({ err }, 'order-service call failed');
    return res.status(502).json({ error: 'order-service unavailable' });
  }
});

app.get('/orders/:id', async (req, res) => {
  try {
    const upstream = await fetch(`${orderServiceUrl()}/orders/${req.params.id}`);
    const body = await upstream.json();
    return res.status(upstream.status).json(body);
  } catch (err) {
    req.log.error({ err }, 'order-service call failed');
    return res.status(502).json({ error: 'order-service unavailable' });
  }
});

if (require.main === module) {
  app.listen(PORT, () => logger.info({ port: PORT }, 'edge-api listening'));
}

module.exports = app;
