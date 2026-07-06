#!/usr/bin/env bash
# Integration test: proves the FULL request lineage works against the live
# cluster - not mocks. Places a real order through Kong, follows it through
# edge-api -> order-service -> inventory-service, then verifies the
# resulting trace actually landed in Tempo with all three service names
# and one continuous trace_id (the entire point of the platform).
set -euo pipefail
cd "$(dirname "$0")/../.."
KCTX="k3d-platform-demo"
NS="${TEST_NAMESPACE:-dev}"

echo "== Port-forwarding Kong proxy and Tempo =="
kubectl --context "$KCTX" -n platform-gateway port-forward svc/kong-gateway-proxy 18080:80 >/tmp/pf-kong.log 2>&1 &
KONG_PID=$!
kubectl --context "$KCTX" -n platform-observability port-forward svc/tempo 13100:3100 >/tmp/pf-tempo.log 2>&1 &
TEMPO_PID=$!
trap 'kill $KONG_PID $TEMPO_PID 2>/dev/null || true' EXIT
sleep 3

echo "== Placing an order through Kong -> edge-api =="
RESP=$(curl -s -i -X POST "http://localhost:18080/orders" \
  -H 'content-type: application/json' \
  -d '{"item":"widget","quantity":2}')

echo "$RESP"
TRACE_ID=$(echo "$RESP" | grep -i '^x-trace-id:' | awk '{print $2}' | tr -d '\r')
STATUS=$(echo "$RESP" | head -1 | awk '{print $2}')

if [ "$STATUS" != "201" ]; then
  echo "FAIL: expected 201, got $STATUS"
  exit 1
fi
if [ -z "$TRACE_ID" ]; then
  echo "FAIL: no x-trace-id header on response - is OTel instrumentation running?"
  exit 1
fi
echo "Order placed. trace_id=$TRACE_ID"

echo "== Waiting for the trace to land in Tempo (spans are batch-exported) =="
FOUND=0
for i in $(seq 1 15); do
  sleep 2
  TRACE_JSON=$(curl -s "http://localhost:13100/api/traces/${TRACE_ID}" || true)
  if echo "$TRACE_JSON" | grep -q "edge-api" && \
     echo "$TRACE_JSON" | grep -q "order-service" && \
     echo "$TRACE_JSON" | grep -q "inventory-service"; then
    FOUND=1
    break
  fi
done

if [ "$FOUND" -ne 1 ]; then
  echo "FAIL: trace $TRACE_ID never showed all three services in Tempo within 30s"
  exit 1
fi
echo "PASS: trace $TRACE_ID contains edge-api, order-service, and inventory-service spans."
echo "View it: open Grafana -> Explore -> Tempo -> search trace_id=$TRACE_ID"