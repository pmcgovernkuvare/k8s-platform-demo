#!/usr/bin/env sh
# Continuously places orders through Kong -> edge-api, so a fresh cluster
# has real, live traces/logs/metrics within seconds instead of a blank
# dashboard. Deliberately mixes valid items, an occasional out-of-stock
# item (gizmo, low stock in inventory-service), and a fully unknown item,
# so the golden-signals dashboard shows a realistic mix of 2xx/4xx/5xx.
set -eu
TARGET="${TARGET_URL:-http://kong-gateway-proxy.platform-gateway.svc.cluster.local}"
ITEMS="widget gadget gizmo doohickey unknown-item"

echo "load-generator: sending orders to ${TARGET}/orders every ${INTERVAL_SECONDS:-1}s"

while true; do
  item=$(echo "$ITEMS" | tr ' ' '\n' | shuf -n1 2>/dev/null || echo "widget")
  qty=$(( (RANDOM % 5) + 1 ))
  curl -s -o /dev/null -w "POST /orders item=%s qty=%s -> %{http_code}\n" \
    -X POST "${TARGET}/orders" \
    -H 'content-type: application/json' \
    -d "{\"item\":\"${item}\",\"quantity\":${qty}}" \
    --max-time 3 || true
  sleep "${INTERVAL_SECONDS:-1}"
done
