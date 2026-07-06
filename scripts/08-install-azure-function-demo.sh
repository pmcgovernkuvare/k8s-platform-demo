#!/usr/bin/env bash
# Installs the optional "Azure Functions, running entirely locally" piece:
#   KEDA        - event-driven autoscaling (same engine Azure uses in AKS)
#   Azurite     - local Azure Storage emulator (gives us Azure Queue Storage)
#   notify-function - a .NET 8 isolated-worker Azure Function, queue-triggered,
#                     scaled 0->N by KEDA based on queue depth
#
# This is additive: edge-api/order-service/inventory-service work fine
# without it (order-service's NOTIFICATION_SERVICE_URL is empty until you
# run this, and notifyOrder() is a no-op in that case).
set -euo pipefail
cd "$(dirname "$0")/.."
KCTX="k3d-platform-demo"

echo "== KEDA =="
helm repo add kedacore https://kedacore.github.io/charts --force-update
helm repo update kedacore
helm upgrade --install keda kedacore/keda -n keda --create-namespace \
  --kube-context "$KCTX" \
  -f gitops/infra-values/keda/values.yaml \
  --wait --timeout 5m

echo "== Azurite (local Azure Storage emulator) =="
kubectl --context "$KCTX" apply -f gitops/infra-values/keda/azurite.yaml
kubectl -n platform-azure --context "$KCTX" rollout status deploy/azurite --timeout=120s

echo "== AzureWebJobsStorage secret (dev namespace) =="
if ! kubectl -n dev --context "$KCTX" get secret azurewebjobsstorage >/dev/null 2>&1; then
  kubectl --context "$KCTX" apply -f apps/notify-function-dotnet/k8s/secret.example.yaml
fi

echo "== Build + load images (queue-bridge, notify-function) =="
echo "   (run scripts/build-and-push.sh first if you haven't - see README)"

echo "== queue-bridge (via ArgoCD/GitOps, same as the other services) =="
echo "   handled by gitops/apps/dev/queue-bridge.yaml once you've bootstrapped GitOps"

echo "== notify-function (raw manifests - KEDA-managed scaling, not our Helm chart) =="
kubectl --context "$KCTX" apply -f apps/notify-function-dotnet/k8s/deployment.yaml
kubectl --context "$KCTX" apply -f apps/notify-function-dotnet/k8s/scaledobject.yaml

echo
echo "Point order-service at queue-bridge by setting NOTIFICATION_SERVICE_URL"
echo "(already set in gitops/services/catalog/order-service/values-dev.yaml)."
echo
echo "Watch it scale:"
echo "  kubectl -n dev get pods -l app=notify-function -w"
echo "  # then generate orders: bash scripts/07-demo-urls.sh   (or the load generator)"