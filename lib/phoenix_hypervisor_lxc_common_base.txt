#!/usr/bin/env bash
# Common Base Functions for Phoenix Hypervisor LXC Scripts
# Version: 1.1.4 (Enhanced network check for Portainer endpoints, added logging to phoenix_hypervisor_lxc_common_base.log, aligned with Portainer setup)
# Author: Assistant

# --- Signal successful loading ---
export PHOENIX_HYPERVISOR_LXC_COMMON_BASE_LOADED=1

# --- Logging Setup ---
PHOENIX_BASE_LOG_DIR="/var/log/phoenix_hypervisor"
PHOENIX_BASE_LOG_FILE="$PHOENIX_BASE_LOG_DIR/phoenix_hypervisor_lxc_common_base.log"

mkdir -p "$PHOENIX_BASE_LOG_DIR" 2>/dev/null || {
    PHOENIX_BASE_LOG_DIR="/tmp"
    PHOENIX_BASE_LOG_FILE="$PHOENIX_BASE_LOG_DIR/phoenix_hypervisor_lxc_common_base.log"
}
touch "$PHOENIX_BASE_LOG_FILE" 2>/dev/null || true
chmod 644 "$PHOENIX_BASE_LOG_FILE" 2>/dev/null || true

# --- Source Common Functions ---
if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh
    log_info "phoenix_hypervisor_lxc_common_base.sh: Sourced common functions."
elif [[ -f "/usr/local/bin/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/bin/phoenix_hypervisor_common.sh
    log_info "phoenix_hypervisor_lxc_common_base.sh: Sourced common functions from /usr/local/bin/."
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] phoenix_hypervisor_lxc_common_base.sh: Cannot find phoenix_hypervisor_common.sh" >&2
    tee -a "$PHOENIX_BASE_LOG_FILE" >&2
    exit 1
fi

# --- Check if sourced correctly ---
if [[ -z "$PHOENIX_HYPERVISOR_COMMON_LOADED" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] phoenix_hypervisor_lxc_common_base.sh: Failed to load phoenix_hypervisor_common.sh" >&2
    tee -a "$PHOENIX_BASE_LOG_FILE" >&2
    exit 1
fi

# --- Execute Command in Container with Retry ---
pct_exec_with_retry() {
    local lxc_id="$1"
    shift
    local cmd=("$@")
    local max_attempts=3
    local delay=10
    local stabilization_delay=10

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*" | tee -a "$PHOENIX_BASE_LOG_FILE"; }
    fi

    # Use log_warn if available, otherwise fallback
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" | tee -a "$PHOENIX_BASE_LOG_FILE" >&2; }
    fi

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" | tee -a "$PHOENIX_BASE_LOG_FILE" >&2; exit 1; }
    fi

    # Validate input
    if [[ -z "$lxc_id" ]]; then
        "$error_func" "pct_exec_with_retry: Container ID is required"
        return 1
    fi
    if [[ ${#cmd[@]} -eq 0 ]]; then
        "$error_func" "pct_exec_with_retry: Command is required"
        return 1
    fi

    # Check container status before attempting execution
    local status
    status=$(pct status "$lxc_id" 2>/dev/null)
    "$log_func" "pct_exec_with_retry: Container $lxc_id status before attempt: $status"
    if [[ "$status" != "status: running" ]]; then
        "$log_func" "pct_exec_with_retry: Attempting to start container $lxc_id..."
        if ! retry_command 5 5 pct start "$lxc_id"; then
            "$error_func" "pct_exec_with_retry: Failed to start container $lxc_id"
            return 1
        fi
        "$log_func" "pct_exec_with_retry: Waiting $stabilization_delay seconds for container $lxc_id to stabilize..."
        sleep "$stabilization_delay"
        # Recheck status after stabilization
        status=$(pct status "$lxc_id" 2>/dev/null)
        "$log_func" "pct_exec_with_retry: Container $lxc_id status after stabilization: $status"
        if [[ "$status" != "status: running" ]]; then
            "$error_func" "pct_exec_with_retry: Container $lxc_id failed to stabilize"
            return 1
        fi
    fi

    # Retry loop for command execution
    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "pct_exec_with_retry: Executing command in container $lxc_id (attempt $attempt/$max_attempts): ${cmd[*]}"
        if pct exec "$lxc_id" -- "${cmd[@]}" >/dev/null 2>>"$PHOENIX_BASE_LOG_FILE"; then
            "$log_func" "pct_exec_with_retry: Command executed successfully in container $lxc_id"
            return 0
        else
            "$warn_func" "pct_exec_with_retry: Command failed in container $lxc_id. Retrying in $delay seconds..."
            sleep "$delay"
            # Recheck container status
            status=$(pct status "$lxc_id" 2>/dev/null)
            "$log_func" "pct_exec_with_retry: Container $lxc_id status after attempt $attempt: $status"
            if [[ "$status" != "status: running" ]]; then
                "$log_func" "pct_exec_with_retry: Attempting to restart container $lxc_id..."
                if ! retry_command 5 5 pct start "$lxc_id"; then
                    "$error_func" "pct_exec_with_retry: Failed to restart container $lxc_id"
                    return 1
                fi
                "$log_func" "pct_exec_with_retry: Waiting $stabilization_delay seconds for container $lxc_id to stabilize..."
                sleep "$stabilization_delay"
                status=$(pct status "$lxc_id" 2>/dev/null)
                "$log_func" "pct_exec_with_retry: Container $lxc_id status after stabilization: $status"
                if [[ "$status" != "status: running" ]]; then
                    "$error_func" "pct_exec_with_retry: Container $lxc_id failed to stabilize after restart"
                    return 1
                fi
            fi
            ((attempt++))
        fi
    done
    "$error_func" "pct_exec_with_retry: Command failed after $max_attempts attempts in container $lxc_id"
    return 1
}

# --- Make Container Privileged ---
make_container_privileged() {
    local lxc_id="$1"

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*" | tee -a "$PHOENIX_BASE_LOG_FILE"; }
    fi

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" | tee -a "$PHOENIX_BASE_LOG_FILE" >&2; exit 1; }
    fi

    # Use log_warn if available, otherwise fallback
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" | tee -a "$PHOENIX_BASE_LOG_FILE" >&2; }
    fi

    if [[ -z "$lxc_id" ]]; then
        "$error_func" "make_container_privileged: Container ID is required"
        return 1
    fi

    "$log_func" "make_container_privileged: Configuring container $lxc_id to be privileged..."

    # --- NEW: Warn if GPU access might be needed for containers 900-902 ---
    if [[ "$lxc_id" -ge 900 && "$lxc_id" -le 902 ]]; then
        "$warn_func" "make_container_privileged: Container $lxc_id (Portainer agent) may require GPU access. Ensure GPU passthrough is configured if needed."
    fi

    # --- NEW: Skip privilege escalation for container 999 unless specified ---
    if [[ "$lxc_id" == "999" ]]; then
        "$log_func" "make_container_privileged: Container $lxc_id (Portainer server) typically does not require privileged mode. Skipping unless explicitly required."
        if [[ -n "${FORCE_PRIVILEGED_999:-}" && "$FORCE_PRIVILEGED_999" == "true" ]]; then
            "$log_func" "make_container_privileged: FORCE_PRIVILEGED_999 is set, proceeding with privileged configuration for container $lxc_id."
        else
            return 0
        fi
    fi

    # Stop the container
    "$log_func" "make_container_privileged: Stopping container $lxc_id..."
    if ! retry_command 3 10 pct stop "$lxc_id"; then
        "$error_func" "make_container_privileged: Failed to stop container $lxc_id"
        return 1
    fi

    # Update container configuration
    local config_file="/etc/pve/lxc/$lxc_id.conf"
    "$log_func" "make_container_privileged: Setting unprivileged: 0 in $config_file..."
    if ! grep -q "^unprivileged: 0" "$config_file" 2>/dev/null; then
        if grep -q "^unprivileged: 1" "$config_file" 2>/dev/null; then
            sed -i 's/^unprivileged: 1/unprivileged: 0/' "$config_file"
        else
            echo "unprivileged: 0" >> "$config_file"
        fi
    fi

    "$log_func" "make_container_privileged: Added lxc.apparmor.profile: unconfined to $config_file."
    if ! grep -q "^lxc.apparmor.profile: unconfined" "$config_file" 2>/dev/null; then
        echo "lxc.apparmor.profile: unconfined" >> "$config_file"
    fi

    # Add monitor timeout to prevent socket issues
    "$log_func" "make_container_privileged: Setting lxc.start.timeout: 300 in $config_file..."
    if ! grep -q "^lxc.start.timeout: 300" "$config_file" 2>/dev/null; then
        echo "lxc.start.timeout: 300" >> "$config_file"
    fi

    # Start the container
    "$log_func" "make_container_privileged: Starting container $lxc_id..."
    if ! retry_command 5 5 pct start "$lxc_id"; then
        "$error_func" "make_container_privileged: Failed to start container $lxc_id"
        return 1
    fi

    # Wait for container to become responsive
    "$log_func" "make_container_privileged: Waiting for container $lxc_id to become responsive..."
    if ! pct_exec_with_retry "$lxc_id" bash -c "echo 'Responsive'"; then
        "$error_func" "make_container_privileged: Container $lxc_id is not responsive"
        return 1
    fi

    "$log_func" "make_container_privileged: Container $lxc_id is responsive."
    return 0
}

# --- Check if a container exists ---
container_exists() {
    local lxc_id="$1"
    if [[ -z "$lxc_id" ]]; then
        if declare -F log_error >/dev/null 2>&1; then
            log_error "container_exists: Container ID is required."
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] container_exists: Container ID is required." | tee -a "$PHOENIX_BASE_LOG_FILE" >&2
            exit 1
        fi
        return 2 # Invalid argument
    fi

    if pct config "$lxc_id" >/dev/null 2>>"$PHOENIX_BASE_LOG_FILE"; then
        return 0 # Exists
    else
        return 1 # Does not exist
    fi
}

# --- Ensure a container is running, starting it if necessary ---
ensure_container_running() {
    local lxc_id="$1"

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*" | tee -a "$PHOENIX_BASE_LOG_FILE"; }
    fi

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" | tee -a "$PHOENIX_BASE_LOG_FILE" >&2; exit 1; }
    fi

    if [[ -z "$lxc_id" ]]; then
        "$error_func" "ensure_container_running: Container ID is required."
        return 2
    fi

    local status
    status=$(pct status "$lxc_id" 2>>"$PHOENIX_BASE_LOG_FILE" | grep 'status' | awk '{print $2}')

    if [[ "$status" == "running" ]]; then
        "$log_func" "ensure_container_running: Container $lxc_id is already running."
        return 0
    elif [[ "$status" == "stopped" ]]; then
        "$log_func" "ensure_container_running: Container $lxc_id is stopped. Starting..."
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

# --- Perform a basic network connectivity check inside the container ---
check_container_network() {
    local lxc_id="$1"

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*" | tee -a "$PHOENIX_BASE_LOG_FILE"; }
    fi

    # Use log_warn if available, otherwise fallback
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" | tee -a "$PHOENIX_BASE_LOG_FILE" >&2; }
    fi

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" | tee -a "$PHOENIX_BASE_LOG_FILE" >&2; exit 1; }
    fi

    if [[ -z "$lxc_id" ]]; then
        "$error_func" "check_container_network: Container ID is required."
        return 2
    fi

    "$log_func" "check_container_network: Performing basic network check in container $lxc_id..."

    # Basic ping test to 8.8.8.8
    local network_check_cmd="set -e; timeout 10s ping -c 1 8.8.8.8 >/dev/null 2>&1 && echo '[SUCCESS] Network ping successful' || { echo '[ERROR] Network ping failed'; exit 1; }"

    if pct_exec_with_retry "$lxc_id" bash -c "$network_check_cmd"; then
        "$log_func" "check_container_network: Basic network connectivity verified for container $lxc_id."
    else
        "$warn_func" "check_container_network: Basic network check failed in container $lxc_id."
        return 1
    fi

    # --- NEW: Portainer-specific port check ---
    if [[ "$lxc_id" == "999" || "$lxc_id" -ge 900 && "$lxc_id" -le 902 ]]; then
        local port_check_ip="10.0.0.99"
        local port_check_port
        if [[ "$lxc_id" == "999" ]]; then
            port_check_port="9443"
        else
            port_check_port="9001"
        fi
        "$log_func" "check_container_network: Checking Portainer endpoint $port_check_ip:$port_check_port in container $lxc_id..."
        local port_check_cmd="set -e; if command -v nc >/dev/null 2>&1; then timeout 5s nc -z $port_check_ip $port_check_port >/dev/null 2>&1 && echo '[SUCCESS] Portainer port check successful' || { echo '[ERROR] Portainer port check failed'; exit 1; }; else echo '[WARN] netcat not installed, skipping port check'; exit 0; fi"
        if pct_exec_with_retry "$lxc_id" bash -c "$port_check_cmd"; then
            "$log_func" "check_container_network: Portainer endpoint $port_check_ip:$port_check_port verified for container $lxc_id."
        else
            "$warn_func" "check_container_network: Portainer endpoint $port_check_ip:$port_check_port check failed in container $lxc_id."
            return 1
        fi
    fi

    return 0
}

# --- Set temporary DNS inside the container ---
set_temporary_dns() {
    local lxc_id="$1"
    local dns_server="${2:-8.8.8.8}"

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*" | tee -a "$PHOENIX_BASE_LOG_FILE"; }
    fi

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" | tee -a "$PHOENIX_BASE_LOG_FILE" >&2; exit 1; }
    fi

    if [[ -z "$lxc_id" ]]; then
        "$error_func" "set_temporary_dns: Container ID is required."
        return 2
    fi

    "$log_func" "set_temporary_dns: Setting temporary DNS to $dns_server in container $lxc_id..."

    local dns_set_cmd="set -e; echo 'nameserver $dns_server' > /etc/resolv.conf && echo '[INFO] Temporary DNS set to $dns_server'"

    if pct_exec_with_retry "$lxc_id" bash -c "$dns_set_cmd"; then
        "$log_func" "set_temporary_dns: Temporary DNS set successfully in container $lxc_id."
        return 0
    else
        "$error_func" "set_temporary_dns: Failed to set temporary DNS in container $lxc_id."
        return 1
    fi
}

# Initialize logging
if declare -F setup_logging >/dev/null 2>&1; then
    setup_logging
fi

# Signal successful loading
if declare -F log_info >/dev/null 2>&1; then
    log_info "phoenix_hypervisor_lxc_common_base.sh: Library loaded successfully."
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] phoenix_hypervisor_lxc_common_base.sh: Library loaded successfully." | tee -a "$PHOENIX_BASE_LOG_FILE"
fi