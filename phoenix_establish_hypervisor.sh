#!/bin/bash
# Phoenix Establish Hypervisor Script
# Orchestrates the execution of hypervisor preparation and LXC setup scripts.
# Ensures LXC_DEFAULT_ROOT_PASSWORD is set.
# For each LXC defined in the configuration, it first runs the creation script,
# then executes the corresponding setup script.
# Prerequisites:
# - Root privileges
# - phoenix_hypervisor_config.sh (defines LXC_CONFIGS, LXC_SETUP_SCRIPTS, HYPERVISOR_MARKER_DIR)
# - phoenix_hypervisor_common.sh (defines execute_script, log, etc.)
# - LXC configuration file (e.g., /usr/local/etc/phoenix_lxc_configs.json)
# Usage: ./phoenix_establish_hypervisor.sh
# Example: ./phoenix_establish_hypervisor.sh

set -euo pipefail # Exit on error, undefined vars, pipe failures

########################################################
# Function: prompt_for_lxc_password
# Description: Prompts the user to enter and confirm the default root password for LXC containers.
# The password is then exported as a base64-encoded environment variable (LXC_DEFAULT_ROOT_PASSWORD).
# Parameters: None
# Inputs: User input from terminal
# Outputs: Exports LXC_DEFAULT_ROOT_PASSWORD, logs actions
# Returns: None (exits script on persistent failure)
# Example: prompt_for_lxc_password
########################################################
prompt_for_lxc_password() {
    local password_input
    local password_confirm
    local attempts=0
    local max_attempts=3

    while [[ $attempts -lt $max_attempts ]]; do
        read -s -p "Enter the default root password for LXC containers: " password_input
        echo # For a newline after the password input
        if [[ -z "$password_input" ]]; then
            ((attempts++))
            log "WARN" "Password cannot be empty. Attempt $attempts/$max_attempts."
            continue
        fi

        read -s -p "Confirm the password: " password_confirm
        echo # For a newline after the confirmation
        if [[ "$password_input" != "$password_confirm" ]]; then
            ((attempts++))
            log "WARN" "Passwords do not match. Attempt $attempts/$max_attempts."
            continue
        else
            log "INFO" "Password confirmed."
            # Export the base64 encoded password for the child scripts
            export LXC_DEFAULT_ROOT_PASSWORD=$(echo -n "$password_input" | base64)
            log "INFO" "LXC_DEFAULT_ROOT_PASSWORD has been set from user input."
            return 0
        fi
    done

    log "ERROR" "Maximum password attempts ($max_attempts) reached. Exiting."
    exit 1
}

########################################################
# Function: execute_script
# Description: Wrapper to execute a script, handling logging and exit codes.
# Parameters:
# script_path - The path to the script to execute.
# script_args - (Optional) Arguments to pass to the script.
# Inputs: Script path (string), optional arguments
# Outputs: Script execution output, logs start/success/failure
# Returns: 0 on script success, 1 on script failure or missing script
# Example: execute_script "/path/to/script.sh" "arg1" "arg2"
########################################################
execute_script() {
    local script_path="$1"
    shift # Remove the first argument (script_path) to leave only the args
    local script_args=("$@") # Capture remaining arguments

    if [[ ! -x "$script_path" ]]; then
        log "ERROR" "Script not found or not executable: $script_path"
        return 1
    fi

    log "INFO" "Executing: $script_path ${script_args[*]}"

    # Execute the script with its arguments
    if "$script_path" "${script_args[@]}"; then
        log "INFO" "Script succeeded: $script_path"
        return 0
    else
        local exit_code=$?
        log "ERROR" "Script failed: $script_path (Exit code: $exit_code)"
        return 1
    fi
}

# --- Script Initialization ---
# Source the common functions first to get 'log' and 'execute_script'
source /usr/local/bin/phoenix_hypervisor_common.sh || { echo "Error: Failed to source phoenix_hypervisor_common.sh" >&2; exit 1; }

# Check for root privileges early
check_root # Assuming check_root is defined in phoenix_hypervisor_common.sh

# Source the main configuration to get paths, defaults, and load LXC_CONFIGS/LXC_SETUP_SCRIPTS
source /usr/local/bin/phoenix_hypervisor_config.sh || { echo "Error: Failed to source phoenix_hypervisor_config.sh" >&2; exit 1; }

# Load the configuration (including LXC_CONFIGS and LXC_SETUP_SCRIPTS arrays)
load_hypervisor_config # Assuming this function is defined in phoenix_hypervisor_config.sh

# Ensure the log file variable is set and logging is initialized
export LOGFILE="$HYPERVISOR_LOGFILE" # Assuming HYPERVISOR_LOGFILE is defined in phoenix_hypervisor_config.sh
setup_logging # Assuming setup_logging is defined in phoenix_hypervisor_common.sh

log "INFO" "Starting phoenix_establish_hypervisor.sh"

# --- LXC Root Password Handling ---
# Check if LXC_DEFAULT_ROOT_PASSWORD is already set in the environment
if [[ -z "${LXC_DEFAULT_ROOT_PASSWORD:-}" ]]; then
    log "INFO" "LXC_DEFAULT_ROOT_PASSWORD not found in environment. Prompting user..."
    prompt_for_lxc_password
else
    log "INFO" "LXC_DEFAULT_ROOT_PASSWORD found in environment. Using provided value."
fi

# --- Script Execution Orchestrator ---
# Define the path to the default LXC creation script
default_create_script="/usr/local/bin/phoenix_hypervisor_create_lxc.sh"

# Check if LXC_CONFIGS was populated (indicating config file was found and parsed)
if [[ ${#LXC_CONFIGS[@]} -eq 0 ]]; then
    log "WARN" "No LXC configurations found in LXC_CONFIGS array. Nothing to orchestrate."
    exit 0
fi

# Iterate through the loaded LXC configurations
for lxc_id in "${!LXC_CONFIGS[@]}"; do
    log "INFO" "Processing configuration for LXC ID: $lxc_id"

    # 1. Run the creation script first
    if [[ -x "$default_create_script" ]]; then
        if execute_script "$default_create_script" "$lxc_id"; then
            log "INFO" "Creation script for LXC $lxc_id completed successfully."
        else
            log "ERROR" "Creation script for LXC $lxc_id failed. Stopping orchestration."
            exit 1
        fi
    else
        log "ERROR" "Default creation script '$default_create_script' is missing or not executable."
        exit 1
    fi

    # 2. Run the custom setup script if specified
    setup_script=""
    if [[ -n "${LXC_SETUP_SCRIPTS[$lxc_id]:-}" ]]; then
        setup_script="${LXC_SETUP_SCRIPTS[$lxc_id]}"
        log "DEBUG" "Found custom setup script for LXC $lxc_id: $setup_script"
    else
        log "INFO" "No custom setup script for LXC $lxc_id. Skipping additional setup."
        continue
    fi

    # Execute the custom setup script
    if execute_script "$setup_script" "$lxc_id"; then
        log "INFO" "Setup script for LXC $lxc_id completed successfully."
    else
        log "ERROR" "Setup script for LXC $lxc_id failed. Stopping orchestration."
        exit 1
    fi
done

log "INFO" "Completed phoenix_establish_hypervisor.sh successfully."
exit 0