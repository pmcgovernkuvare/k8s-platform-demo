// k6 benchmark: exercises the full request lineage (Kong -> edge-api ->
// order-service -> inventory-service) under increasing load. Thresholds
// encode the same SLOs as the Prometheus alert rules (see
// gitops/infra-values/prometheus/values.yaml) so a benchmark run and a
// production alert would fire on the same numbers - "did we just prove
// we'd have paged ourselves" is a good test of whether the SLOs are real.
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const errorRate = new Rate('order_errors');
const orderLatency = new Trend('order_latency_ms');

const BASE_URL = __ENV.TARGET_URL || 'http://localhost:8080';
const ITEMS = ['widget', 'gadget', 'gizmo', 'doohickey'];

export const options = {
  scenarios: {
    ramping_orders: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '30s', target: 10 },
        { duration: '1m', target: 25 },
        { duration: '1m', target: 25 },
        { duration: '30s', target: 0 },
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.05'],       // < 5% errors, matches HighErrorRate alert
    http_req_duration: ['p(95)<500'],       // p95 < 500ms, matches HighP95Latency alert
    order_errors: ['rate<0.05'],
  },
};

export default function () {
  const item = ITEMS[Math.floor(Math.random() * ITEMS.length)];
  const quantity = Math.floor(Math.random() * 4) + 1;

  const res = http.post(
    `${BASE_URL}/orders`,
    JSON.stringify({ item, quantity }),
    { headers: { 'Content-Type': 'application/json' } }
  );

  const ok = check(res, {
    'status is 201 or a handled error (400/409)': (r) => [201, 400, 409].includes(r.status),
  });
  errorRate.add(!ok);
  orderLatency.add(res.timings.duration);

  sleep(Math.random() * 0.5 + 0.2);
}
