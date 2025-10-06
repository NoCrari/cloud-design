#!/usr/bin/env bash
set -euo pipefail

# Mount a dashboard ConfigMap into Grafana's dashboard definitions dir.
# Usage: patch-grafana-dashboard-mount.sh [namespace] [deployment] [configmap-name]

NS=${1:-monitoring}
DEPLOY=${2:-grafana}
CM=${3:-grafana-dashboard-microservices}

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found" >&2
  exit 1
fi

json_patch=$(cat <<JSON
{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "grafana",
            "volumeMounts": [
              {
                "name": "${CM}",
                "mountPath": "/grafana-dashboard-definitions/0/microservices",
                "readOnly": false
              }
            ]
          }
        ],
        "volumes": [
          {
            "name": "${CM}",
            "configMap": {
              "name": "${CM}",
              "defaultMode": 420
            }
          }
        ]
      }
    }
  }
}
JSON
)

kubectl -n "$NS" patch deploy "$DEPLOY" --type strategic -p "$json_patch"

echo "Patched $NS/$DEPLOY to mount dashboard ConfigMap '$CM'."

