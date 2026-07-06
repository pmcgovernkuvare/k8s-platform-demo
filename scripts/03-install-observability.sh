#!/usr/bin/env bash
# Installs the LGTM(+OTel) observability stack into platform-observability:
#   Prometheus (+ Alertmanager)  - metrics, golden signals, alerting
#   Loki                          - logs, correlated by trace_id
#   Tempo                         - distributed traces
#   Grafana                       - single pane of glass, pre-wired datasources
#   OpenTelemetry Collector       - the ingestion front door for app + mesh telemetry
set -euo pipefail
cd "$(dirname "$0")/.."
KCTX="k3d-platform-demo"
NS=platform-observability

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update
helm repo update

echo "== Prometheus + Alertmanager + Grafana (kube-prometheus-stack) =="
helm upgrade --install kps prometheus-community/kube-prometheus-stack -n "$NS" --create-namespace \
  --kube-context "$KCTX" \
  -f gitops/infra-values/prometheus/values.yaml \
  --wait --timeout 8m

echo "== Loki (single binary, demo-sized) =="
helm upgrade --install loki grafana/loki -n "$NS" \
  --kube-context "$KCTX" \
  -f gitops/infra-values/loki/values.yaml \
  --wait --timeout 5m

echo "== Grafana Alloy (log + kubernetes metadata shipper -> Loki) =="
helm upgrade --install alloy grafana/alloy -n "$NS" \
  --kube-context "$KCTX" \
  -f gitops/infra-values/loki/alloy-values.yaml \
  --wait --timeout 5m

echo "== Tempo (trace storage) =="
helm upgrade --install tempo grafana/tempo -n "$NS" \
  --kube-context "$KCTX" \
  -f gitops/infra-values/tempo/values.yaml \
  --wait --timeout 5m

echo "== OpenTelemetry Collector (OTLP gateway: apps + Linkerd -> Tempo/Prometheus/Loki) =="
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector -n "$NS" \
  --kube-context "$KCTX" \
  -f gitops/infra-values/otel-collector/values.yaml \
  --wait --timeout 5m

echo "== Grafana datasource + dashboard provisioning (Prometheus <-> Loki <-> Tempo linking) =="
kubectl -n "$NS" --context "$KCTX" apply -f gitops/infra-values/grafana/datasources-configmap.yaml
for f in gitops/infra-values/grafana/dashboards/*.json; do
  name=$(basename "$f" .json)
  kubectl -n "$NS" --context "$KCTX" create configmap "dash-${name}" \
    --from-file="${name}.json=${f}" \
    --dry-run=client -o yaml | \
    kubectl label --local -f - grafana_dashboard=1 -o yaml --dry-run=client | \
    kubectl --context "$KCTX" apply -n "$NS" -f -
done

echo
echo "Grafana admin password:"
kubectl -n "$NS" --context "$KCTX" get secret kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
echo "Grafana:  http://localhost:3000  (admin / password above)"
echo "Next: scripts/04-bootstrap-gitops.sh"