.PHONY: apply build push images delete health test test-db docs

NAMESPACE ?= microservices
TAG ?=
PUSH ?=

apply:
	bash Scripts/gke-apply.sh

build:
	bash Scripts/build-images.sh $(TAG)

push:
	bash Scripts/build-images.sh $(TAG) --push

images: build

delete:
	bash Scripts/clean-up.sh $(NAMESPACE)

health:
	bash Scripts/healthcheck.sh $(NAMESPACE)

test:
	bash Scripts/test-api.sh $(NAMESPACE)

test-db:
	bash Scripts/test-databases.sh $(NAMESPACE)


docs:
	@echo "Open README.md for full documentation."

.PHONY: monitoring
monitoring:
	@echo "Installing kube-prometheus stack (operator, Prometheus, Grafana)..."
	bash Scripts/install-prometheus-operator.sh
	@echo "Applying Prometheus RBAC (service discovery permissions)"
	-kubectl apply -f Manifests/monitoring/prometheus-rbac.yaml || true
	@echo "Applying optional Grafana admin Secret if provided"
	@if [ -f Manifests/monitoring/grafana-secret.yaml ]; then \
	  kubectl apply -f Manifests/monitoring/grafana-secret.yaml || true; \
	  bash Scripts/patch-grafana-admin-secret.sh monitoring grafana || true; \
	  kubectl -n monitoring rollout status deploy/grafana --timeout=120s || true; \
	else \
	  echo "(skip) Manifests/monitoring/grafana-secret.yaml not found"; \
	fi
	@echo "Applying custom Grafana dashboards (microservices)"
	-kubectl apply -f Manifests/monitoring/grafana-dashboard-microservices.yaml || true
	-bash Scripts/patch-grafana-dashboard-mount.sh monitoring grafana grafana-dashboard-microservices || true
	-kubectl -n monitoring rollout status deploy/grafana --timeout=120s || true
	@echo "Applying monitoring PodMonitors"
	-kubectl apply -f Manifests/monitoring/podmonitors.yaml || true
	@echo "Applying GKE BackendConfigs for health checks"
	-kubectl apply -f Manifests/monitoring/gke/backendconfigs.yaml || true
	@echo "Applying Prometheus override (route prefix /prom)"
	-kubectl apply -f Manifests/monitoring/prometheus-overrides.yaml || true
	@echo "Annotating backend Services for GCE Ingress (NEGs + BackendConfig)"
	-kubectl -n monitoring annotate svc grafana cloud.google.com/neg='{"ingress": true}' --overwrite || true
	-kubectl -n monitoring annotate svc grafana cloud.google.com/backend-config='{"ports":{"http":"grafana-bcfg"}}' --overwrite || true
	# Ensure Prometheus web Service has expected healthcheck path (idempotent)
	-kubectl -n monitoring annotate svc prometheus-web cloud.google.com/healthcheck-path="/prom/-/ready" --overwrite || true
	@echo "Applying GKE Service for Prometheus web (NEG-enabled)"
	-kubectl apply -f Manifests/monitoring/gke/prometheus-web-svc.yaml || true
	# Explicit healthcheck path annotation (in addition to BackendConfig) to aid GCLB
	-kubectl -n monitoring annotate svc grafana cloud.google.com/healthcheck-path="/login" --overwrite || true
	@echo "Applying GKE NetworkPolicy to allow monitoring ingress (namespace + GFE)"
	-kubectl apply -f Manifests/monitoring/gke/netpol-allow-monitoring-ingress.yaml || true
	@echo "Applying GKE monitoring Ingress (HTTP on port 80)"
	-kubectl apply -f Manifests/monitoring/gke/ingress.yaml || true
	@echo "Setting Prometheus externalUrl from monitoring Ingress"
	-bash Scripts/set-prometheus-external-url.sh || true
	@echo "Done. Check namespace: monitoring"
