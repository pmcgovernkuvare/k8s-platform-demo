#!/usr/bin/env bash
# Prints every URL/credential you need for a live walkthrough.
set -euo pipefail
KCTX="k3d-platform-demo"
echo "Grafana:        http://localhost:3000"
echo "  user: admin  pass: $(kubectl -n platform-observability --context $KCTX get secret kps-grafana -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)"
echo "ArgoCD:         http://localhost:8090"
echo "  user: admin  pass: $(kubectl -n platform-gitops --context $KCTX get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
echo "Linkerd viz:    http://localhost:8084"
echo "Kong proxy:     http://localhost:8080  (edge-api routes live here)"
echo "Prometheus:     kubectl -n platform-observability port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090"
echo "Tempo:          kubectl -n platform-observability port-forward svc/tempo 3100:3100"