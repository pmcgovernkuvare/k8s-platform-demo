# Scaling From Namespaces to Real Multi-Cluster

This demo runs dev/test/prod as namespaces on one k3d cluster (see
[`architecture.md`](architecture.md) for why). Moving to real separate
clusters - the way you'd actually run this in production - touches
surprisingly little:

1. **Create additional clusters.** Locally: `k3d cluster create
   platform-demo-test`, `platform-demo-prod`, each with the same port/
   registry flags as `scripts/01-create-cluster.sh` (adjusted so the host
   ports don't collide with the first cluster). In a real environment:
   separate EKS/AKS/GKE/on-prem clusters, one per environment (or per
   region+environment).

2. **Install the platform layer on each cluster.** `scripts/02-install-platform.sh`
   and `scripts/03-install-observability.sh` are already idempotent and
   parameterized by `$KCTX` - point them at each new cluster's context.
   (At real scale, you'd also centralize Grafana/Tempo/Loki into one
   "observability cluster" that remote-reads from per-environment
   Prometheus/Loki/Tempo instances via Grafana Mimir/Loki's
   multi-tenancy, rather than running a full copy per environment - out
   of scope for this demo but a natural next step.)

3. **Register each cluster with ArgoCD**, then change exactly one field
   per environment: `gitops/bootstrap/root-app.tmpl.yaml`'s
   `spec.destination.server` for `test`/`prod` moves from
   `https://kubernetes.default.svc` (the "local" cluster ArgoCD runs on)
   to the new cluster's registered server URL/name. Every other file in
   `gitops/` - the Application manifests, the values catalog, the CI
   workflows - is completely unaware of how many clusters exist.

4. **NetworkPolicies simplify.** Once dev/test/prod are on separate
   clusters, `networkPolicy.allowFromNamespaces` in each service's values
   file can drop the cross-environment entries that only exist because
   this demo shares a cluster.

The reason this is a small change and not a redesign: the platform's unit
of ownership was always "one Application per service per environment,"
never "one cluster." Namespace-per-env on a single k3d cluster was a
laptop-resource concession, not an architectural one.