# Cachet Status Page - Podman Deployment

This project provides an automated deployment infrastructure for [CachetHQ](https://cachethq.io/) status page system using Podman containers, with integrated Prometheus AlertManager webhook middleware for automatic incident management.

All application sources and dependencies are prepared automatically by the deployment script; you do not need to manually clone or manage any application repositories except this one.

## What This Does

This infrastructure deploys a complete status page system consisting of:

- **Cachet Application**: Open-source status page system (Laravel-based)
- **PostgreSQL Database**: Data persistence layer
- **Traefik Reverse Proxy**: HTTP/HTTPS routing and SSL termination
- **AlertManager Webhook Middleware**: Python service that receives Prometheus alerts and automatically manages Cachet incidents and component statuses
- **Two-tier Component Architecture**: Invisible components (per-target monitoring) + visible components (aggregated service status)

The middleware handles alert lifecycle (firing/resolved) and intelligently updates component statuses and incidents based on alert state and target criticality.

---

## Prerequisites for Deployment

To deploy the infrastructure, ensure the following prerequisites are met:

1. **Configured SSH Key**:
   - The user must have an SSH key configured on their system.
   - The key must be authorized to access private repositories on GitHub.

2. **Add GitHub to known_hosts**:
   - Run the following command to add GitHub's fingerprint to the `known_hosts` file:
     ```bash
     ssh-keyscan github.com >> ~/.ssh/known_hosts
     ```
   - This command should be executed inside the user's `.ssh` directory.

3. **System Requirements**:
   - **Bash**: Ensure Bash is installed as the default shell.
   - **Podman**: Install Podman for container management.
   - **Podman-Compose**: Install Podman-Compose using the following commands to avoid issues with outdated versions:
     ```bash
     sudo curl -L https://raw.githubusercontent.com/containers/podman-compose/main/podman_compose.py -o /usr/local/bin/podman-compose
     sudo chmod +x /usr/local/bin/podman-compose
     ```
     > **Note**: The version available via `apt` (1.0.6) is outdated and contains bugs related to volume mounting.
   - **Python 3**: Ensure Python 3 and pip3 are installed.
   - **curl**: Required for testing webhook endpoints.
   - **htpasswd**: Installable via `apache2-utils`, used for HTTP authentication.
   - **openssl**: Required for generating random keys (e.g., `APP_KEY`).
   - **systemctl**: Required for managing the Podman rootless socket (systemd-based systems).
   - **sed**, **grep**, **awk**: Standard utilities for file and string manipulation.

By following these steps and ensuring the required tools are installed, you can successfully deploy the infrastructure and complete the setup process.

---

## Quick Start

### 1. Configure Environment

Copy the example environment file and edit with your values follow the inline instructions:

```bash
cp .env.example .env
nano .env
```

**Leave empty (auto-generated):**
- `APP_KEY`
- `CACHET_API_TOKEN`

> **Note for rootless Podman and privileged ports (80/443):**
> 
> By default, non-root users cannot bind to ports below 1024 (such as 80 and 443). If you want to expose Traefik or other services directly on these ports in rootless mode, you must configure the following kernel parameter on your host system:
> 
> ```bash
> sudo sysctl net.ipv4.ip_unprivileged_port_start=80
> ```
> 
> To make this change persistent after reboot, add this line to `/etc/sysctl.conf`:
> 
> ```
> net.ipv4.ip_unprivileged_port_start=80
> ```
> and apply with:
> 
> ```bash
> sudo sysctl -p
> ```
> 
> **Do not set this in any project file (.env, docker-compose.yml, etc): it must be configured at the OS level.**

### 2. Configure Prometheus Targets

Copy the example configuration and edit with your infrastructure details:

```bash
cp middleware/prometheus.yml.example middleware/prometheus.yml
nano middleware/prometheus.yml
```

### 3. Configure Component Groups

Copy the example configuration and edit to define your component groups:

```bash
cp middleware/config.json.example middleware/config.json
nano middleware/config.json
```

**Configure the `groups_configuration` section:**

```json
{
    "new_incident_name": "System %s is experiencing issues",
    "new_incident_message": "We are investigating an issue affecting this service.",
    "resolved_incident_message": "The issue has been resolved.",
    "cachet_per_page_param": 50,
    "groups_configuration": [
        {
            "status_page_group": "Web Services",
            "status_page_components": [
                "Web Server",
                "Load Balancer"
            ]
        },
        {
            "status_page_group": "Database Services",
            "status_page_components": [
                "Database",
                "Backend"
            ]
        }
    ]
}
```

**Configuration parameters:**
- `status_page_group`: Name of the group that will be created on the status page
- `status_page_components`: Array of visible component names that belong to this group

Each visible component referenced in your Prometheus labels must be mapped to a group in this configuration. The `setup.py` script will use this mapping to automatically create groups and organize components during initialization.

**Required Prometheus labels** for status page integration:

Your Prometheus targets configuration must include these custom labels:

```yaml
prometheus_targets:
  node_exporter:
    - targets:
        - '192.168.1.10:9100'
        - '192.168.1.11:9100'
      labels:
        status_page_alert: true                    # NEW: Enable status page monitoring
        status_page_component: 'Web Server'        # NEW: Visible component name(s)
        status_page_critical_target: false         # NEW: Mark as critical target (optional)
    
    - targets:
        - '192.168.1.20:9100'
      labels:
        status_page_alert: true
        status_page_component: 'Database, Backend' # Multiple components supported
        status_page_critical_target: true          # Critical target forces major outage
```

**New Label Definitions:**

- **`status_page_alert`** (required): Set to `true` to enable monitoring for this target
- **`status_page_component`** (required): Name(s) of visible component(s) affected by this target (comma-separated for multiple)
- **`status_page_critical_target`** (optional): Set to `true` to mark target as critical. When a critical target fails, the entire visible component is set to major outage regardless of other targets' status. Default: `false`

**Important**: Make sure all component names used in `status_page_component` labels are also defined in the `groups_configuration` section of `middleware/config.json`.

### 4. Configure Traefik Middlewares

Copy the middlewares configuration for webhook authentication:

```bash
cp traefik/dynamic/middlewares.yml.example traefik/dynamic/middlewares.yml
nano traefik/dynamic/middlewares.yml
```

**Note**: The `webhook-auth` section will be automatically configured by `deploy.sh` from your `.env` credentials.

### 5. Local Development Configuration

**⚠️ Important for Local Deployment:**

For local development (without HTTPS), ensure your `.env` is properly configured:
```bash
ENVIRONMENT=local
CACHET_DOMAIN=localhost
WEBHOOK_DOMAIN=localhost
TRAEFIK_DOMAIN=localhost
APP_ENV=local
APP_DEBUG=true
APP_URL=http://localhost:8080
ASSET_URL=http://localhost:8080
CERT_RESOLVER=
```

### 6. Deploy Infrastructure

Run the deployment script:

```bash
./deploy.sh
```

The script will automatically:
1. Validate configuration
2. Prepare all application sources and dependencies (no manual cloning required)
3. Generate the Laravel `APP_KEY` automatically
4. Configure webhook authentication
5. Build container images
6. Start Traefik, PostgreSQL, Cachet and Middleware services
7. Run database migrations
8. Create the admin user and generate the API token
9. Automatically set up components using Prometheus/config.json if requested
10. Verify the webhook endpoint

At the end of the process, the Cachet status page and middleware will be fully operational.

---

## Architecture Overview

### Component Hierarchy

The middleware implements a two-tier component architecture:

**Invisible Components** (one per monitored target):
- Name format: `<instance> | <component_names>`
- Example: `192.168.1.10:9100 | Web Server, Database`
- Status: Operational (1) or Major Outage (4)
- Purpose: Track individual target health

**Visible Components** (aggregated by service):
- Name: Service name (e.g., `Web Server`, `Database`)
- Status: Calculated by aggregating invisible component statuses
- Incident: Created/closed when status changes to/from Major Outage

### Status Calculation Logic

Visible component status is determined by:
1. **Major Outage (4)**: All invisible components down OR any critical target down
2. **Partial Outage (3)**: Mixed statuses (some up, some down) without critical targets down
3. **Operational (1)**: All invisible components operational

Critical targets (marked with `status_page_critical_target: true`) have priority: if any critical target fails, the entire visible component immediately goes to Major Outage.

---

## Logging and Monitoring

To monitor received webhook requests and component status changes from the middleware container, you can use the following commands:

### Webhook Request Logs

To view all requests received on the `/webhook` endpoint:

```
podman logs <container-name> 2>/dev/null | grep "\[WEBHOOK_REQUEST\]"
```

Example output:

```
[WEBHOOK_REQUEST] source_ip=10.0.0.5 headers=[Host: example.com; User-Agent: curl/7.68.0; Content-Type: application/json] body={...}
```

### Component Status Change Logs

To view all component status changes (both visible and invisible):

```
podman logs <container-name> 2>/dev/null | grep "\[COMPONENT_STATUS_CHANGE\]"
```

Example output:

```
[COMPONENT_STATUS_CHANGE] component="Database" old_status=1 (Operational) new_status=4 (Outage)
```

Replace `<container-name>` with the actual container name (e.g., `cachet-middleware`).

## Additional Documentation

- `middleware/README.md` - Detailed middleware architecture and API
- [Cachet Documentation](https://docs.cachethq.io)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Traefik Documentation](https://doc.traefik.io/traefik/)
