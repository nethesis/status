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

1. **System Requirements**:
   - **Bash**: Ensure Bash is installed as the default shell.
   - **Podman**: Install Podman for container management.
   - **Podman-Compose**: Install Podman-Compose. Version must be greater than 1.0.6 as version 1.0.6 is outdated and contains bugs related to volume mounting.
   - **Python 3**: Ensure Python 3 and pip3 are installed.
   - **curl**: Required for testing webhook endpoints.
   - **htpasswd**: Installable via `apache2-utils`, used for HTTP authentication.
   - **openssl**: Required for generating random keys (e.g., `APP_KEY`).
   - **systemctl**: Required for managing the Podman rootless socket (systemd-based systems).
   - **sed**, **grep**, **awk**: Standard utilities for file and string manipulation.

## Manual Deployment Steps

Manual steps to deploy on **Fedora 42**:

- If the machines does not have enough RAM, create a swapfile:
  ```
  btrfs filesystem mkswapfile --size 2G /swap
  swapon  /swap
  ```

  Then add it to /etc/fstab:
  ```
  /swap  none  swap  defaults  0  0
  ```
- Install required packages:
  ```
  dnf install git podman-compose && dnf update
  ```
- Create a dedicated user for running the containers:
  ```
  useradd cachet -m -s /bin/bash
  loginctl enable-linger cachet
  echo 'net.ipv4.ip_unprivileged_port_start=80' > /etc/sysctl.d/99-podman.conf
  sysctl -p /etc/sysctl.d/99-podman.conf
  ```
- Switch to the new user and set up SSH keys for GitHub:
  ```
  sudo su - cachet
  mkdir -p ~/.ssh/authorized_keys
  curl https://github.com/<username>.keys >> .ssh/authorized_keys
  chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
  git clone git@github.com:nethesis/status.git
  cd status
  ```
  Follow the Quick Start instructions below from this point.

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

**Authentication:**
The webhook endpoint is protected by Basic Auth. You can configure the credentials by setting the `WEBHOOK_BASIC_AUTH` environment variable in `.env`.
The format is `user:hash`. You can generate the hash using `htpasswd -nb user password` or an online generator (BCrypt, MD5, SHA1).
If not set, the default credentials are `admin:admin`.

### 2. Configure Prometheus Targets

Copy the example configuration and edit with your infrastructure details:

```bash
cp middleware/prometheus.yml.example middleware/prometheus.yml
nano middleware/prometheus.yml
```

For a production deployment use prometheus config from [private repository](https://github.com/nethesis/metrics-deploy/blob/master/ansible/group_vars/all/prometheus.yml).


**Required Prometheus labels** for status page integration:

Your Prometheus targets configuration must include these custom labels:

- **`status_page_alert`** (required): Set to `true` to enable monitoring for this target
- **`status_page_component`** (required): Name(s) of visible component(s) affected by this target (comma-separated for multiple)
- **`status_page_critical_target`** (optional): Set to `true` to mark target as critical. When a critical target fails, the entire visible component is set to major outage regardless of other targets' status. Default: `false`

See `prometheus.yml.example` for usage examples.

**Important**: Make sure all component names used in `status_page_component` labels are also defined in the `groups_configuration` section of `middleware/config.json`.

### 3. Configure Component Groups

Copy the example configuration and edit to define your component groups:

```bash
cp middleware/config.json.example middleware/config.json
nano middleware/config.json
```

**Configuration parameters:**
- `status_page_group`: Name of the group that will be created on the status page
- `status_page_components`: Array of visible component names that belong to this group

Each visible component referenced in your Prometheus labels must be mapped to a group in this configuration. The `setup-components.py` script will use this mapping to automatically create groups and organize components during initialization.

### 4. Local Development Configuration

**⚠️ Important for Local Deployment:**

For local development (without HTTPS), ensure your `.env` is properly configured:
```bash
ENVIRONMENT=local
CACHET_DOMAIN=localhost
WEBHOOK_DOMAIN=localhost
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
