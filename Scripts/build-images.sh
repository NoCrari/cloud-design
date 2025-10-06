#!/usr/bin/env bash
set -euo pipefail

# Helper to build and optionally push all service images, then bump manifests
# Usage: bash Scripts/build-images.sh [TAG] [--push]

TAG="${1:-}"
PUSH="${2:-}"
USERNAME="${DOCKER_HUB_USERNAME:-nocrarii}"

if [[ -z "$TAG" ]]; then
  TAG="v$(date +%Y%m%d%H%M)"
fi

blue(){ printf "\033[0;34m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[1;33m%s\033[0m\n" "$*"; }
green(){ printf "\033[0;32m%s\033[0m\n" "$*"; }

blue "Building images with tag: $TAG (user: $USERNAME)"

declare -A MAP=(
  [api-gateway]="Dockerfiles/api-gateway-app"
  [inventory-app]="Dockerfiles/inventory-app"
  [billing-app]="Dockerfiles/billing-app"
  [inventory-db]="Dockerfiles/inventory-db"
  [billing-db]="Dockerfiles/billing-db"
  [rabbitmq]="Dockerfiles/rabbitmq"
)

for name in "${!MAP[@]}"; do
  ctx="${MAP[$name]}"
  image="${USERNAME}/${name}:${TAG}"
  yellow "→ Building $image from $ctx"
  docker build -t "$image" "$ctx"
  if [[ "$PUSH" == "--push" || "$PUSH" == "push" ]]; then
    yellow "→ Pushing $image"
    docker push "$image"
  fi
done

# Update manifests
yellow "→ Updating manifests with new tags"
sed -i -E "s|(image:\s*)${USERNAME}/api-gateway:[a-zA-Z0-9._-]+|\1${USERNAME}/api-gateway:${TAG}|" Manifests/apps/api-gateway.yaml
sed -i -E "s|(image:\s*)${USERNAME}/inventory-app:[a-zA-Z0-9._-]+|\1${USERNAME}/inventory-app:${TAG}|" Manifests/apps/inventory-app.yaml
sed -i -E "s|(image:\s*)${USERNAME}/billing-app:[a-zA-Z0-9._-]+|\1${USERNAME}/billing-app:${TAG}|" Manifests/apps/billing-app.yaml
sed -i -E "s|(image:\s*)${USERNAME}/inventory-db:[a-zA-Z0-9._-]+|\1${USERNAME}/inventory-db:${TAG}|" Manifests/databases/inventory-db.yaml
sed -i -E "s|(image:\s*)${USERNAME}/billing-db:[a-zA-Z0-9._-]+|\1${USERNAME}/billing-db:${TAG}|" Manifests/databases/billing-db.yaml
sed -i -E "s|(image:\s*)${USERNAME}/rabbitmq:[a-zA-Z0-9._-]+|\1${USERNAME}/rabbitmq:${TAG}|" Manifests/messaging/rabbitmq.yaml

green "Done. Manifests point to tag $TAG"

