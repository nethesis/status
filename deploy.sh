#!/bin/bash
# Deployment script for Cachet infrastructure on Podman

set -e

echo "=========================================="
echo "Cachet Infrastructure Deployment"
echo "=========================================="

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
    echo -e "${RED}Warning: .env file not found${NC}"
    echo "Copy it from .env.example to .env"
    exit 1
fi

# Check if middleware/config.json exists
if [ ! -f middleware/config.json ]; then
    echo -e "${RED}Warning: middleware/config.json file not found${NC}"
    echo "Copy it from middleware/config.json.example to middleware/config.json"
    exit 1
fi


# Check if middleware/prometheus.yml exists
if [ ! -f middleware/prometheus.yml ]; then
    echo -e "${RED}Warning: middleware/prometheus.yml file not found${NC}"
    echo "Copy it from middleware/prometheus.yml.example to middleware/prometheus.yml"
    exit 1
fi

# Load environment variables
source .env

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
    echo -e "${YELLOW}podman-compose not found. ${NC}"
    exit 1
fi

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

# Ensure .env exists (used for default values not overridden by ENV vars)
echo ""
echo "Checking .env file..."
if [ ! -f .env ]; then
    echo -e "${RED}Warning: .env not found. Copy it from .env.example...${NC}"
    exit 1
else
    echo -e "${GREEN}✓${NC} .env exists"
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

echo ""
echo "=========================================="
echo "Starting deployment..."
echo "=========================================="


echo ""
echo "Starting core services (excluding middleware)..."
echo -e "${YELLOW}Note: Middleware will be started later after API token configuration${NC}"
podman-compose up -d --no-deps traefik postgres cachet

echo ""
echo "Waiting for database to be ready..."
sleep 10

# Run the AdminSeeder to create admin user and relative token for APIs
echo "Running AdminSeeder to create admin user and API token..."
adminseeder_output=$(podman-compose exec -T cachet php artisan db:seed --class=AdminSeeder --force 2>&1)
echo "--- AdminSeeder output ---"
echo "$adminseeder_output"
echo "-------------------------"
token=$(echo "$adminseeder_output" | grep -oP 'Generated Token: \K.*')

# Update the .env file with the generated token
if [ -n "$token" ]; then
    if grep -q "^CACHET_API_TOKEN=" .env; then
        # Token exists, update it (use # as delimiter to avoid conflicts with | in token)
        sed -i "s#^CACHET_API_TOKEN=.*#CACHET_API_TOKEN=\"${token}\"#g" .env
        echo "API token updated in .env file."
    else
        # Token doesn't exist, append it
        echo "CACHET_API_TOKEN=\"${token}\"" >> .env
        echo "API token added to .env file."
    fi
else
    echo "${RED}Error: Token not generated by AdminSeeder. Check the output above for details.${NC}"
    exit 1
fi


echo ""
echo "Clearing and optimizing cache..."
podman-compose exec -T cachet php artisan optimize:clear
podman-compose exec -T cachet php artisan optimize

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


# === Build and Start Middleware and Setup Components ===
echo ""
echo "=========================================="
echo "Starting Middleware, Initializing Components"
echo "=========================================="

fi

# Start middleware container
echo "Starting middleware container..."
podman-compose up -d middleware

# Wait for middleware to become healthy
echo "Waiting for middleware to become healthy..."
max_attempts=12
attempt=0
while [ $attempt -lt $max_attempts ]; do
    if podman ps --filter label=io.podman.compose.project=podman-setup --format "{{.Names}} {{.Status}}" | grep -q "cachet-middleware.*healthy"; then
        echo -e "${GREEN}✓${NC} Middleware is healthy"
        break
    fi
    attempt=$((attempt + 1))
    echo "  Attempt $attempt/$max_attempts..."
    sleep 5
done
if [ $attempt -eq $max_attempts ]; then
    echo -e "${YELLOW}⚠${NC} Middleware is running but healthcheck not confirmed"
    echo "You can check status with: podman ps --filter label=io.podman.compose.project=podman-setup"
    echo "If middleware keeps failing, check logs with: podman logs cachet-middleware"
fi

# Setup components (run setup.py) with user prompt
echo ""
echo "Initializing Cachet components from Prometheus configuration..."
if [ ! -f middleware/prometheus.yml ]; then
    echo -e "${RED}❌${NC} Prometheus configuration file not found: middleware/prometheus.yml"
    exit 1
fi
if [ ! -f middleware/config.json ]; then
    echo -e "${RED}❌${NC} Middleware configuration file not found: middleware/config.json"
    exit 1
fi
echo "Found configuration files:"
echo "  - Prometheus targets: middleware/prometheus.yml"
echo "  - Component groups: middleware/config.json"
target_count=$(grep -c "status_page_alert: true" middleware/prometheus.yml || echo "0")
echo "Found approximately ${target_count} targets with status_page_alert enabled"
echo ""
read -p "Do you want to run setup.py to create components? This will DELETE all existing components! (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Running setup.py inside middleware container..."
    if podman exec cachet-middleware python3 /app/setup.py --file /app/prometheus.yml; then
        echo -e "${GREEN}✓${NC} Components created successfully!"
    else
        echo -e "${RED}❌${NC} Failed to create components"
        echo "You can run setup.py manually with:"
        echo "  podman exec cachet-middleware python3 /app/setup.py --file /app/prometheus.yml"
        exit 1
    fi
else
    echo -e "${YELLOW}⚠${NC} Component setup skipped by user."
fi

# Verify webhook endpoint
echo ""
echo "Verifying webhook endpoint..."
webhook_url="http://localhost:${HTTP_PORT:-8080}/webhook"
response=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "${WEBHOOK_USERNAME}:${WEBHOOK_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{"test":"setup-verification"}' \
    "$webhook_url" 2>/dev/null || echo "000")
if [ "$response" = "200" ]; then
    echo -e "${GREEN}✓${NC} Webhook endpoint is working correctly!"
    echo "Credentials: ${WEBHOOK_USERNAME}:${WEBHOOK_PASSWORD}"
else
    echo -e "${YELLOW}⚠${NC} Webhook test returned HTTP $response"
    echo "This might be normal if middleware is still starting up"
    echo "You can test manually with:"
    echo "  curl -u '${WEBHOOK_USERNAME}:${WEBHOOK_PASSWORD}' -X POST $webhook_url"
fi

# Final summary
echo ""
echo "=========================================="
echo "SETUP COMPLETE! 🎉"
echo "=========================================="
echo "Your Cachet status page is now available!"
echo "  📊 Status Page:      ${APP_URL}"
echo "  🔧 Manager Login:    ${APP_URL}/dashboard/login"
echo "  📡 Webhook:          http://${APP_URL}/webhook"
echo ""
