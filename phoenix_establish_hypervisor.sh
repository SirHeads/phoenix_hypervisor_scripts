#!/bin/bash
# Phoenix Hypervisor Establish Script
# Main entry point for setting up the Phoenix Hypervisor.
# Orchestrates initial setup, LXC creation, and LXC-specific setup scripts using JSON config.
# Prompts for LXC root password and ensures prerequisites are met.
# Prerequisites:
# - Proxmox VE 8.x (tested with 8.4.6)
# - phoenix_hypervisor_common.sh and phoenix_hypervisor_config.sh sourced
# - /usr/local/etc/phoenix_lxc_configs.json configured
# Usage: ./phoenix_establish_hypervisor.sh
# Version: 1.6.9 (Removed hardcoded defaults, added password passing, enhanced debugging)

set -euo pipefail

# Source common functions and configuration
source /usr/local/bin/phoenix_hypervisor_common.sh || { echo "Error: Failed to source phoenix_hypervisor_common.sh" >&2; exit 1; }
source /usr/local/bin/phoenix_hypervisor_config.sh || { echo "Error: Failed to source phoenix_hypervisor_config.sh" >&2; exit 1; }

# Check root privileges
check_root

# Set up logging
load_hypervisor_config
export LOGFILE="$HYPERVISOR_LOGFILE"
setup_logging

log "INFO" "$0: Starting phoenix_establish_hypervisor.sh"

# --- Prompt for LXC root password ---
prompt_for_lxc_root_password() {
    local passwd_file="/root/.phoenix_lxc_root_passwd"
    local password_input
    local password_confirm
    local attempts=0
    local max_attempts=3

    log "DEBUG" "$0: Checking for LXC root password"
    if [[ -f "$passwd_file" ]]; then
        log "INFO" "$0: LXC root password file exists: $passwd_file"
        export LXC_ROOT_PASSWORD=$(cat "$passwd_file" | base64 -d 2>/dev/null)
        return 0
    fi

    log "INFO" "$0: Prompting for LXC root password..."
    while [[ $attempts -lt $max_attempts ]]; do
        read -s -p "Enter LXC root password: " password_input
        echo # Newline
        if [[ -z "$password_input" ]]; then
            ((attempts++))
            log "WARN" "$0: Password cannot be empty. Attempt $attempts/$max_attempts."
            continue
        fi

        read -s -p "Confirm password: " password_confirm
        echo # Newline
        if [[ "$password_input" != "$password_confirm" ]]; then
            ((attempts++))
            log "WARN" "$0: Passwords do not match. Attempt $attempts/$max_attempts."
            continue
        fi

        log "INFO" "$0: Password confirmed"
        echo -n "$password_input" | base64 > "$passwd_file" || { log "ERROR" "$0: Failed to save password to $passwd_file"; exit 1; }
        chmod 600 "$passwd_file" || { log "WARN" "$0: Failed to set permissions on $passwd_file"; }
        export LXC_ROOT_PASSWORD="$password_input"
        log "INFO" "$0: LXC root password saved to $passwd_file"
        return 0
    done

    log "ERROR" "$0: Maximum password attempts ($max_attempts) reached"
    exit 1
}

# --- Main execution ---
MARKER_FILE="${HYPERVISOR_MARKER_DIR}/establish_hypervisor.marker"
if is_script_completed "$MARKER_FILE"; then
    log "INFO" "$0: Phoenix Hypervisor setup already completed. Skipping."
    exit 0
fi

# Re-validate JSON config
validate_json_config "$PHOENIX_LXC_CONFIG_FILE"

# Ensure Hugging Face token
prompt_for_hf_token

# Validate LXC_CONFIGS and LXC_SETUP_SCRIPTS
if [[ ${#LXC_CONFIGS[@]} -eq 0 ]]; then
    log "ERROR" "$0: No LXC configurations found in $PHOENIX_LXC_CONFIG_FILE"
    exit 1
fi

log "DEBUG" "$0: Processing LXC IDs: ${!LXC_CONFIGS[*]}"
for lxc_id in "${!LXC_CONFIGS[@]}"; do
    if [[ -z "${LXC_SETUP_SCRIPTS[$lxc_id]}" ]]; then
        log "ERROR" "$0: No setup script defined for LXC $lxc_id in LXC_SETUP_SCRIPTS"
        exit 1
    fi
    local setup_script="${LXC_SETUP_SCRIPTS[$lxc_id]}"
    if [[ ! -x "$setup_script" ]]; then
        log "ERROR" "$0: Setup script for LXC $lxc_id is not executable: $setup_script"
        exit 1
    fi
    log "DEBUG" "$0: Valid setup script for LXC $lxc_id: $setup_script"
done

# Prompt for LXC root password
prompt_for_lxc_root_password

# Run initial setup
log "INFO" "$0: Running initial setup..."
if ! output=$(/usr/local/bin/phoenix_hypervisor_initial_setup.sh 2>&1); then
    log "ERROR" "$0: Initial setup failed"
    log "DEBUG" "$0: Initial setup output: $output"
    exit 1
fi
log "DEBUG" "$0: Initial setup output: $output"
log "INFO" "$0: Initial setup completed"

# Create LXC containers
log "INFO" "$0: Creating LXC containers..."
if ! output=$(/usr/local/bin/phoenix_hypervisor_create_lxc.sh 2>&1); then
    log "ERROR" "$0: LXC creation failed"
    log "DEBUG" "$0: LXC creation output: $output"
    exit 1
fi
log "DEBUG" "$0: LXC creation output: $output"
log "INFO" "$0: LXC creation completed"

# Run LXC-specific setup scripts
log "INFO" "$0: Running LXC-specific setup scripts..."
for lxc_id in "${!LXC_CONFIGS[@]}"; do
    local setup_script="${LXC_SETUP_SCRIPTS[$lxc_id]}"
    log "INFO" "$0: Running setup script for LXC $lxc_id: $setup_script"
    if ! output=$("$setup_script" "$lxc_id" 2>&1); then
        log "ERROR" "$0: Setup script failed for LXC $lxc_id: $setup_script"
        log "DEBUG" "$0: Setup script output: $output"
        exit 1
    fi
    log "DEBUG" "$0: Setup script output for LXC $lxc_id: $output"
    log "INFO" "$0: Setup completed for LXC $lxc_id"
done

# Mark setup as complete
mark_script_completed "$MARKER_FILE"
log "INFO" "$0: Completed phoenix_establish_hypervisor.sh successfully"
exit 0