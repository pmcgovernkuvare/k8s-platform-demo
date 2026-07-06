# Troubleshooting

**Cluster creation fails on `kubeadm init` with "connection refused" or
"context deadline exceeded" on a ClusterRoleBinding, even with plenty of
CPU/RAM allocated**
This was a real issue encountered building this demo on a corporate-managed
Mac: kind's kubeadm-based bootstrap runs a post-init step that creates a
ClusterRoleBinding with a hardcoded ~60-second client timeout. On machines
running VPN/EDR software that inspects the whole network stack (Zscaler,
CrowdStrike, Netskope, Cisco AnyConnect, etc.), that inspection can be
just invasive enough - even for Docker's internal bridge network - to make
every request in that 60-second window fail or return a malformed
response, without ever looking like a resource problem (identical failure
persisted after going from 3 nodes/7.65GB to 1 node/15.6GB). If you hit
this and can't disable your VPN/EDR (common at regulated companies), the
fix is to stop using kind's kubeadm-based bootstrap entirely: this repo
now uses **k3d** (k3s-in-Docker) instead (see `scripts/01-create-cluster.sh`).
k3s bootstraps as a single process with no equivalent multi-phase RBAC
polling step, which sidesteps the failure mode completely rather than
working around it. Everything downstream of cluster creation (Linkerd,
Kong, ArgoCD, the observability stack, every sample service) is unaffected
either way.

**`make up` hangs on Linkerd/observability install**
Docker Desktop likely doesn't have enough CPU/RAM allocated. Check
Settings → Resources; this demo wants at least 4 CPUs / 8-10GB RAM. Run
`make prereqs` to see Docker's currently reported allocation.

**`linkerd check` fails on proxy injection**
Confirm the target namespace has `linkerd.io/inject: enabled`
(`kubectl get ns dev --show-labels`) and that pods were created/restarted
*after* the label was applied - Linkerd injects at pod admission time, so
existing pods need a rollout restart: `kubectl -n dev rollout restart
deploy`.

**`make up` (rerun) fails with `UPGRADE FAILED: ... conflict occurred while
applying object ... conflicts with "kubectl-patch"`**
Root cause: an earlier revision of this repo followed every
`helm upgrade --install` for Kong/ArgoCD/Grafana with a separate imperative
`kubectl patch svc ...` to force that Service onto NodePort. `helm upgrade
--install` uses server-side apply, which tracks field ownership per
"field manager" - the follow-up `kubectl patch` transfers ownership of
`.spec.type` and the port names to a *different* field manager
("kubectl-patch"). Every subsequent `helm upgrade --install` (i.e. every
rerun of `make up`) then conflicts with that ownership and fails outright.
Fixed by moving NodePort config into each chart's own Helm values
(`gitops/infra-values/{kong,argocd,prometheus}/values.yaml` -
`proxy.type`/`server.service.type`/`grafana.service.type` respectively) so
Helm owns the whole Service and there's nothing left to conflict with. If
you hit this on an existing cluster (created before this fix), the stale
field-manager entry can also be cleared manually: `kubectl -n <ns> apply
--server-side --force-conflicts -f -` on the Service, or simplest, `helm
uninstall` the affected release and let `make up` recreate it.
Linkerd-viz's dashboard `web` Service is the one exception left with a
`kubectl patch`: that chart has no Helm value for Service type/nodePort at
all, and its install path uses plain `kubectl apply` (client-side, no
field-manager conflicts) rather than `helm upgrade --install`, so the
pattern is safe there.

**ArgoCD Application stuck `OutOfSync` / `Unknown`**
Almost always the `repoURL` placeholder. `gitops/apps/*/*.yaml` and
`gitops/bootstrap/root-app.tmpl.yaml` default to
`https://github.com/YOUR_ORG/k8s-platform-demo.git` - push this repo to
your own GitHub org and either edit those files or re-run
`scripts/04-bootstrap-gitops.sh` with `GITOPS_REPO_URL` set.

**No traces showing up in Tempo**
Check the OTel Collector's logs (`kubectl -n platform-observability logs
deploy/otel-collector-opentelemetry-collector`) - the `debug` exporter
configured in `gitops/infra-values/otel-collector/values.yaml` prints
every span it receives, which is the fastest way to tell "nothing is being
sent" from "spans arrive but Tempo isn't storing them."

**`x-trace-id` header missing from edge-api responses**
This means OpenTelemetry's Node SDK didn't initialize - check that the pod
was started with `node --require ./src/tracing.js src/index.js` (this is
the chart's default `CMD`/`args`; if you overrode the container command,
you dropped the `--require`).

**KEDA never scales `notify-function` above 0**
1. Confirm Azurite is reachable: `kubectl -n platform-azure get pods`.
2. Confirm the `azurewebjobsstorage` secret exists in `dev`:
   `kubectl -n dev get secret azurewebjobsstorage`.
3. Check the KEDA operator's logs for the actual scaler error:
   `kubectl -n keda logs deploy/keda-operator`.
4. Confirm `order-service`'s `NOTIFICATION_SERVICE_URL` env var is set
   (it's only set if you're using the `values-dev.yaml` catalog file as-is
   - see `gitops/services/catalog/order-service/values-dev.yaml`).

**Benchmark (`make bench`) reports much higher latency than the
dashboards show**
Check for CPU throttling on Docker Desktop - k6 itself competing for CPU
with the cluster it's testing is a common false signal on a laptop. Try
lowering k6's VU ramp in `tests/load/k6-order-flow.js` or running k6 with
`--compatibility-mode=... ` on a machine with more headroom.