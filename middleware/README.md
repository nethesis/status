# Prometheus AlertManager to CachetHQ Middleware

Python Flask middleware that receives webhook notifications from Prometheus AlertManager and automatically manages incidents and component statuses in CachetHQ using a two-tier architecture: **invisible components** (for individual targets) and **visible components** (aggregated).

## Features

- **Automatic Incident Management**: Creates, updates, and resolves CachetHQ incidents based on Prometheus alerts
- **Two-Tier Architecture**: Invisible components (per target) + visible components (aggregated)
- **Multi-Alert Tracking**: Tracks multiple concurrent alerts per target via component description
- **Critical Targets**: Special logic for critical targets (force Major Outage on visible components)
- **Smart Status Calculation**: Calculates visible component status by aggregating invisible component statuses
- **Intelligent Incident Management**: Creates incidents only when visible component goes to Major Outage
- **YAML Configuration**: Automatic component setup from Prometheus file with `setup-components.py`

## Architecture

### Invisible Components

One for each monitored target:
- **Name**: `<instance> | <component_names>` (e.g., `192.168.1.10:9100 | Web Server, Database`)
- **Enabled**: `false` (invisible in status page)
- **Description**: Tracks active alerts and critical flag
  ```
  critical: yes
  InstanceDown,CPULoad,
  ```
- **Status**: 1 (operational) or 4 (major outage)

### Visible Components

Aggregated by service/function:
- **Name**: Service name (e.g., `Web Server`, `Database`)
- **Enabled**: `true` (visible in status page)
- **Status**: Calculated by aggregating invisible component statuses
  - **1 (Operational)**: All invisible components at status 1
  - **3 (Partial Outage)**: Mixed statuses (at least one at 4, no critical at 4)
  - **4 (Major Outage)**: All at status 4 OR at least one critical at status 4
- **Incident**: Created/closed when status changes to/from Major Outage

## How It Works

### Alert Management Flow

1. **Webhook Reception**: Receives POST from AlertManager at `/webhook`
2. **Alert Processing**: For each alert with `status_page_alert=true`:
   
   **A) Update Invisible Component:**
   - Identifies invisible component: `<instance> | <component_names>`
   - **Firing**: Adds alertname to description, status → 4
   - **Resolved**: Removes alertname from description, status → 1 if no alerts remaining
   
   **B) Update Visible Components:**
   - Parses `status_page_component` (can contain multiple components separated by comma)
   - For each visible component:
     - Retrieves ALL related invisible components
     - **Calculates new status** with critical logic:
       - If firing alert on critical target → status 4 (forced)
       - If at least one critical target at status 4 → status 4
       - If all at status 1 → status 1
       - If all at status 4 (but no critical) → status 4
       - Otherwise → status 2 (partial outage)
     - Updates visible component status
   
   **C) Incident Management:**
   - **Creates incident** if visible component goes to status 4 (from other status)
   - **Closes incident** if visible component returns to status 1 (from other status)
   - One incident per visible component (not one per alert!)

### Critical Targets Logic

Targets marked with `status_page_critical_target: true` have priority:
- When a firing alert hits a critical target → immediately forces status 4 on visible component
- If at least one critical target is at status 4 → visible component remains at status 4
- Only when all critical targets are operational → normal status is evaluated

**Example**:
- 3 web servers: 2 normal + 1 critical
- If critical goes down → visible component at status 4 (major outage)
- If only the 2 normal ones go down → visible component at status 2 (partial outage)