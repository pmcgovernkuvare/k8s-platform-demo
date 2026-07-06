# GitOps Workflow: PR-Gated Promotion

## The mechanism

```mermaid
sequenceDiagram
    participant Dev as App developer
    participant PR as Pull Request
    participant CI as GitHub Actions
    participant Main as main branch
    participant Argo as ArgoCD
    participant Dev_NS as dev namespace
    participant Test_NS as test namespace
    participant Prod_NS as prod namespace

    Dev->>PR: edit gitops/services/catalog/edge-api/values-dev.yaml
    PR->>CI: pr-validate.yml (lint, unit tests, helm render, kind smoke-deploy)
    CI-->>PR: checks pass
    Dev->>PR: request review (CODEOWNERS auto-requested for protected paths)
    PR->>Main: merge
    Main->>CI: build-and-deploy-dev.yml builds+pushes image, bumps values-dev.yaml, commits
    Argo->>Dev_NS: auto-sync picks up the commit within seconds

    Note over Dev,Prod_NS: Later, promote to test:
    Dev->>CI: workflow_dispatch: promote.yml (service=edge-api, target=test)
    CI->>PR: opens a NEW PR bumping values-test.yaml to the dev image tag
    PR-->>PR: CODEOWNERS requires platform-team review (gitops/apps/test/** is protected)
    PR->>Main: merge (after review)
    Argo->>Test_NS: auto-sync

    Note over Dev,Prod_NS: Same pattern again, test -> prod
```

## What enforces "infra/devops oversight"

Two GitHub-native mechanisms, both already configured in this repo:

1. **`.github/CODEOWNERS`** - `gitops/apps/test/**`, `gitops/apps/prod/**`,
   `charts/**`, and every `values-test.yaml`/`values-prod.yaml` are owned
   by `@your-org/platform-team`. Combined with a branch protection rule
   requiring code owner review (GitHub Settings → Branches → main →
   *Require review from Code Owners*), nobody can merge a change to
   test/prod - or to the shared chart - without platform sign-off. `dev`
   values files are owned by each app team, so they can self-serve there.

2. **`.github/workflows/pr-validate.yml`** runs BEFORE a human ever looks
   at the PR: lint, unit tests, a Helm render of every values file (catches
   a typo'd values file before it becomes a broken deploy), and a
   server-side dry-run apply against a disposable kind cluster. A reviewer
   is reviewing intent and design, not syntax.

## Why ArgoCD's App-of-Apps

`gitops/bootstrap/root-app.tmpl.yaml` creates one root Application per
environment (`root-dev`, `root-test`, `root-prod`), each watching
`gitops/apps/<env>/` recursively. Every file ArgoCD finds there becomes
its own Application. Practically: adding a fifth service to dev is "add
one YAML file to `gitops/apps/dev/` and one values file to
`gitops/services/catalog/<service>/`, open a PR" - nothing about the
platform's bootstrapping changes.

Each per-service Application uses ArgoCD's multi-source feature: one
source points at the shared chart (`charts/service-template`), a second
`ref` source points at the same repo so `helm.valueFiles` can reference
`gitops/services/catalog/<service>/values-<env>.yaml` - a path outside the
chart's own directory. This is what lets one chart + one small values file
fully describe a service, instead of app teams maintaining copies of chart
templates.

## Rollback

Because every environment's desired state is a git commit, rollback is
`git revert` (or re-run `promote.yml` with an older tag) - ArgoCD's
`selfHeal: true` means it will actively converge the cluster back to
match, even undoing manual `kubectl edit` drift automatically. There is
deliberately no "rollback button" in ArgoCD to click during an incident -
the audit trail from a git revert is worth the extra 30 seconds.
