#!/usr/bin/env bash
set -euo pipefail

# Set Ingress.spec.rules[0].host to api.<LB_IP>.nip.io for the API gateway
# and update the ManagedCertificate domain accordingly (if present).
#
# Env overrides:
#   NS              Namespace of ingress/cert (default: microservices)
#   INGRESS_NAME    Ingress name               (default: api-gateway)
#   CERT_NAME       ManagedCertificate name    (default: api-cert)
#   WAIT_TIMEOUT    Max seconds to wait for LB (default: 600)

NS=${NS:-microservices}
INGRESS_NAME=${INGRESS_NAME:-api-gateway}
CERT_NAME=${CERT_NAME:-api-cert}
WAIT_TIMEOUT=${WAIT_TIMEOUT:-900}

blue='\033[0;34m'; green='\033[0;32m'; yellow='\033[1;33m'; red='\033[0;31m'; nc='\033[0m'
say(){ echo -e "${1}${2}${nc}"; }

require() { command -v "$1" >/dev/null 2>&1 || { say "$red" "Missing dependency: $1"; exit 1; }; }
require kubectl

say "$blue" "Waiting for Ingress ${NS}/${INGRESS_NAME} to have an external IP..."
start_ts=$(date +%s)
ip=""
while true; do
  ip=$(kubectl -n "$NS" get ingress "$INGRESS_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "$ip" ]]; then break; fi
  # If Ingress forbids HTTP and no TLS (managed-cert annotation) is set yet, temporarily allow HTTP so GCLB can be created
  allow_http=$(kubectl -n "$NS" get ingress "$INGRESS_NAME" -o jsonpath='{.metadata.annotations.kubernetes\.io/ingress\.allow-http}' 2>/dev/null || true)
  mc_annot=$(kubectl -n "$NS" get ingress "$INGRESS_NAME" -o jsonpath='{.metadata.annotations.networking\.gke\.io/managed-certificates}' 2>/dev/null || true)
  if [[ ("$allow_http" == "false" || -z "$allow_http") && -z "$mc_annot" ]]; then
    say "$yellow" "No TLS configured yet and HTTP disabled; temporarily enabling HTTP for LB provisioning..."
    kubectl -n "$NS" annotate ingress "$INGRESS_NAME" kubernetes.io/ingress.allow-http="true" --overwrite || true
  fi
  now=$(date +%s)
  if (( now - start_ts >= WAIT_TIMEOUT )); then
    say "$red" "Timed out after ${WAIT_TIMEOUT}s waiting for Ingress IP."; exit 1
  fi
  sleep 5
done

host="api.${ip}.nip.io"
say "$green" "Ingress IP detected: ${ip}"
say "$blue" "Target host: ${host}"

# Read current host
current_host=$(kubectl -n "$NS" get ingress "$INGRESS_NAME" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)
if [[ "$current_host" == "$host" ]]; then
  say "$yellow" "Ingress host already set; nothing to do."
else
  say "$blue" "Patching Ingress host..."
  kubectl -n "$NS" patch ingress "$INGRESS_NAME" \
    --type json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"${host}\"}]" || true
fi

# Update ManagedCertificate if it exists
mc_exists=false
if kubectl -n "$NS" get managedcertificate "$CERT_NAME" >/dev/null 2>&1; then
  mc_exists=true
fi

ensure_annotation_contains() {
  local names="$1"
  local current
  current=$(kubectl -n "$NS" get ingress "$INGRESS_NAME" -o jsonpath='{.metadata.annotations.networking\.gke\.io/managed-certificates}' 2>/dev/null || true)
  if [[ "$current" != "$names" ]]; then
    say "$blue" "Patching Ingress managed-certificates annotation → '$names'"
    kubectl -n "$NS" annotate ingress "$INGRESS_NAME" networking.gke.io/managed-certificates="$names" --overwrite || true
  fi
}

wait_cert_active() {
  local cert_name="$1"; local start_ts now status dstatus
  say "$blue" "Waiting for ManagedCertificate ${NS}/${cert_name} to become Active (timeout ${WAIT_TIMEOUT}s)..."
  start_ts=$(date +%s)
  local last_status="" last_dstatus="" last_log=0
  while true; do
    status=$(kubectl -n "$NS" get managedcertificate "$cert_name" -o jsonpath='{.status.certificateStatus}' 2>/dev/null || true)
    dstatus=$(kubectl -n "$NS" get managedcertificate "$cert_name" -o jsonpath='{.status.domainStatus[0].status}' 2>/dev/null || true)
    if [[ "$status" == "Active" || "$dstatus" == "Active" ]]; then
      say "$green" "ManagedCertificate ${cert_name} is Active."
      return 0
    fi
    now=$(date +%s)
    # Log when status changes or every 20s
    if [[ "$status/$dstatus" != "$last_status/$last_dstatus" || $((now - last_log)) -ge 20 ]]; then
      say "$yellow" "Status: certificateStatus='${status:-<none>}' domainStatus='${dstatus:-<none>}' (elapsed $((now - start_ts))s)"
      # Try to print last event line (best-effort)
      kubectl -n "$NS" get events --field-selector involvedObject.kind=ManagedCertificate,involvedObject.name="$cert_name" --sort-by=.lastTimestamp 2>/dev/null | tail -n 1 || true
      last_status="$status"; last_dstatus="$dstatus"; last_log=$now
    fi
    if (( now - start_ts >= WAIT_TIMEOUT )); then
      say "$red" "Timed out waiting for certificate ${cert_name} to become Active."
      return 1
    fi
    sleep 5
  done
}

is_active() {
  local cert_name="$1"
  local status dstatus
  status=$(kubectl -n "$NS" get managedcertificate "$cert_name" -o jsonpath='{.status.certificateStatus}' 2>/dev/null || true)
  dstatus=$(kubectl -n "$NS" get managedcertificate "$cert_name" -o jsonpath='{.status.domainStatus[0].status}' 2>/dev/null || true)
  [[ "$status" == "Active" || "$dstatus" == "Active" ]]
}

if [[ "$mc_exists" == true ]]; then
  current_domain=$(kubectl -n "$NS" get managedcertificate "$CERT_NAME" -o jsonpath='{.spec.domains[0]}' 2>/dev/null || true)
  if [[ "$current_domain" == "$host" ]]; then
    say "$yellow" "ManagedCertificate ${CERT_NAME} already targets ${host}. Ensuring annotation and waiting for Active..."
    ensure_annotation_contains "$CERT_NAME"
    wait_cert_active "$CERT_NAME" || true
  else
    # Rotate certificate: create a new one named with the target IP to avoid update-in-use errors
    new_name="${CERT_NAME}-$(echo "$ip" | tr '.' '-')"
    say "$blue" "Rotating ManagedCertificate: ${CERT_NAME} (${current_domain}) → ${new_name} (${host})"
    kubectl -n "$NS" apply -f - <<EOF
apiVersion: networking.gke.io/v1
kind: ManagedCertificate
metadata:
  name: ${new_name}
  namespace: ${NS}
spec:
  domains:
  - ${host}
EOF
    # Attach both old and new to avoid downtime, then wait for new to be Active, then switch to new only
    ensure_annotation_contains "${CERT_NAME},${new_name}"
    if wait_cert_active "$new_name"; then
      ensure_annotation_contains "${new_name}"
      # best-effort cleanup of old cert
      kubectl -n "$NS" delete managedcertificate "$CERT_NAME" --ignore-not-found=true || true
      # Optionally rename: we keep new_name
    fi
  fi
else
  # Prefer creating a unique cert name tied to the current IP to avoid GC/controller update races
  new_name="${CERT_NAME}-$(echo "$ip" | tr '.' '-')"
  say "$blue" "Creating ManagedCertificate ${NS}/${new_name} for ${host} and attaching to Ingress..."
  kubectl -n "$NS" apply -f - <<EOF
apiVersion: networking.gke.io/v1
kind: ManagedCertificate
metadata:
  name: ${new_name}
  namespace: ${NS}
spec:
  domains:
  - ${host}
EOF
  ensure_annotation_contains "$new_name"
  if ! wait_cert_active "$new_name"; then
    say "$yellow" "Certificate ${new_name} not Active yet; will keep HTTP enabled until it activates."
  else
    # Best-effort cleanup of any other api-cert* leftover
    for mc in $(kubectl -n "$NS" get managedcertificate -o name | sed -n 's|.*/||p'); do
      if [[ "$mc" != "$new_name" && "$mc" == ${CERT_NAME}* ]]; then
        kubectl -n "$NS" delete managedcertificate "$mc" --ignore-not-found=true || true
      fi
    done
    # Disable HTTP only when TLS is active
    say "$blue" "Disabling HTTP on Ingress now that TLS is active..."
    kubectl -n "$NS" annotate ingress "$INGRESS_NAME" kubernetes.io/ingress.allow-http="false" --overwrite || true
  fi
fi

say "$green" "Done. Ingress host set to ${host}. HTTPS will work once the certificate is Active."
