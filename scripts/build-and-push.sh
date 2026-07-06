#!/usr/bin/env bash
# Builds every service's image and pushes it to the local k3d registry
# (localhost:5001, started by scripts/01-create-cluster.sh). Run this
# whenever app code changes, before syncing ArgoCD / restarting a Deployment.
set -euo pipefail
cd "$(dirname "$0")/.."
REG=localhost:5001
TAG="${IMAGE_TAG:-0.1.0}"

build() {
  local name=$1 dir=$2
  echo "== ${name}:${TAG} =="
  docker build -t "${REG}/${name}:${TAG}" "${dir}"
  docker push "${REG}/${name}:${TAG}"
}

build edge-api            apps/edge-api-node
build order-service       apps/order-service-go
build inventory-service   apps/inventory-service-python
build queue-bridge        apps/queue-bridge-python
build load-generator      apps/load-generator

echo "== notify-function:${TAG} (.NET, slower build) =="
docker build -t "${REG}/notify-function:${TAG}" apps/notify-function-dotnet
docker push "${REG}/notify-function:${TAG}"

echo
echo "All images built and pushed to ${REG}."