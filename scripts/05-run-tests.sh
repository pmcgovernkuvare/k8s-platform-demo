#!/usr/bin/env bash
# Runs the full test pyramid against the live demo cluster:
#   unit (per-service, no cluster needed) -> integration (in-cluster call chain)
#   -> e2e smoke (mesh mTLS, gateway routing, GitOps sync health, telemetry presence)
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Unit tests =="
# `npm install` (not just `npm test`) matters here: if apps/edge-api-node/
# has no node_modules of its own yet, Node's require() resolution walks UP
# the directory tree looking for node-fetch, and can pick up an unrelated,
# incompatible version (e.g. a newer ESM-only node-fetch v3.x from some
# other project/tooling higher up on your filesystem) instead of the v2.x
# this app's package.json actually pins - which fails at runtime with
# "fetch is not a function" rather than a clear "module not found". Installing
# locally first guarantees Node resolves the correct nested copy.
( cd apps/edge-api-node && npm install --silent && npm test --silent )
# go.sum isn't committed (same class of gap as the missing package-lock.json
# above) - `go test` refuses to run at all without every entry present
# ("missing go.sum entry"), so `go mod tidy` has to run first to generate it.
( cd apps/order-service-go && go mod tidy && go test ./... )
( cd apps/inventory-service-python && python3 -m pip install -q -r requirements-dev.txt && python3 -m pytest -q )

echo "== Integration tests (in-cluster call chain + trace propagation) =="
bash tests/integration/run.sh

echo "== E2E smoke tests (mesh, gateway, gitops, telemetry) =="
bash tests/e2e/smoke.sh

echo
echo "All test suites passed."