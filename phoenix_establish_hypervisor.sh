#!/bin/bash

# Phoenix Establish Hypervisor Script
# Orchestrates the execution of hypervisor setup and LXC creation/setup scripts in a defined order.
# Ensures idempotency using marker files to skip completed scripts.
# Usage: ./phoenix_establish_hypervisor.sh

# Source common functions and configuration
source /usr/local/bin/phoenix_hypervisor_common.sh || { echo "Error: Failed to source phoenix_hypervisor_common.sh" >&2; exit 1; }
source /usr/local/bin/phoenix_hypervisor_config.sh || { echo "Error: Failed to source phoenix_hypervisor_config.sh" >&2; exit 1; }

# Check if running as root
check_root

# Set up logging
load_hypervisor_config
export LOGFILE="$HYPERVISOR_LOGFILE"
setup_logging

log "INFO" "Starting phoenix_establish_hypervisor.sh"

# Create marker directory (centralized to avoid redundancy)
mkdir -p "$HYPERVISOR_MARKER_DIR" || { log "ERROR" "Failed to create marker directory: $HYPERVISOR_MARKER_DIR"; exit 1; }

# Define the order of scripts to execute
# Format: "script_path:marker_name" (e.g., "/usr/local/bin/script.sh:script_marker")
declare -A SCRIPTS_ORDER=(
    ["/usr/local/bin/phoenix_hypervisor_initial_setup.sh"]="initial_setup"
    ["/usr/local/bin/phoenix_hypervisor_create_lxc.sh"]="create_lxc"
)

# Track executed scripts and configured LXCs for summary
declare -a executed_scripts
declare -a configured_lxcs

# Execute each script in order
for script_path in "${!SCRIPTS_ORDER[@]}"; do
    marker_name="${SCRIPTS_ORDER[$script_path]}"
    marker_file="${HYPERVISOR_MARKER_DIR}/${marker_name}.marker"

    # Skip if the script has already completed (marker file exists)
    if is_script_completed "$marker_file"; then
        log "INFO" "Skipping completed script: $script_path"
        executed_scripts+=("$script_path (skipped)")
        continue
    fi

    # Ensure the script file exists and is executable
    if [[ ! -f "$script_path" ]]; then
        log "ERROR" "Script file not found: $script_path"
        exit 1
    fi

    if [[ ! -x "$script_path" ]]; then
        log "WARN" "Script not executable, attempting chmod +x: $script_path"
        chmod +x "$script_path" || { log "ERROR" "Failed to make script executable: $script_path"; exit 1; }
    fi

    # Execute the script
    log "INFO" "Executing: $script_path"
    if "$script_path"; then
        log "INFO" "Script succeeded: $script_path"
        mark_script_completed "$marker_file"
        executed_scripts+=("$script_path")
    else
        log "ERROR" "Script failed: $script_path (Exit code: $?)"
        exit 1
    fi
done

# Loop through LXC_CONFIGS and run their specific setup scripts
# LXC_SETUP_SCRIPTS format: Associative array mapping LXC ID to setup script path (e.g., [901]="/usr/local/bin/phoenix_lxc_setup_drdevstral.sh")
for lxc_id in "${!LXC_SETUP_SCRIPTS[@]}"; do
    setup_script="${LXC_SETUP_SCRIPTS[$lxc_id]}"
    marker_file="${HYPERVISOR_MARKER_DIR}/lxc_${lxc_id}_setup.marker"

    if is_script_completed "$marker_file"; then
        log "INFO" "Skipping completed LXC setup script for $lxc_id: $setup_script"
        configured_lxcs+=("$lxc_id (skipped)")
        continue
    fi

    # Ensure the setup script file exists and is executable
    if [[ ! -f "$setup_script" ]]; then
        log "ERROR" "LXC setup script file not found: $setup_script"
        exit 1
    fi

    if [[ ! -x "$setup_script" ]]; then
        log "WARN" "LXC setup script not executable, attempting chmod +x: $setup_script"
        chmod +x "$setup_script" || { log "ERROR" "Failed to make LXC setup script executable: $setup_script"; exit 1; }
    fi

    # Execute the setup script
    log "INFO" "Executing LXC setup script for $lxc_id: $setup_script"
    if "$setup_script" "$lxc_id"; then
        log "INFO" "LXC setup script succeeded: $setup_script"
        mark_script_completed "$marker_file"
        configured_lxcs+=("$lxc_id")
    else
        log "ERROR" "LXC setup script failed: $setup_script (Exit code: $?)"
        exit 1
    fi
done

# Output summary of executed scripts and configured LXCs
log "INFO" "Execution summary:"
log "INFO" "  Executed scripts: ${executed_scripts[*]:-None}"
log "INFO" "  Configured LXCs: ${configured_lxcs[*]:-None}"

log "INFO" "Completed phoenix_establish_hypervisor.sh successfully."