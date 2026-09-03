#!/bin/bash
# Comprehensive setup script for a Linux VPS (adapted from the upstream OpenFrontIO
# script for OVHcloud — works on any Ubuntu/Debian box) with Docker, user setup,
# a Cloudflare Tunnel, Node Exporter, and OpenTelemetry.
#
# This box never opens an inbound port for the game: cloudflared makes an outbound
# connection to Cloudflare's edge, and Cloudflare routes your domain's traffic back
# down that tunnel to an internal-only Traefik, which fans it out to whichever app
# container(s) are currently live (blue/green).

set -e

echo "====================================================="
echo "🚀 STARTING SERVER SETUP"
echo "====================================================="

# Load environment variables from .env.setup if present
ENV_FILE="$(dirname "$0")/.env.setup"
if [ -f "$ENV_FILE" ]; then
    echo "📂 Loading environment from $ENV_FILE"
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
else
    echo "ℹ️  No .env.setup file found"
    exit 1
fi

# CF_TUNNEL_TOKEN: token for a Cloudflare Tunnel. Authenticates cloudflared to your
# Cloudflare account with no locally-managed certs or config files.
# Generate one at: Cloudflare Zero Trust dashboard -> Networks -> Tunnels ->
# Create a tunnel -> Docker, then copy the token out of the install command shown.
# Add a Public Hostname for your domain in that same dashboard, pointing it at:
#   http://traefik:80
# That's the only "ingress rule" you need — it lives in Cloudflare's config, not
# on this box.
if [ -z "$CF_TUNNEL_TOKEN" ]; then
    echo "❌ ERROR: CF_TUNNEL_TOKEN is not set!"
    echo "Create a tunnel at: Cloudflare Zero Trust -> Networks -> Tunnels -> Create a tunnel -> Docker"
    echo "Copy the token from the install command it shows you, then add it to .env.setup"
    echo "Point the tunnel's Public Hostname at: http://traefik:80"
    exit 1
fi

echo "🔄 Updating system..."
apt update && apt upgrade -y

# Install jq (used by update.sh for asset upload)
if command -v jq &> /dev/null; then
    echo "jq is already installed"
else
    echo "📦 Installing jq..."
    apt install -y jq
fi

# Check if Docker is already installed
if command -v docker &> /dev/null; then
    echo "Docker is already installed"
else
    echo "🐳 Installing Docker..."
    # Install Docker using official script
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    systemctl enable --now docker
    echo "Docker installed successfully"
fi

echo "👤 Setting up openfront user..."
# Create openfront user if it doesn't exist
if id "openfront" &> /dev/null; then
    echo "User openfront already exists"
else
    useradd -m -s /bin/bash openfront
    echo "User openfront created"
fi

# Check if openfront is already in docker group
if groups openfront | grep -q '\bdocker\b'; then
    echo "User openfront is already in the docker group"
else
    usermod -aG docker openfront
    echo "Added openfront to docker group"
fi

# Create .ssh directory for openfront if it doesn't exist
if [ ! -d "/home/openfront/.ssh" ]; then
    mkdir -p /home/openfront/.ssh
    chmod 700 /home/openfront/.ssh
    echo "Created .ssh directory for openfront"
fi

# Copy SSH keys from root if they exist and haven't been copied yet
if [ -f /root/.ssh/authorized_keys ] && [ ! -f /home/openfront/.ssh/authorized_keys ]; then
    cp /root/.ssh/authorized_keys /home/openfront/.ssh/
    chmod 600 /home/openfront/.ssh/authorized_keys
    echo "SSH keys copied from root to openfront"
fi

# Configure UDP buffer sizes. Both the game's own WebSocket/QUIC traffic and
# cloudflared's tunnel protocol (QUIC by default) benefit from this.
# https://github.com/quic-go/quic-go/wiki/UDP-Buffer-Sizes
echo "🔧 Configuring UDP buffer sizes..."
if grep -q "net.core.rmem_max" /etc/sysctl.conf && grep -q "net.core.wmem_max" /etc/sysctl.conf; then
    echo "UDP buffer size settings already configured"
else
    echo "# UDP buffer size settings for improved QUIC performance" >> /etc/sysctl.conf
    echo "net.core.rmem_max=7500000" >> /etc/sysctl.conf
    echo "net.core.wmem_max=7500000" >> /etc/sysctl.conf
    sysctl -p
    echo "UDP buffer sizes configured and applied"
fi

# Set proper ownership for openfront's home directory
chown -R openfront:openfront /home/openfront
echo "Set proper ownership for openfront's home directory"

# Set up Traefik as an INTERNAL-ONLY reverse proxy, with the Cloudflare Tunnel
# as the sole public entry point. Neither container publishes a host port —
# cloudflared reaches Traefik over the shared "web" docker network, and the
# outside world only ever reaches Cloudflare's edge, never this box directly.
echo "🔀 Setting up Traefik + Cloudflare Tunnel..."

# Create the shared Docker network used by Traefik, cloudflared, and app containers
if docker network ls --format '{{.Name}}' | grep -q '^web$'; then
    echo "Docker network 'web' already exists"
else
    docker network create web
    echo "Created Docker network 'web'"
fi

TRAEFIK_CONFIG_DIR="/home/openfront/traefik"
mkdir -p "$TRAEFIK_CONFIG_DIR"

# No [api] block — dashboard is disabled for production.
# To access it for debugging, SSH tunnel: ssh -L 8080:localhost:8080 user@server
cat > "$TRAEFIK_CONFIG_DIR/traefik.toml" << 'EOF'
[log]
  level = "INFO"

[entryPoints]
  [entryPoints.web]
    address = ":80"

[providers]
  [providers.docker]
    endpoint = "unix:///var/run/docker.sock"
    exposedByDefault = false # Only route containers with traefik.enable=true
    network = "web"
    watch = true
EOF

cat > "$TRAEFIK_CONFIG_DIR/compose.yaml" << 'EOF'
networks:
  web:
    # External so blue/green containers can join independently.
    external: true

services:
  traefik:
    image: traefik:v3.6
    container_name: traefik
    restart: unless-stopped
    # No "ports:" — only reachable from other containers on the "web"
    # network (cloudflared included). Nothing is exposed to the host's
    # public interface.
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /home/openfront/traefik/traefik.toml:/etc/traefik/traefik.toml:ro
    networks:
      - web

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --no-autoupdate run
    environment:
      - TUNNEL_TOKEN=${CF_TUNNEL_TOKEN}
    networks:
      - web
EOF

# Give openfront ownership of the whole config dir — nothing here is a secret
# the app user shouldn't see (the tunnel token lives in .env.setup, not in
# these files).
chown -R openfront:openfront "$TRAEFIK_CONFIG_DIR"

docker compose -f "$TRAEFIK_CONFIG_DIR/compose.yaml" pull
docker compose -f "$TRAEFIK_CONFIG_DIR/compose.yaml" up -d

if docker ps | grep -q traefik && docker ps | grep -q cloudflared; then
    echo "✅ Traefik and cloudflared started successfully!"
else
    echo "❌ Failed to start Traefik or cloudflared. Check logs with: docker logs traefik / docker logs cloudflared"
    exit 1
fi

echo "====================================================="
echo "🎉 SETUP COMPLETE!"
echo "====================================================="
echo "The openfront user has been set up and has Docker permissions."
echo "UDP buffer sizes have been configured for optimal QUIC performance."
echo "Traefik is running as an internal-only reverse proxy — no public ports open."
echo "cloudflared is tunneling to Cloudflare's edge. Set the tunnel's Public"
echo "Hostname (Zero Trust dashboard) to point at: http://traefik:80"
echo ""
echo "📝 Configuration:"
echo "  - Traefik config:  $TRAEFIK_CONFIG_DIR"
echo "====================================================="
