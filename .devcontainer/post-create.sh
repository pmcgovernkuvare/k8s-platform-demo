#!/usr/bin/env bash
# Runs once, after the devcontainer is built and the repo is mounted.
# Pre-installs every app's dependencies so `make test`/`make build` work
# immediately - this is the same class of gap that broke `make test` twice
# on a bare macOS setup (missing node_modules caused Node's require() to
# walk up and grab an incompatible node-fetch v3; missing go.sum made
# `go test` refuse to run at all; see docs/troubleshooting.md). Doing it
# once here, in a clean container, means nobody has to rediscover either
# issue again.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== edge-api-node (npm install) =="
( cd apps/edge-api-node && npm install )

echo "== order-service-go (go mod tidy) =="
( cd apps/order-service-go && go mod tidy )

echo "== inventory-service-python (pip install -r requirements-dev.txt) =="
( cd apps/inventory-service-python && python3 -m pip install --user -r requirements-dev.txt )

echo "== queue-bridge-python (pip install -r requirements-dev.txt) =="
( cd apps/queue-bridge-python && python3 -m pip install --user -r requirements-dev.txt )

echo "== notify-function-dotnet (dotnet restore) =="
( cd apps/notify-function-dotnet && dotnet restore )

echo
echo "Devcontainer ready. Next: make prereqs   (verifies Docker's resource allocation)"
echo
echo "NOTE on networking: k3d's cluster containers (scripts/01-create-cluster.sh)"
echo "are created as SIBLINGS on the host's real Docker daemon via"
echo "docker-outside-of-docker, not nested inside this container. That means"
echo "'localhost' means something different depending on where you run a"
echo "command:"
echo "  - kubectl/helm/k3d/make commands: run them IN this devcontainer as usual."
echo "  - curl'ing a published port (e.g. http://localhost:8080/orders) from"
echo "    INSIDE this devcontainer's terminal will NOT reach it - that port is"
echo "    published on the ACTUAL HOST (your Mac), not this container. Use"
echo "    http://host.docker.internal:8080 from inside the devcontainer, or"
echo "    just run curl from a regular Mac terminal instead."