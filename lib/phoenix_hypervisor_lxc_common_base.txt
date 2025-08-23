#!/usr/bin/env bash

# phoenix_hypervisor_lxc_common_base.sh
#
# Common functions for basic LXC container operations.
# This script is intended to be sourced by other Phoenix Hypervisor scripts.

# --- Helper Functions ---

# Execute command in container with retry logic
# Usage: pct_exec_with_retry <container_id> <command_string>
pct_exec_with_retry() {
    local lxc_id=""
    local command=""
    local max_attempts=3
    local delay=30
    local attempt=1

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    fi

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    # --- Parse arguments correctly ---
    if [[ $# -lt 2 ]]; then
        "$error_func" "pct_exec_with_retry: Container ID and command are required."
        return 1
    fi

    lxc_id="$1"
    shift

    # Check if the next argument is the standard '--' separator for pct exec
    if [[ "$1" == "--" ]]; then
        shift # Remove the '--'
    fi

    # Check if there's anything left to run
    if [[ $# -eq 0 ]]; then
         "$error_func" "pct_exec_with_retry: No command provided."
        return 1
    fi

    # Reconstruct the command from the remaining arguments
    # This handles simple strings and commands with arguments
    command=""
    while [[ $# -gt 0 ]]; do
       if [[ -z "$command" ]]; then
           command="$1"
       else
           # Quote arguments to prevent word splitting issues when passed to bash -c later
           # printf %q is generally good for this in bash
           command="$command $(printf "%q" "$1")"
       fi
       shift
    done
    # --- End argument parsing ---

    if [[ -z "$lxc_id" || -z "$command" ]]; then
        "$error_func" "pct_exec_with_retry: Container ID and command string are required."
        return 1
    fi

    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "pct_exec_with_retry: Executing command in container $lxc_id (attempt $attempt/$max_attempts)..."
        # Execute the reconstructed command string with bash -c
        if pct exec "$lxc_id" -- bash -c "$command"; then
            "$log_func" "pct_exec_with_retry: Command executed successfully in container $lxc_id"
            return 0
        else
            # Use log_warn if available, otherwise fallback
            local warn_func="log_warn"
            if ! declare -F log_warn >/dev/null 2>&1; then
                warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" >&2; }
            fi
            "$warn_func" "pct_exec_with_retry: Command failed in container $lxc_id. Retrying in $delay seconds..."
            sleep "$delay"
            ((attempt++))
        fi
    done

    "$error_func" "pct_exec_with_retry: Command failed after $max_attempts attempts in container $lxc_id"
    return 1
}

# Check if a container exists
# Usage: container_exists <container_id>
container_exists() {
    local lxc_id="$1"
    if [[ -z "$lxc_id" ]]; then
         if declare -F log_error >/dev/null 2>&1; then
            log_error "container_exists: Container ID is required."
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] container_exists: Container ID is required." >&2
            exit 1
        fi
        return 2 # Invalid argument
    fi

    if pct config "$lxc_id" >/dev/null 2>&1; then
        return 0 # Exists
    else
        return 1 # Does not exist
    fi
}

# Ensure a container is running, starting it if necessary
# Usage: ensure_container_running <container_id>
ensure_container_running() {
    local lxc_id="$1"

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    fi

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    if [[ -z "$lxc_id" ]]; then
        "$error_func" "ensure_container_running: Container ID is required."
        return 2
    fi

    local status
    status=$(pct status "$lxc_id" 2>/dev/null | grep 'status' | awk '{print $2}')

    if [[ "$status" == "running" ]]; then
        "$log_func" "ensure_container_running: Container $lxc_id is already running."
        return 0
    elif [[ "$status" == "stopped" ]]; then
        "$log_func" "ensure_container_running: Container $lxc_id is stopped. Starting..."
        # Use retry_command if available, otherwise direct call
        if declare -F retry_command >/dev/null 2>&1; then
            if retry_command 3 10 pct start "$lxc_id"; then
                "$log_func" "ensure_container_running: Container $lxc_id started successfully."
                return 0
            else
                "$error_func" "ensure_container_running: Failed to start container $lxc_id after retries."
                return 1
            fi
        else
            if pct start "$lxc_id"; then
                 "$log_func" "ensure_container_running: Container $lxc_id started successfully."
                return 0
            else
                "$error_func" "ensure_container_running: Failed to start container $lxc_id."
                return 1
            fi
        fi
    else
        "$error_func" "ensure_container_running: Container $lxc_id has unexpected status: $status"
        return 1
    fi
}

# Perform a basic network connectivity check inside the container
# Usage: check_container_network <container_id>
check_container_network() {
    local lxc_id="$1"

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    fi

    # Use log_warn if available, otherwise fallback
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" >&2; }
    fi

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    if [[ -z "$lxc_id" ]]; then
        "$error_func" "check_container_network: Container ID is required."
        return 2
    fi

    "$log_func" "check_container_network: Performing basic network check in container $lxc_id..."

    local network_check_cmd="set -e; timeout 10s ping -c 1 8.8.8.8 >/dev/null 2>&1 && echo '[SUCCESS] Network ping successful' || { echo '[ERROR] Network ping failed'; exit 1; }"

    if pct_exec_with_retry "$lxc_id" "$network_check_cmd"; then
        "$log_func" "check_container_network: Basic network connectivity verified for container $lxc_id."
        return 0
    else
        "$warn_func" "check_container_network: Basic network check failed in container $lxc_id."
        return 1
    fi
}

# Set temporary DNS inside the container
# Usage: set_temporary_dns <container_id> [dns_server]
set_temporary_dns() {
    local lxc_id="$1"
    local dns_server="${2:-8.8.8.8}"

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    fi

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    if [[ -z "$lxc_id" ]]; then
        "$error_func" "set_temporary_dns: Container ID is required."
        return 2
    fi

    "$log_func" "set_temporary_dns: Setting temporary DNS to $dns_server in container $lxc_id..."

    local dns_set_cmd="set -e; echo 'nameserver $dns_server' > /etc/resolv.conf && echo '[INFO] Temporary DNS set to $dns_server'"

    if pct_exec_with_retry "$lxc_id" "$dns_set_cmd"; then
        "$log_func" "set_temporary_dns: Temporary DNS set successfully in container $lxc_id."
        return 0
    else
        "$error_func" "set_temporary_dns: Failed to set temporary DNS in container $lxc_id."
        return 1
    fi
}


echo "[INFO] phoenix_hypervisor_lxc_common_base.sh: Library loaded successfully."
