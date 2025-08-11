#!/bin/bash
# Script to create a single LXC container for Phoenix Hypervisor
# Intended to be called by phoenix_establish_hypervisor.sh
# Can also be run standalone if dependencies are available
# Usage: ./phoenix_hypervisor_create_lxc.sh <container_id>
# Version: 1.7.4
# Author: Assistant

# --- Enhanced Sourcing of Dependencies ---
# Source common functions if not already sourced
# Priority: 1. Standard lib location, 2. Standard bin location, 3. Current directory
if [[ -z "${PHOENIX_HYPERVISOR_COMMON_LOADED:-}" ]]; then
    if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
        source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh
    elif [[ -f "/usr/local/bin/phoenix_hypervisor_common.sh" ]]; then
        source /usr/local/bin/phoenix_hypervisor_common.sh
        # Use log function if available, else echo
        if declare -f log_warn > /dev/null 2>&1; then
            log_warn "phoenix_hypervisor_create_lxc.sh: Sourced common functions from /usr/local/bin/. Prefer /usr/local/lib/phoenix_hypervisor/."
        else
            echo "[WARN] phoenix_hypervisor_create_lxc.sh: Sourced common functions from /usr/local/bin/. Prefer /usr/local/lib/phoenix_hypervisor/." >&2
        fi
    elif [[ -f "./phoenix_hypervisor_common.sh" ]]; then
        source ./phoenix_hypervisor_common.sh
        if declare -f log_warn > /dev/null 2>&1; then
            log_warn "phoenix_hypervisor_create_lxc.sh: Sourced common functions from current directory. Prefer standard locations."
        else
            echo "[WARN] phoenix_hypervisor_create_lxc.sh: Sourced common functions from current directory. Prefer standard locations." >&2
        fi
    else
        echo "[ERROR] phoenix_hypervisor_create_lxc.sh: Common functions file (phoenix_hypervisor_common.sh) not found in standard locations." >&2
        exit 1
    fi

    # Source configuration if not already sourced
    # Priority: 1. Standard etc location, 2. Current directory
    if [[ -z "${PHOENIX_HYPERVISOR_CONFIG_LOADED:-}" ]]; then # Optional flag for config
        if [[ -f "/usr/local/etc/phoenix_hypervisor_config.sh" ]]; then
            source /usr/local/etc/phoenix_hypervisor_config.sh
            export PHOENIX_HYPERVISOR_CONFIG_LOADED=1
        elif [[ -f "./phoenix_hypervisor_config.sh" ]]; then
            source ./phoenix_hypervisor_config.sh
            export PHOENIX_HYPERVISOR_CONFIG_LOADED=1
            # Use log function if available, else echo
            if declare -f log_warn > /dev/null 2>&1; then
                log_warn "phoenix_hypervisor_create_lxc.sh: Sourced config from current directory. Prefer /usr/local/etc/phoenix_hypervisor_config.sh"
            else
                echo "[WARN] phoenix_hypervisor_create_lxc.sh: Sourced config from current directory. Prefer /usr/local/etc/phoenix_hypervisor_config.sh" >&2
            fi
        else
            # Set default config file path if not set by environment or config script
            if [[ -z "${PHOENIX_LXC_CONFIG_FILE:-}" ]]; then
                export PHOENIX_LXC_CONFIG_FILE="/usr/local/etc/phoenix_lxc_configs.json"
            fi
            # Use log function if available, else echo
            if declare -f log_warn > /dev/null 2>&1; then
                log_warn "phoenix_hypervisor_create_lxc.sh: Config file not explicitly sourced, using default/checking environment: $PHOENIX_LXC_CONFIG_FILE"
            else
                echo "[WARN] phoenix_hypervisor_create_lxc.sh: Config file not explicitly sourced, using default/checking environment: $PHOENIX_LXC_CONFIG_FILE" >&2
            fi
        fi
    fi
fi

# --- Main Execution Logic ---
main() {
    local container_id=""

    # Simple argument parsing: expect the first argument to be the container ID
    if [[ $# -eq 1 ]]; then
        container_id="$1"
    else
        # Use log function if available, else echo
        if declare -f log_error > /dev/null 2>&1; then
            log_error "phoenix_hypervisor_create_lxc.sh: Invalid number of arguments. Usage: $0 <container_id>"
        else
            echo "[ERROR] phoenix_hypervisor_create_lxc.sh: Invalid number of arguments. Usage: $0 <container_id>" >&2
        fi
        exit 1
    fi

    # Validate container ID format
    if [[ -z "$container_id" ]] || ! [[ "$container_id" =~ ^[0-9]+$ ]]; then
        # Use log function if available, else echo
        if declare -f log_error > /dev/null 2>&1; then
            log_error "phoenix_hypervisor_create_lxc.sh: Invalid or missing container ID: '$container_id'"
        else
             echo "[ERROR] phoenix_hypervisor_create_lxc.sh: Invalid or missing container ID: '$container_id'" >&2
        fi
        exit 1
    fi

    # Use log function if available, else echo
    if declare -f log_info > /dev/null 2>&1; then
        log_info "phoenix_hypervisor_create_lxc.sh: Starting creation process for container $container_id..."
    else
        echo "[INFO] phoenix_hypervisor_create_lxc.sh: Starting creation process for container $container_id..."
    fi

    # --- Delegate to the Central Function ---
    # The orchestrator (phoenix_establish_hypervisor.sh) is responsible for
    # loading LXC_CONFIGS. We will fetch the config for this specific container
    # directly from the file to be independent.
    # However, the best practice is for the orchestrator to pass the config data.
    # To align with the corrected common.sh which likely has load_hypervisor_config,
    # and the orchestrator's design, let's assume LXC_CONFIGS should be loaded
    # if this script is run standalone. If called by the orchestrator, it should be loaded.

    # Check if LXC_CONFIGS is an associative array and contains data for this ID
    local container_config=""
    if declare -p LXC_CONFIGS > /dev/null 2>&1 && [[ "$(declare -p LXC_CONFIGS)" =~ "declare -A" ]]; then
        if [[ -n "${LXC_CONFIGS[$container_id]:-}" ]]; then
             container_config="${LXC_CONFIGS[$container_id]}"
             # Use log function if available, else echo
             if declare -f log_info > /dev/null 2>&1; then
                 log_info "phoenix_hypervisor_create_lxc.sh: Using configuration for container $container_id from LXC_CONFIGS array."
             else
                 echo "[INFO] phoenix_hypervisor_create_lxc.sh: Using configuration for container $container_id from LXC_CONFIGS array."
             fi
        fi
    fi

    # If not found in LXC_CONFIGS, load config and try again
    # (This handles standalone execution or if orchestrator didn't load it correctly)
    if [[ -z "$container_config" ]]; then
         # Use log function if available, else echo
         if declare -f log_info > /dev/null 2>&1; then
             log_info "phoenix_hypervisor_create_lxc.sh: Configuration for $container_id not in LXC_CONFIGS, loading from file..."
         else
             echo "[INFO] phoenix_hypervisor_create_lxc.sh: Configuration for $container_id not in LXC_CONFIGS, loading from file..."
         fi

         # Validate config file exists
         if [[ ! -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
             if declare -f log_error > /dev/null 2>&1; then
                 log_error "phoenix_hypervisor_create_lxc.sh: Configuration file not found: $PHOENIX_LXC_CONFIG_FILE"
             else
                 echo "[ERROR] phoenix_hypervisor_create_lxc.sh: Configuration file not found: $PHOENIX_LXC_CONFIG_FILE" >&2
             fi
             exit 1
         fi

         # Use jq to get the specific container's config
         container_config=$(jq -c ".lxc_configs.\"$container_id\"" "$PHOENIX_LXC_CONFIG_FILE" 2>/dev/null)

         if [[ -z "$container_config" ]] || [[ "$container_config" == "null" ]]; then
             if declare -f log_error > /dev/null 2>&1; then
                 log_error "phoenix_hypervisor_create_lxc.sh: Configuration for container ID $container_id not found in $PHOENIX_LXC_CONFIG_FILE"
             else
                 echo "[ERROR] phoenix_hypervisor_create_lxc.sh: Configuration for container ID $container_id not found in $PHOENIX_LXC_CONFIG_FILE" >&2
             fi
             exit 1
         fi
    fi

    # --- Call the central creation function from phoenix_hypervisor_common.sh ---
    # This is the core action, delegating to the shared library.
    if declare -f create_lxc_container > /dev/null; then
        if create_lxc_container "$container_id" "$container_config"; then
            # Use log function if available, else echo
            if declare -f log_info > /dev/null 2>&1; then
                log_info "phoenix_hypervisor_create_lxc.sh: Container $container_id created and configured successfully."
            else
                echo "[INFO] phoenix_hypervisor_create_lxc.sh: Container $container_id created and configured successfully."
            fi
            exit 0
        else
            # The function should log its own errors, but we can add a final one here
            # Use log function if available, else echo
            if declare -f log_error > /dev/null 2>&1; then
                log_error "phoenix_hypervisor_create_lxc.sh: Failed to create or configure container $container_id."
            else
                echo "[ERROR] phoenix_hypervisor_create_lxc.sh: Failed to create or configure container $container_id." >&2
            fi
            exit 1
        fi
    else
        # Use log function if available, else echo
        if declare -f log_error > /dev/null 2>&1; then
            log_error "phoenix_hypervisor_create_lxc.sh: Required function 'create_lxc_container' not found in common.sh."
        else
             echo "[ERROR] phoenix_hypervisor_create_lxc.sh: Required function 'create_lxc_container' not found in common.sh." >&2
        fi
        exit 1
    fi
}

# --- Entry Point ---
# Only run main if the script is executed, not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
