.PHONY: prereqs up platform observability gitops azure-demo build traffic no-traffic \
        test bench demo urls down help

help:
	@echo "k8s-platform-demo - targets:"
	@echo "  make prereqs      Check required local tools are installed"
	@echo "  make up           Full stack: cluster + mesh + gateway + gitops + observability"
	@echo "  make build        Build and push all service images to the local registry"
	@echo "  make gitops       Bootstrap ArgoCD app-of-apps (after 'make up' + 'make build')"
	@echo "  make azure-demo   Add the optional KEDA + Azurite + .NET Azure Function piece"
	@echo "  make traffic      Start the load generator (continuous demo traffic)"
	@echo "  make no-traffic   Stop the load generator"
	@echo "  make test         Run unit + integration + e2e smoke tests"
	@echo "  make bench        Run the k6 benchmark suite and produce a report"
	@echo "  make urls         Print every dashboard URL + credential"
	@echo "  make down         Tear down the k3d cluster"

prereqs:
	bash scripts/00-prereqs-check.sh

up:
	bash scripts/01-create-cluster.sh
	bash scripts/02-install-platform.sh
	bash scripts/03-install-observability.sh
	@echo
	@echo "Core platform is up. Next: 'make build' then 'make gitops'."

build:
	bash scripts/build-and-push.sh

gitops:
	bash scripts/04-bootstrap-gitops.sh

azure-demo:
	bash scripts/08-install-azure-function-demo.sh

traffic:
	kubectl --context k3d-platform-demo apply -f apps/load-generator/deployment.yaml

no-traffic:
	kubectl --context k3d-platform-demo delete -f apps/load-generator/deployment.yaml --ignore-not-found

test:
	bash scripts/05-run-tests.sh

bench:
	bash scripts/06-run-benchmarks.sh

urls:
	bash scripts/07-demo-urls.sh

down:
	bash scripts/99-teardown.sh