from flask import Flask, request
import requests
import logging
import json
import sys
import os
from dotenv import load_dotenv
import psutil
import signal
import atexit
import time
from datetime import datetime

# Load environment variables from .env file
load_dotenv()

# Memory monitoring variables
memory_samples = []
process = psutil.Process()

def record_memory():
    """Record current memory usage in MB."""
    memory_mb = process.memory_info().rss / 1024 / 1024
    memory_samples.append(memory_mb)

def print_memory_report():
    """Print memory usage report."""
    if not memory_samples:
        return
    
    max_memory = max(memory_samples)
    avg_memory = sum(memory_samples) / len(memory_samples)
    
    print("\n" + "="*50)
    print("MEMORY USAGE REPORT")
    print("="*50)
    print(f"Maximum RAM used: {max_memory:.2f} MB")
    print(f"Average RAM used: {avg_memory:.2f} MB")
    print(f"Total samples: {len(memory_samples)}")
    print("="*50 + "\n")
    
    logger.info(f"Maximum RAM used: {max_memory:.2f} MB")
    logger.info(f"Average RAM used: {avg_memory:.2f} MB")

app = Flask(__name__)

CACHET_API_URL = os.getenv("CACHET_API_URL")
CACHET_API_TOKEN = os.getenv("CACHET_API_TOKEN")

# Configure logging
# Console logger - all messages
console_handler = logging.StreamHandler()
console_handler.setLevel(logging.INFO)
console_formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
console_handler.setFormatter(console_formatter)



logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
logger.addHandler(console_handler)

if not CACHET_API_URL or not CACHET_API_TOKEN:
    logger.error("CACHET_API_URL and CACHET_API_TOKEN must be set in .env file")
    sys.exit(1)

# Register cleanup function to print report on exit
atexit.register(print_memory_report)

def signal_handler(sig, frame):
    """Handle termination signals (SIGINT, SIGTERM)."""
    logger.info("Received termination signal. Shutting down...")
    sys.exit(0)

# Register signal handlers
signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)

def load_config(file_path):
    """Load the configuration from an external JSON file."""
    try:
        with open(file_path, "r") as file:
            config = json.load(file)
            logger.info(f"Loaded configuration from {file_path}")
            return config
    except Exception as e:
        logger.error(f"Failed to load configuration from {file_path}: {e}")
        sys.exit(1)

# Get the directory where the script is located
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Define file paths relative to script directory
CONFIG_FILE = os.path.join(SCRIPT_DIR, "config.json")

# Load configuration files
CONFIG = load_config(CONFIG_FILE)

def _extract_status_value(status):
    if isinstance(status, dict):
        return status.get("value", 1)
    return status

def print_component_status_change(name, old_status, new_status):
    status_map = {1: "Operational", 3: "Partial Outage", 4: "Outage"}
    old_status_val = _extract_status_value(old_status)
    new_status_val = _extract_status_value(new_status)
    old_status_str = status_map.get(old_status_val, str(old_status_val))
    new_status_str = status_map.get(new_status_val, str(new_status_val))
    now = datetime.now().isoformat()
    print(f"[COMPONENT_STATUS_CHANGE] [{now}] component=\"{name}\" old_status={old_status_val} ({old_status_str}) new_status={new_status_val} ({new_status_str})")

def get_component_name(component_id):
    """Get the component name from CachetHQ API."""
    logger.info(f"Fetching component name for component ID: {component_id}")
    url = f"{CACHET_API_URL}/components/{component_id}"
    headers = {"Authorization": f"Bearer {CACHET_API_TOKEN}"}
    try:
        response = requests.get(url, headers=headers)
        response.raise_for_status()
        component_name = response.json()["data"]["attributes"]["name"]
        logger.info(f"Component name: {component_name}")
        return component_name
    except Exception as e:
        logger.error(f"Failed to fetch component name: {e}")
        return "Unknown Component"

def create_incident(component_id):
    """Create a new incident with message from configuration."""
    # Get component name from CachetHQ
    component_name = get_component_name(component_id)
    
    # Get incident name template from configuration
    incident_name_template = CONFIG.get("new_incident_name", "Nethesis %s System is experiencing issues")
    incident_name = incident_name_template % component_name
    
    incident_message = CONFIG.get("new_incident_message", "We are currently investigating this issue.")
    
    logger.info(f"Creating incident for component ID: {component_id}, name: {incident_name}")
    url = f"{CACHET_API_URL}/incidents"
    headers = {"Authorization": f"Bearer {CACHET_API_TOKEN}"}
    payload = {
        "name": incident_name,
        "message": incident_message,
        "status": 1,  # Status 1: Investigating
        "visible": 1,
        "component_id": component_id,
        "component_status": 4  # Major outage
    }
    response = requests.post(url, json=payload, headers=headers)
    response.raise_for_status()
    logger.info(f"Incident created with ID: {response.json()['data']['id']}")
    return response.json()["data"]["id"]

def resolve_incident(incident_id):
    logger.info(f"Resolving incident with ID: {incident_id}")
    url = f"{CACHET_API_URL}/incidents/{incident_id}"
    headers = {"Authorization": f"Bearer {CACHET_API_TOKEN}"}
    payload = {"status": 4}  # Resolved
    response = requests.put(url, json=payload, headers=headers)
    response.raise_for_status()
    logger.info(f"Incident resolved with ID: {incident_id}")

def create_incident_update(incident_id, message):
    logger.info(f"Creating update for incident ID: {incident_id}")
    """Create an update for an existing incident."""
    url = f"{CACHET_API_URL}/incidents/{incident_id}/updates"
    headers = {"Authorization": f"Bearer {CACHET_API_TOKEN}"}
    payload = {
        "status": 4,  # Resolved
        "message": message,
        "visible": 1
    }
    response = requests.post(url, json=payload, headers=headers)
    response.raise_for_status()
    logger.info(f"Update created for incident ID: {incident_id}")

def update_component_status(component_id, name, old_status, new_status):
    if old_status != new_status:
        print_component_status_change(name, old_status, new_status)
    logger.info(f"Updating component status for component '{name}' (ID: {component_id}) to status: {new_status}")
    url = f"{CACHET_API_URL}/components/{component_id}"
    headers = {"Authorization": f"Bearer {CACHET_API_TOKEN}"}
    payload = {"status": new_status}
    response = requests.patch(url, json=payload, headers=headers)
    response.raise_for_status()
    logger.info(f"Component status updated for component '{name}' (ID: {component_id})")

def get_component_id_by_name(component_name):
    """Get component ID by name from CachetHQ API with pagination support."""
    logger.info(f"Looking for component with name: {component_name}")
    headers = {"Authorization": f"Bearer {CACHET_API_TOKEN}"}
    
    try:
        page = 1
        per_page = CONFIG.get("cachet_per_page_param", 50)
        
        while True:
            url = f"{CACHET_API_URL}/components"
            params = {"per_page": per_page, "page": page}
            
            logger.info(f"Fetching components page {page}")
            response = requests.get(url, headers=headers, params=params)
            response.raise_for_status()
            response_json = response.json()
            
            components = response_json.get("data", [])
            
            # Search for the component in current page
            for component in components:
                attributes = component.get("attributes", {})
                name = attributes.get("name")
                
                if name == component_name:
                    comp_id = int(component.get("id"))
                    logger.info(f"Component '{component_name}' found with ID: {comp_id}")
                    return comp_id
            
            # Check if there's a next page
            links = response_json.get("links", {})
            next_page = links.get("next")
            
            if not next_page:
                # No more pages, component not found
                logger.error(f"Component '{component_name}' not found in CachetHQ")
                return None
            
            # Move to next page
            page += 1
        
    except Exception as e:
        logger.error(f"Failed to fetch components: {e}")
        return None

def get_component_by_id(component_id):
    """Get component details by ID from CachetHQ API."""
    logger.info(f"Fetching component details for ID: {component_id}")
    url = f"{CACHET_API_URL}/components/{component_id}"
    headers = {"Authorization": f"Bearer {CACHET_API_TOKEN}"}
    try:
        response = requests.get(url, headers=headers)
        response.raise_for_status()
        return response.json()["data"]["attributes"]
    except Exception as e:
        logger.error(f"Failed to fetch component {component_id}: {e}")
        return None

def get_all_invisible_components_for_visible(visible_component_name):
    """
    Get all invisible components that contain the visible component name in their component list.
    The component name should appear in the part after '|' in the invisible component name.
    Example: 'db.example.com:9100 | Component A, Component B' matches both 'Component A' and 'Component B'
    """
    logger.info(f"Fetching all invisible components for visible component: {visible_component_name}")
    headers = {"Authorization": f"Bearer {CACHET_API_TOKEN}"}
    invisible_components = []
    
    try:
        page = 1
        per_page = CONFIG.get("cachet_per_page_param", 50)
        
        while True:
            url = f"{CACHET_API_URL}/components"
            params = {"per_page": per_page, "page": page}
            
            response = requests.get(url, headers=headers, params=params)
            response.raise_for_status()
            response_json = response.json()
            
            components = response_json.get("data", [])
            
            for component in components:
                attributes = component.get("attributes", {})
                name = attributes.get("name", "")
                enabled = attributes.get("enabled", True)
                
                # Check if component is invisible
                if not enabled and '|' in name:
                    # Extract the component list part (after '|')
                    parts = name.split('|', 1)
                    if len(parts) == 2:
                        component_list_str = parts[1].strip()
                        # Split by comma and check if visible_component_name is in the list
                        component_list = [c.strip() for c in component_list_str.split(',')]
                        
                        if visible_component_name in component_list:
                            status_obj = attributes.get("status")
                            # Extract integer value from status (can be int or dict)
                            if isinstance(status_obj, dict):
                                status_value = status_obj.get("value", 1)
                            else:
                                status_value = status_obj
                            
                            invisible_components.append({
                                "id": int(component.get("id")),
                                "name": name,
                                "status": status_value,
                                "description": attributes.get("description", "")
                            })
            
            links = response_json.get("links", {})
            next_page = links.get("next")
            
            if not next_page:
                break
            
            page += 1
        
        logger.info(f"Found {len(invisible_components)} invisible components for '{visible_component_name}'")
        return invisible_components
        
    except Exception as e:
        logger.error(f"Failed to fetch invisible components: {e}")
        return []

def add_alert_to_description(description, alertname):
    """Add alert name to description preserving the critical flag."""
    # Split description into critical flag (first line) and alerts (second line)
    lines = description.split('\n', 1)
    
    if len(lines) < 2:
        # Malformed description, treat as legacy format
        critical_line = "critical: no"
        alerts_line = description if description != "no alerts" else "no alerts"
    else:
        critical_line = lines[0]  # e.g., "critical: yes"
        alerts_line = lines[1]    # e.g., "no alerts" or "InstanceDown,"
    
    # Process alerts
    if alerts_line == "no alerts":
        new_alerts_line = f"{alertname},"
    else:
        # Check if alert already exists
        alerts = [a.strip() for a in alerts_line.split(',') if a.strip()]
        if alertname not in alerts:
            alerts.append(alertname)
        new_alerts_line = ','.join(alerts) + ','
    
    # Reconstruct description with critical flag on first line
    return f"{critical_line}\n{new_alerts_line}"

def remove_alert_from_description(description, alertname):
    """Remove alert name from description preserving the critical flag."""
    # Split description into critical flag (first line) and alerts (second line)
    lines = description.split('\n', 1)
    
    if len(lines) < 2:
        # Malformed description, treat as legacy format
        critical_line = "critical: no"
        alerts_line = description if description != "no alerts" else "no alerts"
    else:
        critical_line = lines[0]  # e.g., "critical: yes"
        alerts_line = lines[1]    # e.g., "InstanceDown,CPULoad,"
    
    # Process alerts
    if alerts_line == "no alerts":
        new_alerts_line = "no alerts"
    else:
        alerts = [a.strip() for a in alerts_line.split(',') if a.strip()]
        if alertname in alerts:
            alerts.remove(alertname)
        
        if len(alerts) == 0:
            new_alerts_line = "no alerts"
        else:
            new_alerts_line = ','.join(alerts) + ','
    
    # Reconstruct description with critical flag on first line
    return f"{critical_line}\n{new_alerts_line}"

def update_invisible_component(component_id, name, old_status, new_status, description):
    if old_status != new_status:
        print_component_status_change(name, old_status, new_status)
    logger.info(f"Updating invisible component '{name}' (ID: {component_id}): status={new_status}, description={description}")
    url = f"{CACHET_API_URL}/components/{component_id}"
    headers = {"Authorization": f"Bearer {CACHET_API_TOKEN}"}
    payload = {
        "status": new_status,
        "enabled": False,
        "description": description
    }
    try:
        response = requests.put(url, json=payload, headers=headers)
        response.raise_for_status()
        logger.info(f"Invisible component '{name}' (ID: {component_id}) updated successfully")
    except Exception as e:
        logger.error(f"Failed to update invisible component '{name}' (ID: {component_id}): {e}")

def extract_critical_from_description(description):
    """
    Extract critical flag from component description.
    Returns True if 'critical: yes', False otherwise.
    """
    lines = description.split('\n', 1)
    if len(lines) < 1:
        return False
    
    critical_line = lines[0].strip()
    return critical_line == "critical: yes"

def calculate_visible_component_status(invisible_components, current_component_is_critical=False, current_alert_status=""):
    """
    Calculate visible component status based on invisible components statuses.
    
    Special logic for critical components:
    - If current alert is firing on a critical component → force status 4
    - If there's at least one critical component at status 4 → status 4
    - Otherwise, standard logic applies
    
    Returns: 1 (operational), 3 (partial outage), or 4 (major outage)
    """
    if not invisible_components:
        return 1
    
    # CRITICAL COMPONENT FIRING: Force major outage immediately
    if current_component_is_critical and current_alert_status == "firing":
        logger.info("Critical component alert firing → forcing visible component to Major Outage (4)")
        return 4
    
    statuses = [comp["status"] for comp in invisible_components]
    
    # All operational
    if all(s == 1 for s in statuses):
        return 1
    
    # Check if there's at least one critical component at status 4
    critical_components_down = []
    for comp in invisible_components:
        if comp["status"] == 4:
            is_critical = extract_critical_from_description(comp.get("description", ""))
            if is_critical:
                critical_components_down.append(comp["name"])
    
    # At least one critical component is down → Major outage
    if critical_components_down:
        logger.info(f"Critical components down: {', '.join(critical_components_down)} → forcing Major Outage (4)")
        return 4
    
    # All at status 4 (but none critical)
    if all(s == 4 for s in statuses):
        return 4
    
    # Mixed status
    return 3

def get_open_incident(component_id):
    """Fetch the open incident for a given component_id from CachetHQ."""
    logger.info(f"Fetching open incident for component_id: {component_id}")

    url = f"{CACHET_API_URL}/incidents"
    headers = {"Authorization": f"Bearer {CACHET_API_TOKEN}"}
    params = {"filter[status]": "0,1,2,3"}  # All open statuses
    response = requests.get(url, headers=headers, params=params)
    response.raise_for_status()
    incidents = response.json().get("data", [])
    
    # Filter incidents manually by component_id in attributes
    for incident in incidents:
        attributes = incident.get("attributes", {})
        if attributes.get("component_id") == component_id:
            incident_id = incident["id"]
            logger.info(f"Open incident found for component_id: {component_id}, ID: {incident_id}")
            return incident_id
    
    logger.info(f"No open incident found for component_id: {component_id}")
    return None

def log_request_details(req):
    """Log request details in a single line on stdout with a fixed label for easy grep."""
    source_ip = req.remote_addr
    try:
        body_json = req.get_json()
        body_str = json.dumps(body_json, separators=(",", ":"), ensure_ascii=False)
    except Exception as e:
        body_str = f"Failed to parse JSON: {e}; Raw: {req.data.decode('utf-8', errors='ignore')}"
    headers_str = "; ".join([f"{k}: {v}" for k, v in req.headers])
    # Compose single line log
    now = datetime.now().isoformat()
    log_line = (
        f"[WEBHOOK_REQUEST] [{now}] source_ip={source_ip} "
        f"headers=[{headers_str}] "
        f"body={body_str}"
    )
    print(log_line)

def sort_alerts_for_processing(alerts):
    """
    Sort alerts for processing:
    - First, all 'resolved' alerts, ordered by endsAt (oldest first)
    - Then, all 'firing' alerts, ordered by startsAt (oldest first)
    - Alerts with unknown status are left at the end, in original order
    """
    def parse_time(s):
        try:
            return datetime.fromisoformat(s.replace('Z', '+00:00'))
        except Exception:
            return datetime.max

    resolved = [a for a in alerts if a.get('status') == 'resolved']
    firing = [a for a in alerts if a.get('status') == 'firing']
    other = [a for a in alerts if a.get('status') not in ('resolved', 'firing')]

    resolved_sorted = sorted(resolved, key=lambda a: parse_time(a.get('endsAt', '9999-12-31T23:59:59Z')))
    firing_sorted = sorted(firing, key=lambda a: parse_time(a.get('startsAt', '9999-12-31T23:59:59Z')))

    return resolved_sorted + firing_sorted + other

@app.route("/health", methods=["GET"])
def health():
    """Health check endpoint for container orchestration and load balancers."""
    return {"status": "healthy", "service": "cachet-webhook-middleware"}, 200

@app.route("/webhook", methods=["POST"])
def webhook():
    logger.info("Received a webhook request.")
    log_request_details(request)
    record_memory()
    data = request.json
    
    alerts = data.get("alerts", [])
    if len(alerts) > 1:
        alerts = sort_alerts_for_processing(alerts)
        logger.info(f"Sorted {len(alerts)} alerts for processing order.")
    for alert in alerts:
        labels = alert.get("labels", {})
        instance = labels.get("instance")
        alertname = labels.get("alertname")
        status_page_component = labels.get("status_page_component")
        status_page_alert = labels.get("status_page_alert")
        status = alert["status"]
        
        logger.info(f"Processing alert in state '{status}' with startsAt: {alert.get('startsAt')} and endsAt: {alert.get('endsAt')}")
        
        if not status_page_alert:
            logger.info(f"Alert '{alertname}' for instance '{instance}' has status_page_alert != true. Ignoring.")
            continue
        
        if not instance or not alertname or not status_page_component:
            logger.warning(f"Alert missing required labels (instance, alertname, status_page_component). Ignoring.")
            continue
        
        logger.info(f"Processing alert '{alertname}' for instance '{instance}', status: {status}")
        
        # Build invisible component name
        invisible_component_name = f"{instance} | {status_page_component}"
        
        # Get invisible component ID
        invisible_component_id = get_component_id_by_name(invisible_component_name)
        
        if not invisible_component_id:
            logger.error(f"Invisible component '{invisible_component_name}' not found. Skipping alert.")
            continue
        
        # Get current invisible component details
        invisible_component = get_component_by_id(invisible_component_id)
        if not invisible_component:
            logger.error(f"Could not fetch details for invisible component {invisible_component_id}")
            continue
        
        current_description = invisible_component.get("description", "critical: no\nno alerts")
        
        # Extract critical flag from current component
        is_current_component_critical = extract_critical_from_description(current_description)
        logger.info(f"Component '{invisible_component_name}' critical flag: {'YES' if is_current_component_critical else 'NO'}")
        
        # Update invisible component based on alert status
        old_invisible_status = invisible_component.get("status", 1)
        invisible_name = invisible_component.get("name", f"ID:{invisible_component_id}")
        if status == "firing":
            new_description = add_alert_to_description(current_description, alertname)
            update_invisible_component(invisible_component_id, invisible_name, old_invisible_status, 4, new_description)
        elif status == "resolved":
            new_description = remove_alert_from_description(current_description, alertname)
            # Check if there are still alerts (second line after \n)
            alerts_line = new_description.split('\n', 1)[1] if '\n' in new_description else "no alerts"
            new_status = 1 if alerts_line == "no alerts" else 4
            update_invisible_component(invisible_component_id, invisible_name, old_invisible_status, new_status, new_description)
        
        # Parse multiple visible components from status_page_component label
        visible_component_names = [name.strip() for name in status_page_component.split(',')]
        logger.info(f"Processing {len(visible_component_names)} visible component(s): {', '.join(visible_component_names)}")
        
        # Process each visible component
        for visible_component_name in visible_component_names:
            if not visible_component_name:
                continue
            
            logger.info(f"Processing visible component: {visible_component_name}")
            
            # Get visible component ID
            visible_component_id = get_component_id_by_name(visible_component_name)
            
            if not visible_component_id:
                logger.error(f"Visible component '{visible_component_name}' not found. Skipping incident management for this component.")
                continue
            
            # Get all invisible components for this visible component
            time.sleep(0.5)  # Wait for CachetHQ to process the update
            all_invisible_components = get_all_invisible_components_for_visible(visible_component_name)
            
            if all_invisible_components:
                # Log with critical indicator
                invisible_details = []
                for comp in all_invisible_components:
                    is_crit = extract_critical_from_description(comp.get("description", ""))
                    crit_mark = " [CRIT]" if is_crit else ""
                    invisible_details.append(f"{comp['name']} (status={comp['status']}{crit_mark})")
                logger.info(f"Invisible components related to '{visible_component_name}': {', '.join(invisible_details)}")
            else:
                logger.warning(f"No invisible components found for visible component '{visible_component_name}'")
                continue
            
            # Calculate new visible component status with critical logic
            new_visible_status = calculate_visible_component_status(
                all_invisible_components, 
                is_current_component_critical, 
                status
            )
            current_visible_component = get_component_by_id(visible_component_id)
            old_visible_status = current_visible_component.get("status") if current_visible_component else 1
            visible_name = current_visible_component.get("name", visible_component_name) if current_visible_component else visible_component_name
            logger.info(f"Visible component '{visible_name}' status change: {old_visible_status} -> {new_visible_status}")

            # Update visible component status
            update_component_status(visible_component_id, visible_name, old_visible_status, new_visible_status)
            
            # Incident management based on component status transitions
            if status == "firing" and new_visible_status == 4 and old_visible_status != 4:
                # Component just went to major outage, create incident
                incident_id = get_open_incident(visible_component_id)
                if not incident_id:
                    logger.info(f"Creating new incident for component: {visible_component_name}")
                    create_incident(visible_component_id)
                else:
                    logger.info(f"Incident {incident_id} already exists for component: {visible_component_name}")
            
            elif status == "resolved" and new_visible_status == 1 and old_visible_status != 1:
                # Component fully recovered, close incident
                incident_id = get_open_incident(visible_component_id)
                if incident_id:
                    logger.info(f"Closing incident {incident_id} for component: {visible_component_name}")
                    create_incident_update(incident_id, CONFIG.get("resolved_incident_message", "The issue has been resolved."))
                    resolve_incident(incident_id)
                else:
                    logger.info(f"No open incident found for component: {visible_component_name}")
    
    logger.info("Webhook processing completed.")
    return "OK", 200

if __name__ == "__main__":
    app.run(port=5000)
