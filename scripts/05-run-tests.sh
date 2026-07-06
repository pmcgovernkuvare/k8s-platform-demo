#!/usr/bin/env bash
# Runs the full test pyramid against the live demo cluster:
#   unit (per-service, no cluster needed) -> integration (in-cluster call chain)
#   -> e2e smoke (mesh mTLS, gateway routing, GitOps sync health, telemetry presence)
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Unit tests =="
( cd apps/edge-api-node && npm test --silent )
( cd apps/order-service-go && go test ./... )
( cd apps/inventory-service-python && python3 -m pytest -q )

echo "== Integration tests (in-cluster call chain + trace propagation) =="
bash tests/integration/run.sh

echo "== E2E smoke tests (mesh, gateway, gitops, telemetry) =="
bash tests/e2e/smoke.sh

echo
echo "All test suites passed."
