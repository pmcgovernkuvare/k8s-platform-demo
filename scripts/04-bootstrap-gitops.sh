#!/usr/bin/env bash
# Points ArgoCD at THIS repo (the "cluster-specific repo" in the exercise)
# using the app-of-apps pattern: one root Application per environment that
# in turn manages every infra + service Application for that environment.
#
# This is the crux of the "shift-left, PR-gated" story: from this point on,
# NOBODY runs `kubectl apply` or `helm upgrade` by hand. Every change to
# what's running in dev/test/prod is a PR against files under gitops/,
# reviewed by infra/devops, merged, and then ArgoCD reconciles it automatically.
set -euo pipefail
cd "$(dirname "$0")/.."
KCTX="k3d-platform-demo"

REPO_URL="${GITOPS_REPO_URL:-https://github.com/YOUR_ORG/k8s-platform-demo.git}"
echo "Using GitOps repo URL: $REPO_URL"
echo "(override with GITOPS_REPO_URL=... if you've pushed this to your own GitHub org)"

for env in dev test prod; do
  sed "s#__REPO_URL__#${REPO_URL}#g" gitops/bootstrap/root-app.tmpl.yaml | \
    sed "s#__ENV__#${env}#g" | \
    kubectl --context "$KCTX" apply -f -
done

echo
echo "Root Applications created. Watch reconciliation with:"
echo "  argocd app list"
echo "  kubectl -n platform-gitops get applications -w"