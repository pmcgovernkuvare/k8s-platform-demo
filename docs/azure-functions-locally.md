# Running Azure Functions Locally (No Azure Subscription)

This demo includes a working, end-to-end example of Azure's serverless
programming model - queue-triggered Azure Functions, scaled by KEDA -
running entirely on a laptop k3d (k3s-in-Docker) cluster.

## The pieces, and why each one is there

- **[Azurite](https://github.com/Azure/Azurite)** - Microsoft's official
  local emulator for Azure Storage (Blob, Queue, Table). We only use Queue
  Storage here. It ships as a container
  (`mcr.microsoft.com/azure-storage/azurite`) and speaks the real Azure
  Storage REST API, so any SDK or tool that talks to Azure Storage talks
  to Azurite unmodified - just point the connection string at it. The
  connection string in this repo (`AccountName=devstoreaccount1...`) is a
  fixed, publicly documented Microsoft development credential; it is safe
  to commit because it only ever works against a local emulator, never
  against real Azure.

- **[KEDA](https://keda.sh/)** - the Kubernetes Event-Driven Autoscaler.
  This is not a demo-only substitute for something Azure does differently
  in production - KEDA is the actual engine Azure Functions uses to scale
  on AKS and Azure Container Apps. The `ScaledObject` in
  `apps/notify-function-dotnet/k8s/scaledobject.yaml` uses KEDA's built-in
  `azure-queue` trigger, watching Azurite's queue depth and scaling the
  Function's Deployment from 0 to 5 replicas. At rest: zero pods, zero
  cost, zero dashboard noise. Under load: replicas climb within seconds.

- **notify-function** - a real Azure Functions app (.NET 8, isolated
  worker model - the current, non-deprecated hosting model), built with
  the same `Microsoft.Azure.Functions.Worker` packages and
  `mcr.microsoft.com/azure-functions/dotnet-isolated` base image you'd use
  for a real Azure deployment. `[Function("ProcessOrderNotification")]`
  with a `[QueueTrigger(...)]` attribute is unchanged whether it's running
  in this k3d cluster, in AKS, or in Azure's own Functions hosting -
  that's the point.

## What's genuinely different from real Azure, and what isn't

| | This demo | Real Azure |
|---|---|---|
| Storage Queue | Azurite (emulator) | Real Azure Storage Account |
| Autoscaling engine | KEDA on k3d | KEDA on AKS, or Azure's managed scale controller on Consumption/Container Apps |
| Function runtime | Same official container image | Same official container image (AKS), or Azure-managed (Consumption) |
| Function code | Identical | Identical |
| Trace propagation | Manual (queue messages carry trace_id/span_id as JSON fields - Storage Queues have no native trace-context headers) | Same manual pattern is standard practice for any queue-based messaging, on any cloud |

Moving this piece to real Azure is: create a Storage Account, replace the
Azurite connection string with the real one (ideally via a Kubernetes
Secret sourced from Key Vault, not committed), and either keep running it
on AKS with KEDA (nearly zero change) or redeploy the same code to Azure
Functions' Consumption plan (no Kubernetes at all - the tradeoff there is
losing the shared mesh/observability stack this demo showcases).

## Try it

```bash
make azure-demo
kubectl -n dev get pods -l app=notify-function -w   # watch it scale from 0
curl -X POST http://localhost:8080/orders -d '{"item":"widget","quantity":1}' \
  -H 'content-type: application/json'
# within ~5-10s (KEDA's pollingInterval): a notify-function pod appears,
# processes the message, and (if you check Tempo) the trace continues
# straight into it.
```