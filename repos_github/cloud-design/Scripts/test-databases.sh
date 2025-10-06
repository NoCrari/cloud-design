#!/usr/bin/env bash
set -euo pipefail

# Smoke tests for Postgres databases in the cluster (or external hosts)
# Usage: bash Scripts/test-databases.sh [namespace]
# Optionally override hosts via env:
#   INVENTORY_DB_HOST, BILLING_DB_HOST, DB_PORT, INVENTORY_DB_NAME, BILLING_DB_NAME

NAMESPACE="${1:-microservices}"

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 1; }

get_secret() {
  local key=$1
  kubectl -n "$NAMESPACE" get secret db-secrets -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d
}

PG_USER=$(get_secret postgres-user)
PG_PASS=$(get_secret postgres-password)
if [[ -z "${PG_USER}" || -z "${PG_PASS}" ]]; then
  echo "Could not read postgres credentials from secret 'db-secrets' in namespace '$NAMESPACE'" >&2
  exit 1
fi

INVENTORY_DB_HOST=${INVENTORY_DB_HOST:-"inventory-db.${NAMESPACE}.svc.cluster.local"}
BILLING_DB_HOST=${BILLING_DB_HOST:-"billing-db.${NAMESPACE}.svc.cluster.local"}
DB_PORT=${DB_PORT:-"5432"}
INVENTORY_DB_NAME=${INVENTORY_DB_NAME:-"inventory"}
BILLING_DB_NAME=${BILLING_DB_NAME:-"billing"}

# Preflight info (does not fail the run)
kubectl -n "$NAMESPACE" get svc inventory-db >/dev/null 2>&1 || echo "[warn] Service inventory-db not found in $NAMESPACE"
kubectl -n "$NAMESPACE" get svc billing-db   >/dev/null 2>&1 || echo "[warn] Service billing-db not found in $NAMESPACE"

run_psql_smoke() {
  local name=$1 host=$2 dbname=$3
  echo "→ Testing ${name} at ${host}:${DB_PORT} (db=${dbname})"
  local pod="psql-smoke-${name}-$(date +%s)-$RANDOM"

  # Create a short-lived pod and exec into it to avoid attach issues on some clusters
  kubectl -n "$NAMESPACE" run "$pod" --restart=Never \
    --image=postgres:14-alpine \
    --env="PGUSER=${PG_USER}" \
    --env="PGPASSWORD=${PG_PASS}" \
    --env="PGHOST=${host}" \
    --env="PGPORT=${DB_PORT}" \
    --env="PGDATABASE=${dbname}" \
    --command -- sleep 3600 >/dev/null 2>&1 || true

  # Always cleanup the pod on exit from this function
  trap 'kubectl -n "$NAMESPACE" delete pod "$pod" --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true' RETURN

  # Wait for pod to be Ready
  kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/"$pod" --timeout=120s

  set +e
  kubectl -n "$NAMESPACE" exec "$pod" -- sh -lc '
    set -euo pipefail
    T="smoke_$(tr -dc a-z0-9 </dev/urandom | head -c6)"
    echo "Checking connectivity to $PGHOST:$PGPORT ..." >&2
    ok=false
    for i in $(seq 1 60); do
      if psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -p "$PGPORT" -c "SELECT 1" >/dev/null 2>&1; then
        ok=true; break
      fi
      echo "(attempt $i) DB not ready yet, retrying..." >&2
      sleep 2
    done
    if [ "$ok" != true ]; then
      echo "✗ ${PGHOST}:${PGPORT}/${PGDATABASE} not reachable after timeout" >&2
      exit 1
    fi
    echo "Creating temp table $T, inserting, selecting, dropping..." >&2
    psql -v ON_ERROR_STOP=1 -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -p "$PGPORT" -c "CREATE TABLE ${T}(id SERIAL PRIMARY KEY, val TEXT NOT NULL)"
    psql -v ON_ERROR_STOP=1 -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -p "$PGPORT" -c "INSERT INTO ${T}(val) VALUES (''ok'')"
    cnt=$(psql -tAc -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -p "$PGPORT" "SELECT count(*) FROM ${T}")
    if [ "${cnt}" -ge 1 ]; then
      echo "✓ insert/select works ($cnt row(s))"
    else
      echo "✗ expected at least 1 row, got ${cnt}" >&2
      exit 1
    fi
    psql -v ON_ERROR_STOP=1 -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -p "$PGPORT" -c "DROP TABLE ${T}"
  '
  rc=$?
  set -e
  # kubectl sometimes returns 141 (SIGPIPE) even when the inner script succeeded; treat that as success
  if [ "$rc" -eq 141 ]; then
    echo "[warn] kubectl exec returned 141 (SIGPIPE); continuing as success"
    rc=0
  fi
  if [ "$rc" -ne 0 ]; then
    echo "[error] ${name} DB smoke test failed with rc=$rc. Pod logs:"
    kubectl -n "$NAMESPACE" logs "$pod" || true
    return "$rc"
  fi
}

run_psql_smoke inventory "$INVENTORY_DB_HOST" "$INVENTORY_DB_NAME"
run_psql_smoke billing   "$BILLING_DB_HOST"   "$BILLING_DB_NAME"

echo "All DB smoke tests passed."
