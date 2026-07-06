'use strict';
const test = require('node:test');
const assert = require('node:assert');
const http = require('node:http');

// The app module is required ONCE for the whole file (prom-client's
// registry is a process-level singleton, and index.js reads
// ORDER_SERVICE_URL per-request rather than at load time) so tests can
// swap the stub upstream via env var without re-registering metrics.
const app = require('../src/index.js');

function withStubOrderService(handler, fn) {
  return async () => {
    const stub = http.createServer(handler);
    await new Promise((resolve) => stub.listen(0, resolve));
    const { port } = stub.address();
    const previous = process.env.ORDER_SERVICE_URL;
    process.env.ORDER_SERVICE_URL = `http://localhost:${port}`;
    try {
      await fn(app);
    } finally {
      process.env.ORDER_SERVICE_URL = previous;
      await new Promise((resolve) => stub.close(resolve));
    }
  };
}

test('GET /healthz returns ok', async () => {
  const server = app.listen(0);
  const { port } = server.address();
  const res = await fetch(`http://localhost:${port}/healthz`);
  assert.strictEqual(res.status, 200);
  const body = await res.json();
  assert.strictEqual(body.status, 'ok');
  server.close();
});

test('GET /metrics exposes Prometheus format', async () => {
  const server = app.listen(0);
  const { port } = server.address();
  const res = await fetch(`http://localhost:${port}/metrics`);
  assert.strictEqual(res.status, 200);
  const body = await res.text();
  assert.match(body, /http_server_requests_total/);
  server.close();
});

test('POST /orders with missing fields returns 400', async () => {
  const server = app.listen(0);
  const { port } = server.address();
  const res = await fetch(`http://localhost:${port}/orders`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({}),
  });
  assert.strictEqual(res.status, 400);
  server.close();
});

test('POST /orders proxies to order-service and returns its response', withStubOrderService(
  (req, res) => {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      const parsed = JSON.parse(body);
      res.writeHead(201, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ orderId: 'ord-1', item: parsed.item, quantity: parsed.quantity }));
    });
  },
  async () => {
    const server = app.listen(0);
    const { port } = server.address();
    const res = await fetch(`http://localhost:${port}/orders`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ item: 'widget', quantity: 3 }),
    });
    assert.strictEqual(res.status, 201);
    const out = await res.json();
    assert.strictEqual(out.orderId, 'ord-1');
    server.close();
  }
));

test('POST /orders returns 502 when order-service is unreachable', async () => {
  const previous = process.env.ORDER_SERVICE_URL;
  process.env.ORDER_SERVICE_URL = 'http://127.0.0.1:1'; // nothing listens here
  const server = app.listen(0);
  const { port } = server.address();
  const res = await fetch(`http://localhost:${port}/orders`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ item: 'widget', quantity: 1 }),
  });
  assert.strictEqual(res.status, 502);
  process.env.ORDER_SERVICE_URL = previous;
  server.close();
});
