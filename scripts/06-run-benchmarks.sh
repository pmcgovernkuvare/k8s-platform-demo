#!/usr/bin/env bash
# Runs the k6 load/benchmark suite against edge-api (through Kong + Linkerd)
# and produces a markdown report correlating k6 results with Linkerd golden
# metrics and Prometheus resource usage pulled for the same time window.
set -euo pipefail
cd "$(dirname "$0")/.."
bash tests/load/run-benchmark.sh "$@"
