#!/usr/bin/env bash
set -euo pipefail

# Apply manifests to a GKE (or any Kubernetes) cluster with current kubectl context
# Usage: bash Scripts/gke-apply.sh

NAMESPACE="microservices"

say(){ echo -e "$1"; }
blue(){ say "\033[0;34m$*\033[0m"; }
yellow(){ say "\033[1;33m$*\033[0m"; }
green(){ say "\033[0;32m$*\033[0m"; }
red(){ say "\033[0;31m$*\033[0m"; }

command -v kubectl >/dev/null || { red "kubectl not found"; exit 1; }

blue "Using kubectl context: $(kubectl config current-context 2>/dev/null || echo unknown)"

# Ensure namespaces
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - || true

# Apply namespace manifest if present
if [[ -f Manifests/namespace.yaml ]]; then
  yellow "→ Applying namespace manifest"
  kubectl apply -f Manifests/namespace.yaml || true
fi

# Base config
yellow "→ Applying secrets and configmaps"
kubectl apply -n "$NAMESPACE" -f Manifests/secrets/ || true
kubectl apply -n "$NAMESPACE" -f Manifests/configmaps/ || true

# Messaging and databases
yellow "→ Applying messaging"
kubectl apply -n "$NAMESPACE" -f Manifests/messaging/ || true
yellow "→ Applying databases"
kubectl apply -n "$NAMESPACE" -f Manifests/databases/ || true

# Applications
yellow "→ Applying applications"
kubectl apply -n "$NAMESPACE" -f Manifests/apps/ || true

# Autoscaling
if [[ -d Manifests/autoscaling ]]; then
  yellow "→ Applying autoscaling"
  kubectl apply -n "$NAMESPACE" -f Manifests/autoscaling/ || true
fi

# NetworkPolicies (optional)
if [[ -d Manifests/networkpolicies ]]; then
  yellow "→ Applying network policies"
  kubectl apply -n "$NAMESPACE" -f Manifests/networkpolicies/ || true
fi

# Ingress (optional)
if [[ -d Manifests/ingress ]]; then
  yellow "→ Applying ingress"
  # Apply provider-specific (GKE) assets first to satisfy dependencies (e.g., BackendConfig)
  if [[ -d Manifests/ingress/gke ]]; then
    # Apply BackendConfig first if present
    if [[ -f Manifests/ingress/gke/backendconfigs.yaml ]]; then
      kubectl apply -f Manifests/ingress/gke/backendconfigs.yaml || true
    fi
    kubectl apply -f Manifests/ingress/gke/ || true
  fi
  # Then apply the main ingress resources (namespace-aware)
  kubectl apply -f Manifests/ingress/ || true
  yellow "→ Setting api-gateway host to api.<LB_IP>.nip.io"
  bash Scripts/set-api-ingress-host.sh || true
fi

# Monitoring extras: only apply if CRDs exist (stack installed separately)
if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  if [[ -f Manifests/monitoring/servicemonitors.yaml ]]; then
    yellow "→ Applying ServiceMonitors"
    kubectl apply -f Manifests/monitoring/servicemonitors.yaml || true
  fi
  if kubectl get crd podmonitors.monitoring.coreos.com >/dev/null 2>&1; then
    if [[ -f Manifests/monitoring/podmonitors.yaml ]]; then
      yellow "→ Applying PodMonitors"
      kubectl apply -f Manifests/monitoring/podmonitors.yaml || true
    fi
  fi
else
  yellow "Monitoring CRDs absent; install stack first (make monitoring)"
fi

green "All manifests applied. Check: kubectl get all -n ${NAMESPACE}"
