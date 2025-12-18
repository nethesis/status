#!/bin/bash
# Deployment script for Cachet infrastructure on Podman

set -e

echo "=========================================="
echo "Cachet Infrastructure Deployment"
echo "=========================================="

# Prepare Cachet repository
echo ""

echo "Preparing Cachet repository..."
# Remove existing local cachet folder if present
if [ -d "cachet" ]; then
    echo "Removing existing cachet/ folder..."
    rm -rf cachet
fi

# Copy SSH directory for Docker build context (for composer update in Dockerfile)
SSH_BUILD_CONTEXT="cachet-configuration-files/.ssh"
if [ -d "$SSH_BUILD_CONTEXT" ]; then
    echo "Removing old .ssh from build context..."
    rm -rf "$SSH_BUILD_CONTEXT"
fi
echo "Copying ~/.ssh to $SSH_BUILD_CONTEXT for build context..."
cp -r ~/.ssh "$SSH_BUILD_CONTEXT"

# Clone Cachet repository
echo "Cloning cachet repository..."
git clone git@github.com:cachethq/cachet.git cachet || { echo "Error cloning cachet"; exit 1; }

# Copy Dockerfile and docker folder into the new cachet folder
cp cachet-configuration-files/Dockerfile cachet/Dockerfile
cp -r cachet-configuration-files/docker cachet/

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    echo -e "${YELLOW}Warning: Running as root. Rootless podman is recommended for better security.${NC}"
    echo -e "${YELLOW}Continuing anyway... Press CTRL+C to abort or Enter to continue.${NC}"
    read
fi

# Check if .env exists
if [ ! -f .env ]; then
    echo -e "${YELLOW}Warning: .env file not found${NC}"
    echo "Copying .env.example to .env..."
    cp .env.example .env
    echo -e "${YELLOW}Please edit .env file with your configuration before proceeding${NC}"
    echo "Press CTRL+C to exit and edit .env, or press Enter to continue..."
    read
fi

# Load environment variables
source .env

# Auto-detect and set PODMAN_SOCKET in .env if not set or invalid
detect_and_set_podman_socket() {
    local socket_path=""
    if [ "$EUID" -eq 0 ]; then
        # Root context
        socket_path="/run/podman/podman.sock"
    else
        # Rootless context
        socket_path="/run/user/$(id -u)/podman/podman.sock"
    fi

    # If PODMAN_SOCKET is not set or is not the detected value, update .env
    if ! grep -q "^PODMAN_SOCKET=" .env; then
        echo "PODMAN_SOCKET=\"$socket_path\"" >> .env
        export PODMAN_SOCKET="$socket_path"
        echo -e "${GREEN}✓${NC} PODMAN_SOCKET set to $socket_path in .env"
    else
        current_socket=$(grep "^PODMAN_SOCKET=" .env | cut -d= -f2- | tr -d '"')
        if [ "$current_socket" != "$socket_path" ]; then
            sed -i "s|^PODMAN_SOCKET=.*|PODMAN_SOCKET=\"$socket_path\"|" .env
            export PODMAN_SOCKET="$socket_path"
            echo -e "${GREEN}✓${NC} PODMAN_SOCKET updated to $socket_path in .env"
        else
            export PODMAN_SOCKET="$current_socket"
            echo -e "${GREEN}✓${NC} PODMAN_SOCKET already set correctly in .env"
        fi
    fi
}

detect_and_set_podman_socket

# Check and start Podman rootless socket if needed
if [ "$EUID" -ne 0 ] && [[ "$PODMAN_SOCKET" == /run/user/* ]]; then
    echo "Checking Podman rootless socket..."
    if ! systemctl --user is-active --quiet podman.socket; then
        echo "Podman rootless socket is not active. Starting it..."
        systemctl --user start podman.socket
        sleep 2
    fi
    if ! systemctl --user is-active --quiet podman.socket; then
        echo "Error: Podman rootless socket could not be started. Please check your user session and permissions."
        exit 1
    fi
fi

# Check required environment variables
REQUIRED_VARS=("DB_PASSWORD")
MISSING_VARS=()

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ] || [ "${!var}" == "YOUR_"* ]; then
        MISSING_VARS+=("$var")
    fi
done

# Check APP_KEY and CACHET_API_TOKEN but allow temporary values
if [ -z "${APP_KEY}" ] || [ "${APP_KEY}" == "YOUR_"* ]; then
    echo -e "${YELLOW}Warning: APP_KEY not set. You'll need to generate it after deployment with: make key${NC}"
fi

if [ -z "${CACHET_API_TOKEN}" ] || [ "${CACHET_API_TOKEN}" == "YOUR_"* ]; then
    echo -e "${YELLOW}Warning: CACHET_API_TOKEN not set. Generate it from Cachet dashboard after setup.${NC}"
fi

if [ ${#MISSING_VARS[@]} -ne 0 ]; then
    echo -e "${RED}Error: Missing or invalid required environment variables:${NC}"
    for var in "${MISSING_VARS[@]}"; do
        echo -e "  - ${YELLOW}$var${NC}"
    done
    echo ""
    echo "Please edit .env file and set these variables"
    exit 1
fi

# Check if podman-compose is available
if ! command -v podman-compose &> /dev/null; then
    echo -e "${YELLOW}podman-compose not found. Installing...${NC}"
    pip3 install --user podman-compose
fi

# Create necessary directories
echo "Creating necessary directories..."
mkdir -p middleware/logs
mkdir -p cachet/storage/{app,framework,logs}
mkdir -p cachet/storage/framework/{sessions,views,cache}

# Set proper permissions
chmod -R 755 middleware/logs
chmod -R 755 cachet/storage

# Generate APP_KEY if not present in podman-setup/.env
echo ""
echo "Checking Laravel APP_KEY in .env..."
APP_KEY_VALUE=$(grep "^APP_KEY=" .env 2>/dev/null | cut -d= -f2 | tr -d '"')

if [ -z "$APP_KEY_VALUE" ] || [ "$APP_KEY_VALUE" = "" ]; then
    echo "Generating new Laravel APP_KEY..."
    RANDOM_KEY=$(openssl rand -base64 32)
    
    # Update podman-setup/.env (this will be passed to container as ENV var)
    if grep -q "^APP_KEY=" .env; then
        sed -i "s|^APP_KEY=.*|APP_KEY=\"base64:${RANDOM_KEY}\"|" .env
    else
        echo "APP_KEY=\"base64:${RANDOM_KEY}\"" >> .env
    fi
    
    echo -e "${GREEN}✓${NC} APP_KEY generated and saved to .env"
else
    echo -e "${GREEN}✓${NC} APP_KEY already exists in .env"
fi

# Ensure cachet/.env exists (used for default values not overridden by ENV vars)
echo ""
echo "Checking cachet/.env file..."
if [ ! -f cachet/.env ]; then
    echo -e "${YELLOW}Warning: cachet/.env not found, copying from cachet/.env.example${NC}"
    cp cachet/.env.example cachet/.env
    echo -e "${GREEN}✓${NC} cachet/.env created from example"
else
    echo -e "${GREEN}✓${NC} cachet/.env exists"
fi

# Configure webhook authentication in Traefik middlewares
echo ""
echo "Configuring webhook authentication..."
if [ -n "${WEBHOOK_USERNAME}" ] && [ -n "${WEBHOOK_PASSWORD}" ]; then
    # Check if htpasswd is available
    if ! command -v htpasswd &> /dev/null; then
        echo -e "${YELLOW}Warning: htpasswd not found. Installing apache2-utils...${NC}"
        sudo apt-get install -y apache2-utils || {
            echo -e "${RED}Error: Failed to install apache2-utils. Please install it manually.${NC}"
            exit 1
        }
    fi
    
    # Generate SHA hash for webhook credentials
    WEBHOOK_HASH=$(htpasswd -nbs "${WEBHOOK_USERNAME}" "${WEBHOOK_PASSWORD}")
    
    # Update middlewares.yml with the generated hash
    sed -i 's|.*WEBHOOK_CREDENTIALS_PLACEHOLDER.*|          - "'"${WEBHOOK_HASH}"'"|g' traefik/dynamic/middlewares.yml
    
    echo -e "${GREEN}✓${NC} Webhook authentication configured for user: ${WEBHOOK_USERNAME}"
else
    echo -e "${YELLOW}Warning: WEBHOOK_USERNAME or WEBHOOK_PASSWORD not set in .env${NC}"
fi

# Configure Traefik dashboard authentication in Traefik middlewares
echo ""
echo "Configuring Traefik dashboard authentication..."
if [ -n "${TRAEFIK_DASHBOARD_USERNAME}" ] && [ -n "${TRAEFIK_DASHBOARD_PASSWORD}" ]; then
    # Check if htpasswd is available
    if ! command -v htpasswd &> /dev/null; then
        echo -e "${YELLOW}Warning: htpasswd not found. Installing apache2-utils...${NC}"
        sudo apt-get install -y apache2-utils || {
            echo -e "${RED}Error: Failed to install apache2-utils. Please install it manually.${NC}"
            exit 1
        }
    fi
    # Generate SHA hash for dashboard credentials
    TRAEFIK_DASHBOARD_HASH=$(htpasswd -nbs "${TRAEFIK_DASHBOARD_USERNAME}" "${TRAEFIK_DASHBOARD_PASSWORD}")
    # Update middlewares.yml with the generated hash
    sed -i 's|.*TRAEFIK_DASHBOARD_CREDENTIALS_PLACEHOLDER.*|          - "'"${TRAEFIK_DASHBOARD_HASH}"'"|g' traefik/dynamic/middlewares.yml
    echo -e "${GREEN}✓${NC} Traefik dashboard authentication configured for user: ${TRAEFIK_DASHBOARD_USERNAME}"
else
    echo -e "${YELLOW}Warning: TRAEFIK_DASHBOARD_USERNAME or TRAEFIK_DASHBOARD_PASSWORD not set in .env${NC}"
fi

echo ""
echo "=========================================="
echo "Starting deployment..."
echo "=========================================="

# Build and start services
echo "Building images..."
podman-compose build

# Remove SSH directory from build context after build for security
if [ -d "$SSH_BUILD_CONTEXT" ]; then
    echo "Removing .ssh from build context after build..."
    rm -rf "$SSH_BUILD_CONTEXT"
fi

echo ""
echo "Starting core services (excluding middleware)..."
echo -e "${YELLOW}Note: Middleware will be started later after API token configuration${NC}"
podman-compose up -d --no-deps traefik postgres cachet

echo ""
echo "Waiting for database to be ready..."
sleep 10

# Run Cachet migrations and setup
echo ""
echo "Setting up Cachet database..."
podman-compose exec -T cachet php artisan migrate --force

echo ""
echo "Clearing and optimizing cache..."
podman-compose exec -T cachet php artisan optimize:clear
podman-compose exec -T cachet php artisan optimize

echo ""
echo "Fixing permissions (post-startup)..."
podman-compose exec -T cachet chown -R www-data:www-data /var/www/html/bootstrap/cache /var/www/html/storage
podman-compose exec -T cachet chmod -R 775 /var/www/html/bootstrap/cache /var/www/html/storage

# Fix Traefik acme.json permissions for Let's Encrypt when deploying with rootless Podman
echo ""
echo "Checking traefik-certs volume permissions..."
PROJECT_PREFIX=$(basename "$PWD" | tr -d '\n' | tr -c 'a-zA-Z0-9' '_')
PROJECT_PREFIX="${PROJECT_PREFIX%_}"
TRAEFIK_VOLUME_NAME="${PROJECT_PREFIX}_traefik-certs"

TRAEFIK_CERTS_PATH=""
if podman volume inspect "$TRAEFIK_VOLUME_NAME" &>/dev/null; then
    TRAEFIK_CERTS_PATH=$(podman volume inspect "$TRAEFIK_VOLUME_NAME" --format '{{ .Mountpoint }}')
    if [ -n "$TRAEFIK_CERTS_PATH" ]; then
        mkdir -p "$TRAEFIK_CERTS_PATH"
        # Fix permissions for acme.json if exists, else create it
        if [ ! -f "$TRAEFIK_CERTS_PATH/acme.json" ]; then
            touch "$TRAEFIK_CERTS_PATH/acme.json"
        fi
        chmod 600 "$TRAEFIK_CERTS_PATH/acme.json"
        # Change owner to current user if running rootless
        if [ "$EUID" -ne 0 ]; then
            chown $(id -u):$(id -g) "$TRAEFIK_CERTS_PATH/acme.json"
        fi
        echo -e "${GREEN}✓${NC} $TRAEFIK_VOLUME_NAME/acme.json permissions set (600, user: $(id -u))"
    fi
else
    echo -e "${RED}Error: $TRAEFIK_VOLUME_NAME volume not found!${NC}"
fi

echo ""
echo "=========================================="
echo "Deployment completed successfully!"
echo "=========================================="
echo ""
echo "Services are now running:"
echo -e "  ${GREEN}✓${NC} Traefik (Reverse Proxy)"
echo -e "  ${GREEN}✓${NC} PostgreSQL (Database)"
echo -e "  ${GREEN}✓${NC} Cachet (Status Page)"
echo -e "  ${YELLOW}⏸${NC} Middleware (will be started after API token configuration)"
echo ""
echo "Access URLs (${ENVIRONMENT:-local} environment):"
if [ "${ENVIRONMENT:-local}" == "local" ]; then
    echo "  - Cachet Status Page: http://localhost:${HTTP_PORT:-8080}"
    echo "  - Traefik Dashboard:  http://localhost:${HTTP_PORT:-9090}/traefik"
    echo "  - Webhook Endpoint:   http://localhost:${HTTP_PORT:-8080}/webhook"
else
    echo "  - Cachet Status Page: https://${CACHET_DOMAIN}"
    echo "  - Traefik Dashboard:  https://${CACHET_DOMAIN}:${DASHBOARD_PORT:-9090}/traefik"
    echo "  - Webhook Endpoint:   https://${WEBHOOK_DOMAIN}/webhook"
fi
echo ""
echo "=========================================="
echo "Next Steps:"
echo "=========================================="
echo ""
echo "Run the interactive setup script to complete the configuration:"
echo -e "  ${GREEN}./setup-cachet.sh${NC}"
echo ""
echo "This will guide you through:"
echo "  1. Creating admin user (php artisan cachet:make:user)"
echo "  2. Generating API token from Cachet dashboard"
echo "  3. Configuring middleware with the API token"
echo "  4. Initializing components from prometheus.yml"
echo "  5. Verifying webhook endpoint"
echo ""
