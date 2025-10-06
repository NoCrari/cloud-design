#!/usr/bin/env bash
set -euo pipefail

# Installs Prometheus Operator + Prometheus stack using upstream kube-prometheus
# This script downloads the release tarball locally, then applies manifests.
# Requirements: internet access, curl, tar, kubectl configured

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
say(){ echo -e "${1}${2}${NC}"; }

command -v kubectl >/dev/null || { say "$RED" "kubectl not found"; exit 1; }
command -v curl >/dev/null || { say "$RED" "curl not found"; exit 1; }
command -v tar >/dev/null || { say "$RED" "tar not found"; exit 1; }

VERSION="release-0.13"  # kube-prometheus branch/tag
ARCHIVE_URL="https://github.com/prometheus-operator/kube-prometheus/archive/refs/heads/${VERSION}.tar.gz"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

say "$BLUE" "Downloading kube-prometheus (${VERSION})..."
curl -fsSL "$ARCHIVE_URL" -o "$TMPDIR/kp.tar.gz" || {
  say "$RED" "Failed to download $ARCHIVE_URL"; exit 1; }

say "$BLUE" "Extracting..."
tar -xzf "$TMPDIR/kp.tar.gz" -C "$TMPDIR"
ROOT_DIR="$TMPDIR/kube-prometheus-${VERSION}"

if [[ ! -d "$ROOT_DIR/manifests" ]]; then
  say "$RED" "Unexpected archive layout; manifests not found"; exit 1
fi

kubectl_retry() {
  local tries=1 max=5 delay=5
  while true; do
    if KUBECTL_REQUEST_TIMEOUT=120s kubectl --request-timeout=120s "$@"; then
      return 0
    fi
    if (( tries >= max )); then
      return 1
    fi
    say "$YELLOW" "kubectl failed (attempt ${tries}/${max}); retrying in ${delay}s..."
    sleep "$delay"; tries=$((tries+1)); delay=$((delay*2))
  done
}

say "$BLUE" "Applying kube-prometheus CRDs and setup (with retry)..."
kubectl_retry apply --server-side -f "$ROOT_DIR/manifests/setup" || {
  say "$RED" "Failed to apply setup manifests after retries"; exit 1; }

say "$YELLOW" "Waiting for CRDs to be established..."
kubectl wait --for=condition=Established crd/alertmanagers.monitoring.coreos.com --timeout=120s || true
kubectl wait --for=condition=Established crd/podmonitors.monitoring.coreos.com --timeout=120s || true
kubectl wait --for=condition=Established crd/probes.monitoring.coreos.com --timeout=120s || true
kubectl wait --for=condition=Established crd/prometheuses.monitoring.coreos.com --timeout=120s || true
kubectl wait --for=condition=Established crd/prometheusrules.monitoring.coreos.com --timeout=120s || true
kubectl wait --for=condition=Established crd/servicemonitors.monitoring.coreos.com --timeout=120s || true
kubectl wait --for=condition=Established crd/thanosrulers.monitoring.coreos.com --timeout=120s || true

say "$BLUE" "Deploying kube-prometheus stack (with retry)..."
kubectl_retry apply -f "$ROOT_DIR/manifests" || {
  say "$RED" "Failed to apply kube-prometheus manifests after retries"; exit 1; }

say "$GREEN" "kube-prometheus installed. Namespace 'monitoring' will contain Prometheus/Alertmanager/Grafana (if included)."
say "$YELLOW" "Your ServiceMonitors in other namespaces (e.g., microservices) should now be picked up."
