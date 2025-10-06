#!/usr/bin/env bash
set -euo pipefail

# Set Prometheus.spec.externalUrl to the public address of the monitoring Ingress.
# Works for GCE/GCLB (uses .status.loadBalancer.ingress[0].ip or .hostname).
#
# Env overrides:
#   PROM_NAMESPACE   Namespace of Prometheus resource (default: monitoring)
#   PROM_NAME        Prometheus resource name        (default: k8s)
#   INGRESS_NAMESPACE Namespace of the Ingress       (default: monitoring)
#   INGRESS_NAME     Ingress resource name           (default: monitoring-ingress)
#   ROUTE_PREFIX     Route prefix for Prometheus     (default: /prom)
#   WAIT_TIMEOUT     Max seconds to wait for IP/DNS  (default: 600)

PROM_NAMESPACE=${PROM_NAMESPACE:-monitoring}
PROM_NAME=${PROM_NAME:-k8s}
INGRESS_NAMESPACE=${INGRESS_NAMESPACE:-monitoring}
INGRESS_NAME=${INGRESS_NAME:-monitoring-ingress}
ROUTE_PREFIX=${ROUTE_PREFIX:-/prom}
WAIT_TIMEOUT=${WAIT_TIMEOUT:-600}

blue='\033[0;34m'; green='\033[0;32m'; yellow='\033[1;33m'; red='\033[0;31m'; nc='\033[0m'
say(){ echo -e "${1}${2}${nc}"; }

require() { command -v "$1" >/dev/null 2>&1 || { say "$red" "Missing dependency: $1"; exit 1; }; }
require kubectl

say "$blue" "Waiting for Ingress ${INGRESS_NAMESPACE}/${INGRESS_NAME} to have an external address..."

start_ts=$(date +%s)
addr=""
while true; do
  # Try IP first, then hostname
  ip=$(kubectl -n "$INGRESS_NAMESPACE" get ingress "$INGRESS_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  host=$(kubectl -n "$INGRESS_NAMESPACE" get ingress "$INGRESS_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

  if [[ -n "${ip}" ]]; then
    addr="$ip"
    break
  fi
  if [[ -n "${host}" ]]; then
    addr="$host"
    break
  fi

  now=$(date +%s)
  elapsed=$(( now - start_ts ))
  if (( elapsed >= WAIT_TIMEOUT )); then
    say "$red" "Timed out after ${WAIT_TIMEOUT}s waiting for Ingress address."
    exit 1
  fi
  sleep 5
done

url="http://${addr}${ROUTE_PREFIX}"
say "$green" "Ingress address detected: ${addr}"
say "$blue" "Target externalUrl: ${url}"

# Read current value to avoid unnecessary patch
current=$(kubectl -n "$PROM_NAMESPACE" get prometheus "$PROM_NAME" -o jsonpath='{.spec.externalUrl}' 2>/dev/null || true)
if [[ "$current" == "$url" ]]; then
  say "$yellow" "Prometheus.spec.externalUrl already set to desired value; nothing to do."
  exit 0
fi

say "$blue" "Patching Prometheus ${PROM_NAMESPACE}/${PROM_NAME} externalUrl..."
kubectl -n "$PROM_NAMESPACE" patch prometheus "$PROM_NAME" \
  --type merge \
  -p "{\"spec\":{\"externalUrl\":\"${url}\"}}"

say "$green" "Done. externalUrl updated to ${url}."

