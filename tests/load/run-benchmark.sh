#!/usr/bin/env bash
# Runs the k6 benchmark against the live cluster and writes a markdown
# report correlating k6's client-side view (latency/error rate as the
# customer experiences it) with Linkerd's server-side golden metrics and
# Prometheus resource usage for the SAME time window - "did the mesh see
# what the load test saw" is a good sanity check that your observability
# pipeline isn't lying to you.
set -euo pipefail
cd "$(dirname "$0")/../.."
KCTX="k3d-platform-demo"
OUT_DIR="tests/results"
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT_DIR"

command -v k6 >/dev/null 2>&1 || { echo "k6 not installed - brew install k6"; exit 1; }

echo "== Port-forwarding Kong proxy =="
kubectl --context "$KCTX" -n platform-gateway port-forward svc/kong-gateway-proxy 18080:80 >/tmp/pf-bench.log 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 3

echo "== Running k6 (this takes ~3 minutes) =="
START_EPOCH=$(date +%s)
TARGET_URL="http://localhost:18080" k6 run --summary-export="${OUT_DIR}/k6-summary-${STAMP}.json" tests/load/k6-order-flow.js \
  | tee "${OUT_DIR}/k6-output-${STAMP}.log"
END_EPOCH=$(date +%s)

echo "== Pulling Prometheus data for the same window =="
kubectl --context "$KCTX" -n platform-observability port-forward svc/kps-kube-prometheus-stack-prometheus 19090:9090 >/tmp/pf-prom.log 2>&1 &
PROM_PID=$!
sleep 3
P95_QUERY='histogram_quantile(0.95, sum(rate(http_server_duration_seconds_bucket{service=~"edge-api|order-service|inventory-service"}[5m])) by (le,service))'
CPU_QUERY='sum(rate(container_cpu_usage_seconds_total{namespace="dev"}[5m])) by (pod)'
P95_RESULT=$(curl -s "http://localhost:19090/api/v1/query?query=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$P95_QUERY")&time=${END_EPOCH}")
CPU_RESULT=$(curl -s "http://localhost:19090/api/v1/query?query=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$CPU_QUERY")&time=${END_EPOCH}")
kill $PROM_PID 2>/dev/null || true

REPORT="${OUT_DIR}/benchmark-report-${STAMP}.md"
{
  echo "# Benchmark Report - ${STAMP}"
  echo
  echo "Window: $(date -d @"$START_EPOCH" 2>/dev/null || date -r "$START_EPOCH") -> $(date -d @"$END_EPOCH" 2>/dev/null || date -r "$END_EPOCH")"
  echo
  echo "## k6 client-side results"
  echo '```'
  tail -40 "${OUT_DIR}/k6-output-${STAMP}.log"
  echo '```'
  echo
  echo "## Prometheus server-side p95 latency by service (at test end)"
  echo '```json'
  echo "$P95_RESULT" | python3 -m json.tool
  echo '```'
  echo
  echo "## Prometheus pod CPU usage during test (at test end)"
  echo '```json'
  echo "$CPU_RESULT" | python3 -m json.tool
  echo '```'
  echo
  echo "## How to read this"
  echo
  echo "If k6's p95 is meaningfully higher than Prometheus' server-side p95 for"
  echo "the same window, the difference is network/mesh overhead between your"
  echo "laptop and Kong - expected for a local demo, worth flagging if it ever"
  echo "shows up in a real multi-node cluster. If they roughly agree, the"
  echo "dashboards are trustworthy: what Grafana shows during a real incident"
  echo "is what your customers actually experienced."
} > "$REPORT"

echo
echo "Report written: $REPORT"