#!/usr/bin/env bash
# Verifies your laptop has everything needed before we touch a cluster.
set -euo pipefail
ok=1
need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "  MISSING: $1  -- $2"
    ok=0
  else
    echo "  OK: $1 ($($1 $3 2>&1 | head -n1))"
  fi
}
echo "== Checking prerequisites =="
need docker   "Docker Desktop (or compatible) running"      "--version"
need k3d      "brew install k3d"                              "--version"
need kubectl  "brew install kubectl"                          "version --client --short"
need helm     "brew install helm"                              "version --short"
need linkerd  "brew install linkerd"                            "version --client --short"
need argocd   "brew install argocd"                              "version --client --short"
need k6       "brew install k6"                                   "version"
need jq       "brew install jq"                                    "--version"

echo
echo "== Docker resources (recommend >= 4 CPU / 8GB RAM allocated to Docker) =="
docker info --format 'CPUs: {{.NCPU}}  Memory: {{.MemTotal}}' 2>/dev/null || echo "  Could not read docker info"

if [[ "$ok" -ne 1 ]]; then
  echo
  echo "One or more required tools are missing. Install them, then re-run this script."
  exit 1
fi
echo
echo "All prerequisites satisfied. Run: make up"