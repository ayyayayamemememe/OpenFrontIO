#!/bin/bash
# redeploy.sh - pull the latest code, rebuild the image on THIS box, and swap
# the running container. No registry, no CI, no SSH — everything happens here.
#
# First-time setup: copy .env.app.example to .env.app and set DOMAIN.
# Every time after that: just run ./redeploy.sh
set -euo pipefail

CONTAINER_NAME="openfront"
IMAGE_NAME="openfront-local:latest"
ENV_FILE=".env.app"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ $ENV_FILE not found."
    echo "Copy .env.app.example to .env.app and fill in DOMAIN first."
    exit 1
fi

echo "======================================================"
echo "🔄 Pulling latest code..."
echo "======================================================"
git pull

GIT_COMMIT="$(git rev-parse HEAD)"
echo "======================================================"
echo "🏗️  Building image ($GIT_COMMIT)..."
echo "======================================================"
docker build --build-arg GIT_COMMIT="$GIT_COMMIT" -t "$IMAGE_NAME" .

echo "======================================================"
echo "🔀 Swapping container..."
echo "======================================================"
docker rm -f "$CONTAINER_NAME" 2> /dev/null || true

# In case this is run before setup.sh's Traefik/cloudflared stack exists
docker network create web 2> /dev/null || true

docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --env-file "$ENV_FILE" \
    --network web \
    --label "traefik.enable=true" \
    --label "traefik.http.routers.${CONTAINER_NAME}.rule=PathPrefix(\`/\`)" \
    --label "traefik.http.routers.${CONTAINER_NAME}.entrypoints=web" \
    --label "traefik.http.services.${CONTAINER_NAME}.loadbalancer.server.port=80" \
    "$IMAGE_NAME"

echo "======================================================"
echo "🧹 Cleaning up old images..."
echo "======================================================"
docker image prune -f

echo "======================================================"
echo "✅ DONE — $CONTAINER_NAME is running $GIT_COMMIT"
echo "======================================================"
docker ps --filter "name=$CONTAINER_NAME"
