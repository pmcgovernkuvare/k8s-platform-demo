# Base devcontainer image (Ubuntu 22.04). Runtimes (Node/Go/Python/.NET) and
# kubectl/helm/docker-outside-of-docker are added afterwards via the
# "features" block in devcontainer.json, NOT here - features are layered on
# top of whatever this Dockerfile builds, so nothing in this file can depend
# on them being present yet. This file only installs the CLI tools that
# don't have an official devcontainer feature: k3d, linkerd, argocd, k6,
# yamllint, shellcheck, gh.
FROM mcr.microsoft.com/devcontainers/base:ubuntu-22.04

# Every curl-piped-install below uses -fsSL (fail on HTTP error, follow
# redirects) rather than a bare -s. A plain `curl -s` that hits a redirect
# or an error page fails SILENTLY - piped into `gpg --dearmor` it produces a
# corrupt-but-present keyring file, which doesn't error out here but makes
# `apt-get update` quietly drop that repo's package list with a warning
# apt-get treats as non-fatal - so the actual failure only surfaces later,
# confusingly, as "Unable to locate package X". -f makes curl (and therefore
# this RUN step) fail loudly and immediately instead.
#
# ArgoCD and k6 are downloaded as arch-detected binaries rather than via a
# generic Linux package, because this devcontainer gets built natively on
# whatever the host's architecture is (arm64 on Apple Silicon Macs, amd64
# elsewhere) - the same class of "wrong architecture" issue already hit
# twice in this repo (see docs/troubleshooting.md's Azure Functions and
# Azurite notes). k6's official apt repo (dl.k6.io/deb) only ever publishes
# amd64 packages (confirmed: https://github.com/grafana/k6/issues/2136,
# still open) - apt-get install -y k6 on an arm64 build host fails with
# "Unable to locate package k6" even though the repo's own index fetches
# fine. Downloading the correct per-arch release tarball directly sidesteps
# that gap entirely, and also fixes a latent bug in an earlier version of
# this file that hardcoded argocd-linux-amd64 unconditionally - that would
# have downloaded successfully on an arm64 host too, just producing a
# binary that fails with "exec format error" the first time anyone actually
# ran it, since nothing exercises the binary at build time to catch it.
RUN dpkg --print-architecture > /tmp/build-arch

# k3d (k3s-in-Docker) - the local cluster this whole repo is built around
# (scripts/01-create-cluster.sh). k3d's own install script auto-detects
# architecture internally, so no arch handling needed here. Pinned to a
# specific version rather than "latest" so every teammate's devcontainer
# gets the exact same k3d.
ARG K3D_VERSION=v5.9.0
RUN curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh \
    | TAG=${K3D_VERSION} bash

# Linkerd CLI - deliberately the STABLE channel, not edge (also arch-detected
# internally by the install script). The live cluster this repo was debugged
# against was running an "edge" CLI/control-plane build (edge-26.6.3, a
# nightly/pre-release channel), and the identity-cert issue documented in
# docs/troubleshooting.md ("make azure-demo hangs on Azurite - control plane
# presents an already-expired certificate after a few days of uptime") was
# only ever observed on that edge build. Installing stable here avoids
# reintroducing that class of flakiness. Leaving LINKERD2_VERSION unset
# intentionally picks up whatever the current latest STABLE release is at
# build time, rather than a hardcoded version string that will eventually
# go stale and 404.
RUN curl --proto '=https' --tlsv1.2 -sSfL https://run.linkerd.io/install-stable | sh
ENV PATH="/root/.linkerd2/bin:${PATH}"

# ArgoCD CLI - arch-detected (see note above).
ARG ARGOCD_VERSION=v3.4.4
RUN ARGOCD_ARCH=$(cat /tmp/build-arch) \
    && curl -fsSL -o /usr/local/bin/argocd \
       "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-${ARGOCD_ARCH}" \
    && chmod +x /usr/local/bin/argocd

# k6 (load testing - scripts/06-run-benchmarks.sh) - arch-detected binary
# tarball, NOT the apt repo (see note above for why).
ARG K6_VERSION=v2.1.0
RUN K6_ARCH=$(cat /tmp/build-arch) \
    && mkdir -p /tmp/k6-extract \
    && curl -fsSL -o /tmp/k6.tar.gz \
       "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-${K6_ARCH}.tar.gz" \
    && tar -xzf /tmp/k6.tar.gz -C /tmp/k6-extract \
    && find /tmp/k6-extract -type f -name k6 -exec mv {} /usr/local/bin/k6 \; \
    && test -x /usr/local/bin/k6 \
    && rm -rf /tmp/k6.tar.gz /tmp/k6-extract

# yamllint + shellcheck - both used by ci/pre-pr-check.sh, both packaged in
# Ubuntu 22.04's repos (as noarch/multi-arch packages, so no arch-detection
# gap like k6's apt repo has), so no separate install script/pip dependency
# needed.
RUN apt-get update && apt-get install -y yamllint shellcheck \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI - useful for the GitOps repo push workflow (docs/troubleshooting.md,
# "make gitops" section) - creating/pushing to your own GitHub repo without
# hand-rolling a Personal Access Token. cli.github.com's apt repo does
# publish arm64 packages, and the arch=$(dpkg --print-architecture) below
# already selects the right one, unlike k6's repo.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && test -s /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*