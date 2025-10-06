#!/usr/bin/env bash
set -euo pipefail

# Ensure Grafana Deployment consumes admin credentials from Secret "grafana".
# Adds env vars GF_SECURITY_ADMIN_USER and GF_SECURITY_ADMIN_PASSWORD via strategic merge patch.

NS=${1:-monitoring}
DEPLOY=${2:-grafana}
SECRET_NAME=${3:-grafana}

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found" >&2
  exit 1
fi

json_patch=$(cat <<'JSON'
{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "grafana",
            "env": [
              {
                "name": "GF_SECURITY_ADMIN_USER",
                "valueFrom": {
                  "secretKeyRef": {
                    "name": "grafana",
                    "key": "admin-user"
                  }
                }
              },
              {
                "name": "GF_SECURITY_ADMIN_PASSWORD",
                "valueFrom": {
                  "secretKeyRef": {
                    "name": "grafana",
                    "key": "admin-password"
                  }
                }
              }
            ]
          }
        ]
      }
    }
  }
}
JSON
)

kubectl -n "$NS" patch deploy "$DEPLOY" --type strategic -p "$json_patch"

echo "Patched deployment $NS/$DEPLOY to read admin creds from Secret '$SECRET_NAME'."

