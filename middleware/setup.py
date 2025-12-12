#!/usr/bin/env python3
"""
Script to configure CachetHQ by reading configuration from a Prometheus YAML file.
Creates component groups and components via Cachet API based on prometheus_targets labels.
"""

import json
import os
import sys
import requests
import yaml
import argparse
import time
from pathlib import Path
from dotenv import load_dotenv
from collections import OrderedDict


def load_prometheus_config(yaml_file):
    """Load configuration from Prometheus YAML file."""
    try:
        with open(yaml_file, 'r', encoding='utf-8') as f:
            return yaml.safe_load(f)
    except FileNotFoundError:
        print(f"❌ Error: File {yaml_file} not found")
        sys.exit(1)
    except yaml.YAMLError as e:
        print(f"❌ Error parsing YAML: {e}")
        sys.exit(1)

def load_groups_configuration(config_file='config.json'):
    """Load groups configuration from config.json file."""
    try:
        with open(config_file, 'r', encoding='utf-8') as f:
            config = json.load(f)
            groups_config = config.get('groups_configuration', [])
            # Create a map: component_name -> group_name
            component_to_group = {}
            for entry in groups_config:
                group = entry.get('status_page_group')
                components = entry.get('status_page_components', [])
                if group and components:
                    # Map each component in the array to its group
                    for component in components:
                        if component:
                            component_to_group[component] = group
            return component_to_group
    except FileNotFoundError:
        print(f"❌ Error: File {config_file} not found")
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"❌ Error parsing JSON: {e}")
        sys.exit(1)

def parse_targets_from_prometheus(prometheus_config, component_to_group_map):
    """
    Parse prometheus_targets section and extract target and component information.
    Returns:
    - invisible_components: list of target components (one per target)
    - visible_components_set: set of component names to create as visible components
    """
    invisible_components = []
    visible_components_set = set()
    
    if 'prometheus_targets' not in prometheus_config:
        print("⚠️  Warning: No 'prometheus_targets' section found in YAML file")
        return invisible_components, visible_components_set
    
    targets_section = prometheus_config['prometheus_targets']
    
    for job_name, job_targets in targets_section.items():
        if not isinstance(job_targets, list):
            continue
            
        for target_group in job_targets:
            if not isinstance(target_group, dict):
                continue
            
            # Extract targets
            targets = target_group.get('targets', [])
            labels = target_group.get('labels', {})
            
            # Check if status_page_alert exists and is true
            status_page_alert = labels.get('status_page_alert', False)
            if not status_page_alert:
                continue
            
            # Extract required label
            component_names_str = labels.get('status_page_component')
            
            # Extract critical target flag (default: False)
            is_critical = labels.get('status_page_critical_target', False)
            
            if not component_names_str:
                print(f"⚠️  Warning: Skipping target in job '{job_name}' - missing status_page_component")
                continue
            
            # Split component names by comma and strip whitespace
            component_names = [name.strip() for name in component_names_str.split(',')]
            
            # Add all components to visible components set
            for component_name in component_names:
                if component_name:
                    visible_components_set.add(component_name)
            
            # Create invisible component for each target
            for target in targets:
                invisible_component_name = f"{target} | {component_names_str}"
                invisible_components.append({
                    'name': invisible_component_name,
                    'target': target,
                    'component_names': component_names,  # List of component names
                    'component_names_str': component_names_str,  # Original string
                    'job': job_name,
                    'critical': is_critical
                })
    
    return invisible_components, visible_components_set

def format_group_name(group_slug):
    """
    Convert component_group slug to display name.
    Example: 'repositories_and_updates' -> 'Repositories And Updates'
    """
    words = group_slug.split('_')
    return ' '.join(word.capitalize() for word in words)

def delete_all_components(api_url, api_token):
    """Delete all components from CachetHQ with pagination support."""
    headers = {
        "Authorization": f"Bearer {api_token}",
        "Content-Type": "application/json"
    }
    
    try:
        print("🗑️  Fetching all components...")
        all_components = []
        page = 1
        per_page = 50
        
        # Fetch all components across all pages
        while True:
            url = f"{api_url}/components"
            params = {"per_page": per_page, "page": page}
            
            response = requests.get(url, headers=headers, params=params)
            response.raise_for_status()
            response_json = response.json()
            
            components = response_json.get('data', [])
            all_components.extend(components)
            
            # Check if there's a next page
            links = response_json.get("links", {})
            next_page = links.get("next")
            
            if not next_page:
                break
            
            page += 1
        
        if not all_components:
            print("✓ No components to delete")
            return
        
        print(f"🗑️  Deleting {len(all_components)} components...")
        for component in all_components:
            component_id = component['id']
            component_name = component.get('attributes', {}).get('name', 'Unknown')
            delete_url = f"{api_url}/components/{component_id}"
            
            try:
                del_response = requests.delete(delete_url, headers=headers)
                del_response.raise_for_status()
                print(f"✓ Deleted component: {component_name} (ID: {component_id})")
                time.sleep(1.5)  # Small delay between deletions
            except requests.exceptions.RequestException as e:
                print(f"❌ Error deleting component '{component_name}': {e}")
        
        print("✓ All components deleted")
    except requests.exceptions.RequestException as e:
        print(f"❌ Error fetching components: {e}")

def delete_all_component_groups(api_url, api_token):
    """Delete all component groups from CachetHQ with pagination support."""
    headers = {
        "Authorization": f"Bearer {api_token}",
        "Content-Type": "application/json"
    }
    
    try:
        print("🗑️  Fetching all component groups...")
        all_groups = []
        page = 1
        per_page = 50
        
        # Fetch all component groups across all pages
        while True:
            url = f"{api_url}/component-groups"
            params = {"per_page": per_page, "page": page}
            
            response = requests.get(url, headers=headers, params=params)
            response.raise_for_status()
            response_json = response.json()
            
            groups = response_json.get('data', [])
            all_groups.extend(groups)
            
            # Check if there's a next page
            links = response_json.get("links", {})
            next_page = links.get("next")
            
            if not next_page:
                break
            
            page += 1
        
        if not all_groups:
            print("✓ No component groups to delete")
            return
        
        print(f"🗑️  Deleting {len(all_groups)} component groups...")
        for group in all_groups:
            group_id = group['id']
            group_name = group.get('attributes', {}).get('name', 'Unknown')
            delete_url = f"{api_url}/component-groups/{group_id}"
            
            try:
                del_response = requests.delete(delete_url, headers=headers)
                del_response.raise_for_status()
                print(f"✓ Deleted component group: {group_name} (ID: {group_id})")
                time.sleep(0.5)  # Small delay between deletions
            except requests.exceptions.RequestException as e:
                print(f"❌ Error deleting group '{group_name}': {e}")
        
        print("✓ All component groups deleted")
    except requests.exceptions.RequestException as e:
        print(f"❌ Error fetching component groups: {e}")

def create_component_group(api_url, api_token, group_name):
    """Create a component group on CachetHQ."""
    url = f"{api_url}/component-groups"
    headers = {
        "Authorization": f"Bearer {api_token}",
        "Content-Type": "application/json"
    }
    
    payload = {
        "name": group_name,
        "visible": 1
    }
    
    try:
        response = requests.post(url, headers=headers, json=payload)
        response.raise_for_status()
        result = response.json()
        component_id = int(result['data']['id'])
        print(f"✓ Component Group created: {group_name} (ID: {component_id})")
        return component_id
    except requests.exceptions.RequestException as e:
        print(f"❌ Error creating group '{group_name}': {e}")
        if hasattr(e.response, 'text'):
            print(f"   Details: {e.response.text}")
        return None

def create_invisible_component(api_url, api_token, component_data):
    """Create an invisible component on CachetHQ (for individual targets)."""
    url = f"{api_url}/components"
    headers = {
        "Authorization": f"Bearer {api_token}",
        "Content-Type": "application/json"
    }
    
    # Build description with critical flag on first line, alerts on second line
    is_critical = component_data.get('critical', False)
    critical_text = "critical: yes" if is_critical else "critical: no"
    description = f"{critical_text}\nno alerts"
    
    payload = {
        "name": component_data["name"],
        "status": 1,
        "enabled": False,
        "description": description
    }
    
    try:
        response = requests.post(url, headers=headers, json=payload)
        response.raise_for_status()
        result = response.json()
        component_id = int(result['data']['id'])
        critical_indicator = " [CRITICAL]" if is_critical else ""
        print(f"✓ Invisible component created: {component_data['name']}{critical_indicator} (ID: {component_id})")
        return component_id
    except requests.exceptions.RequestException as e:
        print(f"❌ Error creating invisible component '{component_data['name']}': {e}")
        if hasattr(e.response, 'text'):
            print(f"   Details: {e.response.text}")
        return None

def create_visible_component(api_url, api_token, component_name, group_id):
    """Create a visible component on CachetHQ."""
    url = f"{api_url}/components"
    headers = {
        "Authorization": f"Bearer {api_token}",
        "Content-Type": "application/json"
    }
    
    payload = {
        "name": component_name,
        "status": 1,
        "enabled": True,
        "component_group_id": group_id
    }
    
    try:
        response = requests.post(url, headers=headers, json=payload)
        response.raise_for_status()
        result = response.json()
        component_id = int(result['data']['id'])
        print(f"✓ Visible component created: {component_name} (ID: {component_id})")
        return component_id
    except requests.exceptions.RequestException as e:
        print(f"❌ Error creating visible component '{component_name}': {e}")
        if hasattr(e.response, 'text'):
            print(f"   Details: {e.response.text}")
        return None

def main():
    # Parse command line arguments
    parser = argparse.ArgumentParser(
        description='Configure CachetHQ from Prometheus YAML configuration'
    )
    parser.add_argument(
        '--file',
        required=True,
        help='Path to Prometheus YAML configuration file'
    )
    parser.add_argument(
        '--just-delete',
        action='store_true',
        help='Only delete existing components and component groups, without creating new ones'
    )
    parser.add_argument(
        '--just-create',
        action='store_true',
        help='Only create components and component groups, without deleting existing ones'
    )
    args = parser.parse_args()
    
    yaml_file = args.file
    just_delete = args.just_delete
    just_create = args.just_create
    
    # Validate mutually exclusive options
    if just_delete and just_create:
        print("❌ Error: Cannot specify both --just-delete and --just-create")
        sys.exit(1)
    
    # Determine which phases to execute
    should_delete = just_delete or not just_create
    should_create = just_create or not just_delete
    
    # Validate file extension
    if not yaml_file.endswith('.yml') and not yaml_file.endswith('.yaml'):
        print("❌ Error: Input file must be a YAML file (.yml or .yaml)")
        sys.exit(1)
    
    # Check if file exists
    if not os.path.exists(yaml_file):
        print(f"❌ Error: File {yaml_file} not found")
        sys.exit(1)
    
    # Load environment variables
    load_dotenv()
    
    api_url = os.getenv("CACHET_API_URL")
    api_token = os.getenv("CACHET_API_TOKEN")
    
    if not api_url or not api_token:
        print("❌ Error: CACHET_API_URL and CACHET_API_TOKEN must be defined in .env file")
        sys.exit(1)
    
    print(f"\n🌐 Connecting to CachetHQ: {api_url}")
    print("=" * 60)
    
    # Phase 1: Delete existing components and component groups
    if should_delete:
        print("\n🧹 Cleaning up existing components and component groups...")
        delete_all_components(api_url, api_token)
        delete_all_component_groups(api_url, api_token)
        print("✓ Cleanup completed")
        
        if just_delete:
            print("\n" + "=" * 60)
            print("✅ Deletion completed!")
            return
    
    # Phase 2: Create new components and component groups
    if should_create:
        print(f"\n📖 Loading Prometheus configuration from: {yaml_file}")
        prometheus_config = load_prometheus_config(yaml_file)
        
        print("� Loading groups configuration from: config.json")
        component_to_group_map = load_groups_configuration('config.json')
        print(f"✓ Loaded {len(component_to_group_map)} component-to-group mappings")
        
        print("�🔍 Parsing prometheus_targets section...")
        invisible_components, visible_components_set = parse_targets_from_prometheus(prometheus_config, component_to_group_map)
        
        if not invisible_components and not visible_components_set:
            print("⚠️  No components found with status_page_alert=true")
            sys.exit(0)
        
        print(f"✓ Found {len(invisible_components)} targets to create as invisible components")
        print(f"✓ Found {len(visible_components_set)} unique visible components to create")
        
        # Create invisible components (one per target)
        print("\n👻 Creating Invisible Components (one per target)...")
        invisible_components_created = 0
        for component in invisible_components:
            component_id = create_invisible_component(api_url, api_token, component)
            if component_id:
                invisible_components_created += 1
            time.sleep(1.5)
        
        # Extract unique component groups from the mapping
        unique_groups = set()
        for component_name in visible_components_set:
            group_name = component_to_group_map.get(component_name)
            if group_name:
                unique_groups.add(group_name)
            else:
                print(f"⚠️  Warning: Component '{component_name}' has no group mapping in config.json")
        
        # Sort groups alphabetically
        unique_groups = sorted(unique_groups)
        
        print(f"\n✓ Found {len(unique_groups)} unique component groups")
        
        # Create component groups
        print("\n📦 Creating Component Groups...")
        group_id_mapping = {}
        for group_name in unique_groups:
            group_id = create_component_group(api_url, api_token, group_name)
            if group_id:
                group_id_mapping[group_name] = group_id
            time.sleep(1.5)
        
        # Create visible components
        print("\n🔧 Creating Visible Components...")
        visible_component_ids = {}
        for component_name in sorted(visible_components_set):
            group_name = component_to_group_map.get(component_name)
            
            if not group_name:
                print(f"⚠️  Skipping component '{component_name}' - no group mapping found")
                continue
            
            if group_name not in group_id_mapping:
                print(f"⚠️  Skipping component '{component_name}' - group '{group_name}' not created")
                continue
            
            group_id = group_id_mapping[group_name]
            component_id = create_visible_component(api_url, api_token, component_name, group_id)
            if component_id:
                visible_component_ids[component_name] = component_id
            time.sleep(1.5)
        
        print("\n" + "=" * 60)
        print("✅ Setup completed!")
        print(f"📊 Invisible components created: {invisible_components_created}")
        print(f"📊 Component Groups created: {len(group_id_mapping)}")
        print(f"📊 Visible components created: {len(visible_component_ids)}")

if __name__ == "__main__":
    main()
