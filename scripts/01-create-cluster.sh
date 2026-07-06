#!/usr/bin/env bash
# Creates the local k3d (k3s-in-Docker) cluster + local image registry +
# namespaces for dev/test/prod, and labels namespaces for Linkerd auto-inject.
#
# Originally this used kind, which does a full multi-phase kubeadm bootstrap
# (separate etcd/apiserver/controller-manager/scheduler static pods, plus a
# post-init RBAC bootstrap step with its own hardcoded ~60s timeout). On
# some corporate-managed Macs with VPN/EDR software that inspects local
# Docker network traffic, that specific RBAC bootstrap step can fail
# ("client rate limiter Wait returned an error: context deadline exceeded")
# even with plenty of CPU/RAM available. k3s bootstraps as a single binary/
# process with none of kubeadm's multi-phase dance, which sidesteps that
# failure mode entirely - same real Kubernetes API underneath, same Helm
# charts, same everything else in this repo works unchanged.
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER_NAME="platform-demo"
REG_NAME="platform-demo-registry"
REG_PORT="5001"
KCTX="k3d-${CLUSTER_NAME}"

echo "== k3d cluster (+ local image registry) =="
if ! k3d cluster list | awk '{print $1}' | grep -qx "${CLUSTER_NAME}"; then
  k3d cluster create "${CLUSTER_NAME}" \
    --servers 1 \
    --agents 0 \
    --port "8080:30080@server:0" \
    --port "8443:30443@server:0" \
    --port "3000:30300@server:0" \
    --port "8090:30081@server:0" \
    --port "8084:30320@server:0" \
    --registry-create "${REG_NAME}:0.0.0.0:${REG_PORT}" \
    --k3s-arg "--disable=traefik@server:0" \
    --k3s-arg "--disable=servicelb@server:0" \
    --wait
else
  echo "cluster ${CLUSTER_NAME} already exists, skipping create"
fi
kubectl cluster-info --context "${KCTX}"

# k3d auto-configures every node's containerd to mirror "localhost:${REG_PORT}"
# to the registry it just created - unlike kind, no manual docker-network
# dance or containerd config patch is needed. Every image reference in this
# repo (gitops/services/catalog/*/values-*.yaml, scripts/build-and-push.sh)
# already uses "localhost:${REG_PORT}/<service>", so nothing else changes.

echo "== Gateway API CRDs =="
# kind's `featureGates: GatewayAPI: true` installed these for us automatically;
# k3d has no equivalent, so we install the standard upstream CRDs directly -
# this is also the more portable approach (works the same on any Kubernetes
# distribution, not just kind).
kubectl --context "${KCTX}" apply -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml

echo "== Environment namespaces =="
for ns in dev test prod platform-observability platform-mesh platform-gateway platform-gitops; do
  kubectl --context "${KCTX}" create namespace "$ns" --dry-run=client -o yaml | kubectl --context "${KCTX}" apply -f -
done

# Pod Security + resource quotas per simulated environment (light-touch, demo-sized)
for ns in dev test prod; do
  kubectl --context "${KCTX}" label namespace "$ns" "env=${ns}" --overwrite
  kubectl --context "${KCTX}" apply -f - <<Q
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ${ns}-quota
  namespace: ${ns}
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 4Gi
    limits.cpu: "8"
    limits.memory: 8Gi
    pods: "40"
Q
done

echo
echo "Cluster ready (context: ${KCTX}). Next: scripts/02-install-platform.sh"