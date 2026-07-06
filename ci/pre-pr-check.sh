#!/usr/bin/env bash
# Run this before opening a PR (or wire it up as a git pre-push hook - see
# bottom of this file). It's intentionally the SAME checks CI runs on the
# PR itself (ci/.github/workflows/pr-validate.yml), just faster feedback:
# broken code gets caught on your laptop in seconds instead of a 3-minute
# CI round trip. This is the "automated testing & test builds triggered
# before PR creation" half of the shift-left story; the workflow files are
# the "as part of the PR" half.
set -euo pipefail
cd "$(dirname "$0")/.."
FAIL=0

section() { echo; echo "== $1 =="; }

section "YAML lint (gitops/, charts/, clusters/)"
if command -v yamllint >/dev/null 2>&1; then
  yamllint -d "{extends: relaxed, rules: {line-length: disable}}" gitops charts clusters || FAIL=1
else
  echo "yamllint not installed - skipping (pip install yamllint)"
fi

section "Helm lint + template render (service-template)"
if command -v helm >/dev/null 2>&1; then
  for f in gitops/services/catalog/*/values-*.yaml; do
    echo "-- $f"
    helm template demo charts/service-template -f "$f" > /dev/null || FAIL=1
  done
  helm lint charts/service-template || FAIL=1
else
  echo "helm not installed - skipping (brew install helm)"
fi

section "edge-api (Node) unit tests"
if [ -d apps/edge-api-node/node_modules ]; then
  (cd apps/edge-api-node && npm test --silent) || FAIL=1
else
  echo "node_modules missing - run: (cd apps/edge-api-node && npm install)"
fi

section "order-service (Go) unit tests + vet"
if command -v go >/dev/null 2>&1; then
  (cd apps/order-service-go && go vet ./... && go test ./...) || FAIL=1
else
  echo "go not installed - skipping (https://go.dev/dl)"
fi

section "inventory-service (Python) unit tests"
if command -v pytest >/dev/null 2>&1 || python3 -m pytest --version >/dev/null 2>&1; then
  (cd apps/inventory-service-python && PYTHONPATH=. python3 -m pytest -q) || FAIL=1
else
  echo "pytest not installed - skipping (pip install -r apps/inventory-service-python/requirements-dev.txt)"
fi

section "queue-bridge (Python) unit tests"
if python3 -m pytest --version >/dev/null 2>&1; then
  (cd apps/queue-bridge-python && PYTHONPATH=. python3 -m pytest -q) || FAIL=1
else
  echo "pytest not installed - skipping"
fi

section "notify-function (.NET) unit tests"
if command -v dotnet >/dev/null 2>&1; then
  (cd apps/notify-function-dotnet/tests && dotnet test) || FAIL=1
else
  echo "dotnet not installed - skipping (https://dotnet.microsoft.com/download)"
fi

section "Shellcheck (scripts/)"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck scripts/*.sh ci/*.sh || FAIL=1
else
  echo "shellcheck not installed - skipping (brew install shellcheck)"
fi

echo
if [ "$FAIL" -ne 0 ]; then
  echo "FAILED - fix the above before opening a PR."
  exit 1
fi
echo "All checks passed - safe to open a PR."

# To wire this up as a pre-push hook:
#   ln -s ../../ci/pre-pr-check.sh .git/hooks/pre-push
