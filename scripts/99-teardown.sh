#!/usr/bin/env bash
# k3d's cluster delete also removes the registry created alongside it
# (--registry-create in scripts/01-create-cluster.sh), so there's no
# separate `docker rm` step needed here (unlike the old kind-registry setup).
set -euo pipefail
k3d cluster delete platform-demo || true
echo "Torn down."