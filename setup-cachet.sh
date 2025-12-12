#!/bin/bash
# =============================================================================
# CACHET INITIAL SETUP SCRIPT
# =============================================================================
# This script guides you through the initial setup of Cachet after deployment:
# 1. Create admin user
# 2. Generate API token
# 3. Configure middleware with API token
# 4. Initialize components from Prometheus configuration
#
# Run this script AFTER deploying with deploy.sh and verifying all services are healthy.
# =============================================================================

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load environment variables
if [ ! -f .env ]; then
    echo -e "${RED}❌ Error: .env file not found${NC}"
    echo "Please copy .env.example to .env and configure it first"
    exit 1
fi

source .env

# Helper functions
print_step() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Check if services are running
check_services() {
    print_step "STEP 0: Checking Services Status"
    
    # Use podman ps directly instead of podman-compose ps (better output format)
    if ! podman ps --filter label=io.podman.compose.project=podman-setup --format "{{.Names}} {{.Status}}" | grep -q "cachet-app.*healthy"; then
        print_error "Cachet service is not running or not healthy"
        echo "Please run 'podman-compose ps' to check service status"
        echo ""
        print_info "Current status:"
        podman ps --filter label=io.podman.compose.project=podman-setup --format "table {{.Names}}\t{{.Status}}"
        exit 1
    fi
    
    print_success "Core services are running and healthy"
    print_info "Middleware will be started after API token configuration (STEP 3)"
}

# Step 1: Create admin user
create_admin_user() {
    print_step "STEP 1: Admin User Creation"
    
    echo "Do you need to create an admin user?"
    echo ""
    read -p "Have you already created an admin user? (y/n) " -n 1 -r
    echo
    echo ""
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_success "Skipping admin user creation (already exists)"
        return 0
    fi
    
    echo "Creating admin user with Cachet artisan command..."
    echo ""
    echo "You will be prompted to enter:"
    echo "  - Username (e.g., admin)"
    echo "  - Email address"
    echo "  - Password (minimum 6 characters)"
    echo ""
    
    # Run the interactive artisan command
    if podman-compose exec cachet php artisan cachet:make:user; then
        print_success "Admin user created successfully"
    else
        print_error "Failed to create admin user"
        echo ""
        print_info "You can create the user manually with:"
        echo "  podman-compose exec cachet php artisan cachet:make:user"
        exit 1
    fi
}

# Step 2: Generate API token
generate_api_token() {
    print_step "STEP 2: API Token Generation"
    
    echo "To generate an API token:"
    echo "  1. Login to Cachet dashboard: ${APP_URL}"
    echo "  2. Go to Settings → Manage API Keys"
    echo "  3. Click 'New API Key'"
    echo "  4. Give it a name (e.g., 'Middleware Integration')"
    echo "  5. Select abilities: 'components:read', 'components:write', 'incidents:read', 'incidents:write'"
    echo "  6. Click 'Create' and copy the generated token"
    echo ""
    
    read -p "Press Enter when you're ready to input the API token..."
    echo ""
    
    read -p "Paste the API token here: " api_token
    
    if [ -z "$api_token" ]; then
        print_error "API token cannot be empty"
        exit 1
    fi
    
    # Validate token format (should be like: 1|alphanumeric)
    if [[ ! $api_token =~ ^[0-9]+\|[a-zA-Z0-9]+$ ]]; then
        print_warning "Token format looks unusual. Expected format: 1|alphanumeric"
        read -p "Continue anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # Update .env file
    if grep -q "^CACHET_API_TOKEN=" .env; then
        # Token exists, update it (use # as delimiter to avoid conflicts with | in token)
        sed -i "s#^CACHET_API_TOKEN=.*#CACHET_API_TOKEN=\"${api_token}\"#g" .env
        print_success "API token updated in .env file"
    else
        # Token doesn't exist, append it
        echo "CACHET_API_TOKEN=\"${api_token}\"" >> .env
        print_success "API token added to .env file"
    fi
}

# Step 3: Start middleware with API token
restart_middleware() {
    print_step "STEP 3: Starting Middleware"
    
    # Check if middleware is already running
    if podman ps --filter label=io.podman.compose.project=podman-setup --format "{{.Names}}" | grep -q "cachet-middleware"; then
        echo "Middleware is already running. Recreating to apply new API token..."
        podman-compose up -d --force-recreate middleware
    else
        echo "Starting middleware for the first time with API token..."
        podman-compose up -d middleware
    fi
    
    if [ $? -eq 0 ]; then
        print_success "Middleware started successfully"
        
        # Wait for middleware to be healthy
        echo "Waiting for middleware to become healthy..."
        sleep 5
        
        local max_attempts=12
        local attempt=0
        
        while [ $attempt -lt $max_attempts ]; do
            if podman ps --filter label=io.podman.compose.project=podman-setup --format "{{.Names}} {{.Status}}" | grep -q "cachet-middleware.*healthy"; then
                print_success "Middleware is healthy"
                return 0
            fi
            
            attempt=$((attempt + 1))
            echo "  Attempt $attempt/$max_attempts..."
            sleep 5
        done
        
        print_warning "Middleware is running but healthcheck not confirmed"
        print_info "You can check status with: podman ps --filter label=io.podman.compose.project=podman-setup"
        print_info "If middleware keeps failing, check logs with: podman logs cachet-middleware"
    else
        print_error "Failed to start middleware"
        print_info "Check logs with: podman logs cachet-middleware"
        exit 1
    fi
}

# Step 4: Run setup.py to initialize components
setup_components() {
    print_step "STEP 4: Initialize Cachet Components"
    
    echo "This step will create component groups and components in Cachet"
    echo "based on your Prometheus configuration."
    echo ""
    
    # Check if prometheus.yml exists
    if [ ! -f middleware/prometheus.yml ]; then
        print_error "Prometheus configuration file not found: middleware/prometheus.yml"
        echo ""
        echo "Please ensure you have a prometheus.yml file with your targets configuration."
        exit 1
    fi
    
    # Check if config.json exists
    if [ ! -f middleware/config.json ]; then
        print_error "Middleware configuration file not found: middleware/config.json"
        exit 1
    fi
    
    print_info "Found configuration files:"
    echo "  - Prometheus targets: middleware/prometheus.yml"
    echo "  - Component groups: middleware/config.json"
    echo ""
    
    # Count targets with status_page_alert
    local target_count=$(grep -c "status_page_alert: true" middleware/prometheus.yml || echo "0")
    print_info "Found approximately ${target_count} targets with status_page_alert enabled"
    echo ""
    
    read -p "Run setup.py to create components? This will DELETE all existing components! (y/n) " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_warning "Component setup skipped"
        return 0
    fi
    
    echo ""
    print_info "Running setup.py..."
    echo ""
    
    # Run setup.py inside middleware container
    if podman exec cachet-middleware python3 /app/setup.py --file /app/prometheus.yml; then
        print_success "Components created successfully!"
        echo ""
        print_info "You can now view your components at: ${APP_URL}"
    else
        print_error "Failed to create components"
        print_info "You can run setup.py manually with:"
        echo "  podman exec cachet-middleware python3 /app/setup.py --file /app/prometheus.yml"
        exit 1
    fi
}

# Step 5: Verify webhook endpoint
verify_webhook() {
    print_step "STEP 5: Verify Webhook Endpoint"
    
    local webhook_url="http://localhost:${HTTP_PORT:-8080}/webhook"
    
    echo "Testing webhook endpoint with configured credentials..."
    echo ""
    
    # Test webhook with credentials from .env
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        -u "${WEBHOOK_USERNAME}:${WEBHOOK_PASSWORD}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d '{"test":"setup-verification"}' \
        "$webhook_url" 2>/dev/null || echo "000")
    
    if [ "$response" = "200" ]; then
        print_success "Webhook endpoint is working correctly!"
        print_info "Webhook URL: $webhook_url"
        print_info "Credentials: ${WEBHOOK_USERNAME}:${WEBHOOK_PASSWORD}"
    else
        print_warning "Webhook test returned HTTP $response"
        print_info "This might be normal if middleware is still starting up"
        print_info "You can test manually with:"
        echo "  curl -u '${WEBHOOK_USERNAME}:${WEBHOOK_PASSWORD}' -X POST $webhook_url"
    fi
}

# Final summary
print_summary() {
    print_step "SETUP COMPLETE! 🎉"
    
    echo "Your Cachet status page is now fully configured!"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}Access Points:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📊 Status Page:      ${APP_URL}"
    echo "  🔧 Status Page Manager Login:  ${APP_URL}/dashboard/login"
    echo "  📡 Webhook Endpoint: http://localhost:${HTTP_PORT:-8080}/webhook"
    echo "  📈 Traefik Dashboard: http://localhost:${DASHBOARD_PORT:-9090}/dashboard"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}Webhook Configuration (for Alertmanager):${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  URL:      http://localhost:${HTTP_PORT:-8080}/webhook"
    echo "  Username: ${WEBHOOK_USERNAME}"
    echo "  Password: ${WEBHOOK_PASSWORD}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}Useful Commands:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Check status:        podman-compose ps"
    echo "  View logs:           podman-compose logs -f [service]"
    echo "  Restart middleware:  podman-compose restart middleware"
    echo "  Re-run setup.py:     podman exec cachet-middleware python3 /app/setup.py --file /app/prometheus.yml"
    echo "  Healthcheck:         ./healthcheck.sh"
    echo ""
}

# Main execution
main() {
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║          CACHET STATUS PAGE - INITIAL SETUP               ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    check_services
    create_admin_user
    generate_api_token
    restart_middleware
    setup_components
    verify_webhook
    print_summary
}

# Run main function
main
