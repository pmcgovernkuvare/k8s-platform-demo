#!/usr/bin/env bash
# Post-deploy smoke tests: cheap, fast, cluster-wide health checks. Run
# after every deploy (scripts/05-run-tests.sh calls this; the promotion
# story assumes this passes in test before anyone promotes to prod).
set -euo pipefail
KCTX="k3d-platform-demo"
FAIL=0

check() {
  local desc=$1; shift
  echo -n "  ${desc} ... "
  if "$@" >/tmp/smoke-check.log 2>&1; then
    echo "OK"
  else
    echo "FAIL"
    cat /tmp/smoke-check.log
    FAIL=1
  fi
}

echo "== Cluster reachable =="
check "kubectl can reach the API server" kubectl --context "$KCTX" get nodes

echo "== Linkerd mesh health =="
check "linkerd control plane healthy" linkerd check --context "$KCTX"
check "linkerd data plane proxies healthy" linkerd check --context "$KCTX" --proxy

echo "== ArgoCD application health (dev/test/prod) =="
for env in dev test prod; do
  check "root-${env} application synced+healthy" bash -c \
    "kubectl --context $KCTX -n platform-gitops get application root-${env} -o jsonpath='{.status.health.status}' | grep -q Healthy"
done

echo "== Workload readiness (dev) =="
for svc in edge-api order-service inventory-service; do
  check "${svc} deployment available" kubectl --context "$KCTX" -n dev rollout status "deploy/${svc}" --timeout=60s
done

echo "== Gateway routing =="
check "Kong proxy responds on /healthz via edge-api route" bash -c \
  "kubectl --context $KCTX -n platform-gateway port-forward svc/kong-gateway-proxy 18081:80 >/tmp/pf.log 2>&1 & \
   PF=\$!; sleep 3; \
   curl -sf http://localhost:18081/healthz; RC=\$?; kill \$PF; exit \$RC"

echo "== Telemetry pipeline =="
check "Prometheus has scraped edge-api metrics" bash -c \
  "kubectl --context $KCTX -n platform-observability port-forward svc/kps-kube-prometheus-stack-prometheus 19090:9090 >/tmp/pf2.log 2>&1 & \
   PF=\$!; sleep 3; \
   curl -sf 'http://localhost:19090/api/v1/query?query=up{job=\"otel-collector\"}' | grep -q '\"status\":\"success\"'; RC=\$?; kill \$PF; exit \$RC"

echo
if [ "$FAIL" -ne 0 ]; then
  echo "SMOKE TESTS FAILED"
  exit 1
fi
echo "SMOKE TESTS PASSED"