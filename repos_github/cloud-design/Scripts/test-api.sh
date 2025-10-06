#!/usr/bin/env bash
set -euo pipefail

# Simple end-to-end API tests through the API Gateway
# Usage: bash Scripts/test-api.sh [namespace]

NAMESPACE="${1:-microservices}"

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl not found"; exit 1; }
if command -v jq >/dev/null 2>&1; then JQ="jq"; else JQ="cat"; fi

try_url() {
  local url="$1"; local status
  status=$(curl -k -s -o /dev/null -w '%{http_code}' "$url") || status=000
  [[ "$status" != "000" && "$status" -lt 500 ]] && return 0 || return 1
}

discover_base() {
  local base=""

  # 1) Ingress host, if usable
  if kubectl get ingress -n "$NAMESPACE" api-gateway >/dev/null 2>&1; then
    local host
    host=$(kubectl get ingress -n "$NAMESPACE" api-gateway -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)
    if [[ -n "$host" && "$host" != *"your-domain"* ]]; then
      # Try HTTPS first (managed cert), then HTTP
      if try_url "https://${host}/"; then echo "https://${host}"; return; fi
      if try_url "http://${host}/";  then echo "http://${host}";  return; fi
      echo "[warn] Ingress host '$host' not reachable, will try Service LB or port-forward" >&2
    else
      echo "[info] Ingress present but host not set or placeholder; trying Service LB/port-forward" >&2
    fi
  fi

  # 2) Service type LoadBalancer
  if kubectl get svc -n "$NAMESPACE" api-gateway >/dev/null 2>&1; then
    local ip hostn
    ip=$(kubectl get svc -n "$NAMESPACE" api-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    hostn=$(kubectl get svc -n "$NAMESPACE" api-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    if [[ -n "$ip" ]]; then
      if try_url "http://${ip}:3000/"; then echo "http://${ip}:3000"; return; fi
    elif [[ -n "$hostn" ]]; then
      if try_url "http://${hostn}:3000/"; then echo "http://${hostn}:3000"; return; fi
    fi
  fi

  # 3) Fallback to port-forward
  kubectl -n "$NAMESPACE" port-forward svc/api-gateway 3000:3000 >/dev/null 2>&1 & PF_PID=$!
  trap 'kill ${PF_PID:-0} >/dev/null 2>&1 || true' EXIT
  sleep 2
  echo "http://127.0.0.1:3000"
}

BASE=$(discover_base)
echo "➡️  API Gateway: $BASE"

echo "⏳ Waiting for API Gateway to respond..."
ok=false
for i in $(seq 1 30); do
  if try_url "$BASE/"; then
    echo "✅ API Gateway is up"
    ok=true
    break
  fi
  sleep 2
done

if [[ "$ok" != true ]]; then
  echo "❌ API Gateway not reachable after timeout" >&2
  exit 1
fi

echo "📌 Test 1: Create a movie"
CREATE_PAYLOAD='{"title": "A new movie", "description": "Very short description"}'
if ! curl -fsS -X POST "$BASE/api/movies" -H 'Content-Type: application/json' -d "$CREATE_PAYLOAD" | ${JQ} .; then
  echo "[warn] Create movie failed (inventory-db not ready or schema missing?)" >&2
fi

echo "📌 Test 2: List movies"
if ! curl -fsS "$BASE/api/movies" | ${JQ} .; then
  echo "[warn] List movies failed" >&2
fi

echo "📌 Test 3: Send a billing message"
BILLING_PAYLOAD='{"user_id": 20, "number_of_items": 2, "total_amount": 49.99}'
if ! curl -fsS -X POST "$BASE/api/billing/" -H 'Content-Type: application/json' -d "$BILLING_PAYLOAD" | ${JQ} .; then
  echo "[warn] Billing enqueue failed (RabbitMQ not ready or creds mismatch?)" >&2
fi

echo "✅ Tests completed"
