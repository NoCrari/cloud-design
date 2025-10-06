#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${1:-microservices}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
say(){ echo -e "${1}${2}${NC}"; }

command -v kubectl >/dev/null || { say "$RED" "kubectl not found"; exit 1; }

say "$BLUE" "=== Health Check for Audit (${NAMESPACE}) ==="

say "$YELLOW" "1) Nodes"; kubectl get nodes -o wide; echo

say "$YELLOW" "2) Namespace exists?"
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  say "$GREEN" "✓ Namespace '$NAMESPACE' exists"
else
  say "$RED" "✗ Namespace '$NAMESPACE' missing"; exit 1
fi
echo

say "$YELLOW" "3) Secrets"; kubectl get secrets -n "$NAMESPACE"; echo
say "$YELLOW" "4) All resources"; kubectl get all -n "$NAMESPACE"; echo

say "$YELLOW" "5) Deployment vs StatefulSet"
echo "Deployments:"; kubectl get deploy -n "$NAMESPACE" --no-headers || true
echo "StatefulSets:"; kubectl get sts -n "$NAMESPACE" --no-headers || true
echo

say "$YELLOW" "6) HPA"; kubectl get hpa -n "$NAMESPACE" || say "$YELLOW" "(none or metrics not ready)"; echo

say "$YELLOW" "7) PersistentVolumes (bound to $NAMESPACE)"
mapfile -t PVS < <(kubectl get pv -o jsonpath='{range .items[?(@.spec.claimRef.namespace=="'"$NAMESPACE"'")]}{.metadata.name}{"\n"}{end}' || true)
if ((${#PVS[@]})); then printf '%s\n' "${PVS[@]}"; else say "$YELLOW" "No PVs found"; fi
echo

# Determine API Gateway access
say "$YELLOW" "8) API Gateway access"
if kubectl get ingress -n "$NAMESPACE" api-gateway >/dev/null 2>&1; then
  HOST=$(kubectl get ingress -n "$NAMESPACE" api-gateway -o jsonpath='{.spec.rules[0].host}')
  say "$GREEN" "Ingress host detected: http://$HOST (use HTTPS if cert ready)"
else
  say "$YELLOW" "No Ingress found; trying local port-forward to svc/api-gateway (3000)"
  (kubectl -n "$NAMESPACE" port-forward svc/api-gateway 3000:3000 >/dev/null 2>&1 & PF_PID=$!; \
    sleep 2; \
    if curl -fsS http://127.0.0.1:3000/ >/dev/null; then \
      say "$GREEN" "✓ API reachable at http://127.0.0.1:3000/"; \
    else \
      say "$RED" "✗ API not reachable via port-forward"; \
    fi; \
    kill $PF_PID >/dev/null 2>&1 || true)
fi
echo

say "$BLUE" "=== Summary ==="
TOTAL_PODS=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | xargs)
RUNNING_PODS=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "Running" || true)
say "$GREEN" "Pods running: ${RUNNING_PODS}/${TOTAL_PODS}"

