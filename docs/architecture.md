# Architecture

## Cluster topology

```mermaid
flowchart TB
    subgraph laptop["Your laptop (Docker Desktop)"]
        subgraph kind["k3d cluster: platform-demo"]
            subgraph gw["platform-gateway"]
                kong["Kong Gateway"]
            end
            subgraph mesh["Linkerd (cluster-wide)"]
                subgraph devns["dev namespace"]
                    edge["edge-api (Node)"]
                    order["order-service (Go)"]
                    inv["inventory-service (Python)"]
                    bridge["queue-bridge (Python)"]
                    fn["notify-function (.NET, KEDA-scaled 0-N)"]
                end
                subgraph testns["test namespace"]
                    edget["edge-api"]
                    ordert["order-service"]
                    invt["inventory-service"]
                end
                subgraph prodns["prod namespace"]
                    edgep["edge-api"]
                    orderp["order-service"]
                    invp["inventory-service"]
                end
            end
            subgraph az["platform-azure"]
                azurite["Azurite (Azure Storage emulator)"]
            end
            subgraph obs["platform-observability"]
                prom["Prometheus"]
                loki["Loki"]
                tempo["Tempo"]
                otel["OTel Collector"]
                graf["Grafana"]
            end
            subgraph git["platform-gitops"]
                argocd["ArgoCD"]
            end
            keda["KEDA"]
        end
    end

    client["curl / browser"] --> kong
    kong --> edge
    edge --> order
    order --> inv
    order --> bridge
    bridge --> azurite
    azurite -.queue depth.-> keda
    keda -.scales 0-N.-> fn
    azurite --> fn

    edge -. OTLP traces/metrics .-> otel
    order -. OTLP .-> otel
    inv -. OTLP .-> otel
    bridge -. OTLP .-> otel
    fn -. OTLP .-> otel
    mesh -. proxy spans+metrics .-> otel
    kong -. prometheus metrics .-> prom
    otel --> tempo
    otel --> prom
    devns -. container logs .-> loki

    argocd -. watches this repo, reconciles .-> devns
    argocd -. watches this repo, reconciles .-> testns
    argocd -. watches this repo, reconciles .-> prodns

    graf --> prom
    graf --> loki
    graf --> tempo
```

## Why namespaces, not three clusters

Real production platforms usually run dev/test/prod as fully separate
clusters (or at least separate node pools/cloud accounts) for blast-radius
isolation. This demo uses namespaces on one k3d cluster instead, purely
for laptop resource reasons - three full copies of Linkerd + Kong +
Prometheus + Loki + Tempo would need more CPU/RAM than most laptops have
to spare.

Crucially, the GitOps repo (`gitops/`) is structured as if the clusters
were already separate: each environment has its own ArgoCD Application
manifests and its own values files, and the only thing that currently
makes them share infrastructure is the `destination.server` field pointing
at the same cluster. See
[`scaling-to-multi-cluster.md`](scaling-to-multi-cluster.md) for the
one-line change to point `test`/`prod` at real separate clusters.

## Why one Helm chart for every service

`charts/service-template` is deliberately generic - every service, in
every language, in every environment, is a Deployment + Service + HPA +
PodDisruptionBudget + NetworkPolicy + ServiceMonitor + (optionally) an
HTTPRoute and a Linkerd ServiceProfile. A developer adding a new service
writes ~20 lines of values YAML, not a new set of Kubernetes manifests.
Infra/devops owns changes to the chart itself (enforced by
`.github/CODEOWNERS`); app teams own their values files. This is the
literal mechanism behind "shift-left, self-service deploys with
infra oversight" - the chart is the paved road, and the values file is the
only decision a developer has to make.

The one exception is `notify-function`, whose scaling model (KEDA,
0-to-N based on queue depth) is different enough from the standard
HPA-on-CPU pattern that it gets its own raw manifests
(`apps/notify-function-dotnet/k8s/`) rather than forcing that shape into
the shared chart. That's a judgment call worth surfacing in a review: not
every workload fits the same abstraction, and the platform should make
the common case easy without making the uncommon case impossible.