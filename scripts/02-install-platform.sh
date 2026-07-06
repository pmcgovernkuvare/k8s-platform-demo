#!/usr/bin/env bash
# Installs the three "platform" building blocks onto the cluster:
#   1. Linkerd  - service mesh: mTLS everywhere, golden-metrics, distributed
#                 tracing span injection at the proxy layer
#   2. Kong     - API gateway / ingress: the single front door for edge-api
#   3. ArgoCD   - GitOps controller: watches gitops/ and reconciles dev/test/prod
set -euo pipefail
cd "$(dirname "$0")/.."
KCTX="k3d-platform-demo"

echo "== Linkerd: control plane =="
# All `--set` flags for `linkerd install`/`linkerd upgrade` are combined into
# ONE call below (resource requests+limits AND OTel tracing config together).
# An earlier version of this script split these across three separate
# `linkerd install | kubectl apply` invocations - each one regenerates the
# ENTIRE manifest from only the flags passed to THAT call, so the later
# tracing-only call was silently resetting the proxy's resources back to
# blank/unset, since it didn't repeat the resource flags. That combined with
# dev/test/prod's ResourceQuota tracking limits.cpu/limits.memory (see
# scripts/01-create-cluster.sh) - which requires EVERY container in a pod,
# including auto-injected linkerd-init/linkerd-proxy sidecars, to declare
# explicit limits - meant every meshed pod in those namespaces was rejected
# at admission with "must specify limits.cpu for: linkerd-init,linkerd-proxy"
# and never actually ran. Setting explicit cpu/memory limits (not just
# requests) here is the fix; keeping every flag in one call avoids the
# clobbering bug that made it easy to silently lose this fix again.
#
# `linkerd check --pre` deliberately FAILS if Linkerd is already installed
# (it's a pre-flight check, not a health check), so this only runs on a
# genuinely fresh cluster. On a rerun, `linkerd upgrade` (idempotent, reuses
# existing trust anchor/issuer certs) is used instead of skipping entirely -
# skipping meant this resource-limits fix (or any future config change here)
# would never reach an already-installed cluster on `make up` reruns.
LINKERD_SET_FLAGS=(
  --set proxy.resources.cpu.request=50m
  --set proxy.resources.memory.request=32Mi
  --set proxy.resources.cpu.limit=250m
  --set proxy.resources.memory.limit=128Mi
  --set proxy.trace.serviceName=linkerd-proxy
  --set proxy.trace.collector.addr=otel-collector.platform-observability:4317
)
if kubectl --context "$KCTX" get namespace linkerd >/dev/null 2>&1; then
  echo "linkerd namespace already exists, upgrading in place"
  linkerd upgrade --context "$KCTX" "${LINKERD_SET_FLAGS[@]}" | kubectl apply --context "$KCTX" -f -
  # Deliberately NOT calling `linkerd check` here: it auto-detects and
  # includes checks for every installed EXTENSION too (viz, etc.), and
  # viz's self-check queries the shared kube-prometheus-stack Prometheus
  # (see the viz install step below) - which doesn't exist yet if you're
  # re-running this script before scripts/03-install-observability.sh has
  # run. That produced a confusing hang-then-fail even though Linkerd's
  # core control plane was perfectly healthy. Verify core deployments
  # directly instead - fast, and has no dependency on later steps.
  for d in linkerd-destination linkerd-identity linkerd-proxy-injector; do
    kubectl --context "$KCTX" -n linkerd rollout status "deploy/${d}" --timeout=60s
  done
else
  linkerd check --pre --context "$KCTX"
  linkerd install --crds --context "$KCTX" | kubectl apply --context "$KCTX" -f -
  linkerd install --context "$KCTX" "${LINKERD_SET_FLAGS[@]}" | kubectl apply --context "$KCTX" -f -
  linkerd check --context "$KCTX"
fi

echo "== Linkerd: viz extension (dashboards + golden metrics) =="
# --set prometheus.enabled=false + prometheusUrl points viz at the SAME
# kube-prometheus-stack Prometheus that scripts/03-install-observability.sh
# installs (already scraping linkerd-proxy/linkerd-controller - see
# gitops/infra-values/prometheus/values.yaml) instead of installing its own,
# second, entirely redundant Prometheus. Saves real memory on a
# resource-constrained laptop/Docker Desktop VM, at the cost of the viz
# dashboard only working correctly once step 03 has run (fine, since
# `make up` always runs 01->02->03 in order).
linkerd viz install --context "$KCTX" \
  --set prometheus.enabled=false \
  --set prometheusUrl=http://kps-kube-prometheus-stack-prometheus.platform-observability:9090 \
  | kubectl apply --context "$KCTX" -f -
# The linkerd-viz chart doesn't expose a type/nodePort Helm value for the
# "web" Service (only dashboard.service.annotations/labels are settable -
# confirmed against the chart's values.yaml) so a kubectl patch is the only
# way to get it on NodePort. This is safe to leave as an imperative patch,
# unlike the Kong/ArgoCD/Grafana cases below: `linkerd viz install | kubectl
# apply` above is CLIENT-SIDE apply (three-way merge, no field-manager
# conflict errors), not `helm upgrade`'s server-side apply - it just resets
# .spec.type to the chart default on every rerun, and this patch immediately
# re-asserts NodePort right after, every time. No conflict, self-healing.
kubectl -n linkerd-viz --context "$KCTX" patch svc web -p \
  '{"spec": {"type": "NodePort", "ports": [{"port": 8084, "nodePort": 30320, "targetPort": 8084}]}}'

echo "== Linkerd: OpenTelemetry trace export from the proxies =="
# Linkerd's proxies can emit spans for every meshed request, pointed at the
# shared OTel Collector (installed in step 03) which forwards to Tempo -
# already configured above as part of LINKERD_SET_FLAGS in the same
# `linkerd install`/`linkerd upgrade` call that sets proxy resource
# requests/limits, rather than as a separate `linkerd install` invocation
# here. A separate call would regenerate the full manifest from ONLY the
# flags passed to it, silently resetting proxy resources back to blank -
# see the big comment on the Linkerd control plane step above for why that
# combination broke every meshed pod in dev/test/prod.

echo "== Auto-inject the mesh into dev/test/prod =="
for ns in dev test prod; do
  kubectl label namespace "$ns" linkerd.io/inject=enabled --overwrite --context "$KCTX"
done

echo "== Kong: Ingress Controller (Gateway API mode) =="
helm repo add kong https://charts.konghq.com --force-update
helm repo update kong
helm upgrade --install kong kong/ingress -n platform-gateway --create-namespace \
  --kube-context "$KCTX" \
  -f gitops/infra-values/kong/values.yaml \
  --wait --timeout 5m
# NodePort exposure for kong-gateway-proxy is set via proxy.type/proxy.http.
# nodePort/proxy.tls.nodePort in gitops/infra-values/kong/values.yaml - do
# NOT also `kubectl patch` this Service. An earlier version of this script
# did both: helm upgrade --install uses server-side apply, so the patch's
# separate field-manager ("kubectl-patch") ends up owning .spec.type and the
# port names, and every SUBSEQUENT `helm upgrade --install` (i.e. every
# rerun of `make up`) then fails with "Apply failed with 3 conflicts:
# conflicts with 'kubectl-patch'". Let Helm own the whole Service.

echo "== Kong: Prometheus plugin (gateway-level RED metrics) =="
# Applied AFTER the release above exists - this ConfigMap/KongClusterPlugin
# depends on CRDs that Kong's own install just created, so it can't be
# applied any earlier (see the comment at the top of
# gitops/infra-values/kong/values.yaml for why this used to hang).
kubectl --context "$KCTX" apply -f gitops/infra-values/kong/prometheus-plugin.yaml

echo "== ArgoCD =="
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update argo
helm upgrade --install argocd argo/argo-cd -n platform-gitops --create-namespace \
  --kube-context "$KCTX" \
  -f gitops/infra-values/argocd/values.yaml \
  --wait --timeout 5m
# NodePort exposure is set via server.service.type/nodePortHttp in
# gitops/infra-values/argocd/values.yaml - see the Kong comment above for
# why this must NOT also be `kubectl patch`ed (helm upgrade --install's
# server-side apply conflicts with a separate "kubectl-patch" field manager
# on every rerun).

echo
echo "Platform installed. Initial ArgoCD admin password:"
kubectl -n platform-gitops --context "$KCTX" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
echo "Next: scripts/03-install-observability.sh"