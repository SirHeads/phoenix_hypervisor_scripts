#!/usr/bin/env bash
# Common Base Functions for Phoenix Hypervisor LXC Scripts
# Version: 1.1.5 (Added dynamic port reading, QUIET_MODE, config backup, enhanced logging)
# Author: Assistant
# Integration: Supports Portainer containers (900-902, 999) with dynamic port configuration

# --- Signal Successful Loading ---
export PHOENIX_HYPERVISOR_LXC_COMMON_BASE_LOADED=1

# --- Logging Setup ---
PHOENIX_BASE_LOG_DIR="/var/log/phoenix_hypervisor"
PHOENIX_BASE_LOG_FILE="$PHOENIX_BASE_LOG_DIR/phoenix_hypervisor_lxc_common_base.log"

mkdir -p "$PHOENIX_BASE_LOG_DIR" 2>>"$PHOENIX_BASE_LOG_FILE" || {
    log_warn "Failed to create $PHOENIX_BASE_LOG_DIR, falling back to /tmp"
    PHOENIX_BASE_LOG_DIR="/tmp"
    PHOENIX_BASE_LOG_FILE="$PHOENIX_BASE_LOG_DIR/phoenix_hypervisor_lxc_common_base.log"
}
touch "$PHOENIX_BASE_LOG_FILE" 2>>"$PHOENIX_BASE_LOG_FILE" || log_warn "Failed to create $PHOENIX_BASE_LOG_FILE"
chmod 644 "$PHOENIX_BASE_LOG_FILE" 2>>"$PHOENIX_BASE_LOG_FILE" || log_warn "Could not set permissions to 644 on $PHOENIX_BASE_LOG_FILE"

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

# --- Get Portainer Port from Config ---
get_portainer_port() {
    local lxc_id="$1"
    local config_file="${PHOENIX_LXC_CONFIG_FILE:-/usr/local/etc/phoenix_lxc_configs.json}"
    if [[ ! -f "$config_file" ]]; then
        log_error "get_portainer_port: Configuration file $config_file not found"
        return 1
    fi
    local port
    if ! port=$(retry_command 3 5 jq -r ".lxc_configs.\"$lxc_id\".portainer_port // \"$( [[ \"$lxc_id\" == \"999\" ]] && echo \"9443\" || echo \"9001\" )\"" "$config_file" 2>>"$PHOENIX_BASE_LOG_FILE"); then
        log_error "get_portainer_port: Failed to parse portainer_port for container $lxc_id"
        return 1
    fi
    echo "$port"
}

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
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" | tee -a "$PHOENIX_BASE_LOG_FILE" >&2; return 1; }
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
    status=$(retry_command 3 5 pct status "$lxc_id" 2>>"$PHOENIX_BASE_LOG_FILE")
    "$log_func" "pct_exec_with_retry: Container $lxc_id status before attempt: $status"
    if [[ "$status" != "status: running" ]]; then
        "$log_func" "pct_exec_with_retry: Attempting to start container $lxc_id..."
        if ! retry_command 5 5 pct start "$lxc_id" 2>>"$PHOENIX_BASE_LOG_FILE"; then
            "$error_func" "pct_exec_with_retry: Failed to start container $lxc_id"
            return 1
        fi
        "$log_func" "pct_exec_with_retry: Waiting $stabilization_delay seconds for container $lxc_id to stabilize..."
        sleep "$stabilization_delay"
        status=$(retry_command 3 5 pct status "$lxc_id" 2>>"$PHOENIX_BASE_LOG_FILE")
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
        if pct exec "$lxc_id" -- "${cmd[@]}" 2>>"$PHOENIX_BASE_LOG_FILE"; then
            "$log_func" "pct_exec_with_retry: Command executed successfully in container $lxc_id"
            if [[ "${QUIET_MODE:-false}" != "true" ]]; then
                echo "Command executed successfully in container $lxc_id: ${cmd[*]}" >&2
            fi
            return 0
        else
            "$warn_func" "pct_exec_with_retry: Command failed in container $lxc_id. Retrying in $delay seconds..."
            sleep "$delay"
            status=$(retry_command 3 5 pct status "$lxc_id" 2>>"$PHOENIX_BASE_LOG_FILE")
            "$log_func" "pct_exec_with_retry: Container $lxc_id status after attempt $attempt: $status"
            if [[ "$status" != "status: running" ]]; then
                "$log_func" "pct_exec_with_retry: Attempting to restart container $lxc_id..."
                if ! retry_command 5 5 pct start "$lxc_id" 2>>"$PHOENIX_BASE_LOG_FILE"; then
                    "$error_func" "pct_exec_with_retry: Failed to restart container $lxc_id"
                    return 1
                fi
                "$log_func" "pct_exec_with_retry: Waiting $stabilization_delay seconds for container $lxc_id to stabilize..."
                sleep "$stabilization_delay"
                status=$(retry_command 3 5 pct status "$lxc_id" 2>>"$PHOENIX_BASE_LOG_FILE")
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
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" | tee -a "$PHOENIX_BASE_LOG_FILE" >&2; return 1; }
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

    local config_file="/etc/pve/lxc/$lxc_id.conf"
    if [[ ! -f "$config_file" ]]; then
        "$error_func" "make_container_privileged: LXC config file not found: $config_file"
        return 1
    fi

    "$log_func" "make_container_privileged: Backing up LXC config file $config_file..."
    cp "$config_file" "$config_file.bak" 2>>"$PHOENIX_BASE_LOG_FILE" || "$warn_func" "make_container_privileged: Failed to backup $config_file"

    "$log_func" "make_container_privileged: Configuring container $lxc_id to be privileged..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Configuring container $lxc_id to be privileged..." >&2
    fi

    # Warn if GPU access might be needed for containers 900-902
    if [[ "$lxc_id" -ge 900 && "$lxc_id" -le 902 ]]; then
        "$warn_func" "make_container_privileged: Container $lxc_id (Portainer agent) may require GPU access. Ensure GPU passthrough is configured if needed."
    fi

    # Skip privilege escalation for container 999 unless specified
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
    if ! retry_command 3 10 pct stop "$lxc_id" 2>>"$PHOENIX_BASE_LOG_FILE"; then
        "$error_func" "make_container_privileged: Failed to stop container $lxc_id"
        return 1
    fi

    # Update container configuration
    "$log_func" "make_container_privileged: Setting unprivileged: 0 in $config_file..."
    if ! grep -q "^unprivileged: 0" "$config_file" 2>>"$PHOENIX_BASE_LOG_FILE"; then
        if grep -q "^unprivileged: 1" "$config_file" 2>>"$PHOENIX_BASE_LOG_FILE"; then
            sed -i 's/^unprivileged: 1/unprivileged: 0/' "$config_file" 2>>"$PHOENIX_BASE_LOG_FILE"
        else
            echo "unprivileged: 0" >> "$config_file"
        fi
    fi

    "$log_func" "make_container_privileged: Added lxc.apparmor.profile: unconfined to $config_file."
    if ! grep -q "^lxc.apparmor.profile: unconfined" "$config_file" 2>>"$PHOENIX_BASE_LOG_FILE"; then
        echo "lxc.apparmor.profile: unconfined" >> "$config_file"
    fi

    "$log_func" "make_container_privileged: Setting lxc.start.timeout: 300 in $config_file..."
    if ! grep -q "^lxc.start.timeout: 300" "$config_file" 2>>"$PHOENIX_BASE_LOG_FILE"; then
        echo "lxc.start.timeout: 300" >> "$config_file"
    fi

    # Start the container
    "$log_func" "make_container_privileged: Starting container $lxc_id..."
    if ! retry_command 5 5 pct start "$lxc_id" 2>>"$PHOENIX_BASE_LOG_FILE"; then
        "$error_func" "make_container_privileged: Failed to start container $lxc_id"
        return 1
    fi

    # Wait for container to become responsive
    "$log_func" "make_container_privileged: Waiting for container $lxc_id to become responsive..."
    if ! pct_exec_with_retry "$lxc_id" bash -c "echo 'Responsive'" 2>>"$PHOENIX_BASE_LOG_FILE"; then
        "$error_func" "make_container_privileged: Container $lxc_id is not responsive"
        return 1
    fi

    "$log_func" "make_container_privileged: Container $lxc_id is responsive."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Container $lxc_id configured as privileged and is responsive." >&2
    fi
    return 0
}

# --- Check if a Container Exists ---
container_exists() {
    local lxc_id="$1"
    if [[ -z "$lxc_id" ]]; then
        if declare -F log_error >/dev/null 2>&1; then
            log_error "container_exists: Container ID is required."
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] container_exists: Container ID is required." | tee -a "$PHOENIX_BASE_LOG_FILE" >&2
        fi
        return 2
    fi

    if retry_command 3 5 pct config "$lxc_id" 2>>"$PHOENIX_BASE_LOG_FILE" >/dev/null; then
        log_info "container_exists: Container $lxc_id exists."
        return 0
    else
        log_info "container_exists: Container $lxc_id does not exist."
        return 1
    fi
}

# --- Ensure a Container is Running ---
ensure_container_running() {
    local lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        if declare -F log_error >/dev/null 2>&1; then
            log_error "ensure_container_running: Container ID is required."
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] ensure_container_running: Container ID is required." | tee -a "$PHOENIX_BASE_LOG_FILE" >&2
        fi
        return 2
    fi

    local status
    status=$(retry_command 3 5 pct status "$lxc_id" 2>>"$PHOENIX_BASE_LOG_FILE" | grep 'status' | awk '{print $2}')

    if [[ "$status" == "running" ]]; then
        log_info "ensure_container_running: Container $lxc_id is already running."
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Container $lxc_id is already running." >&2
        fi
        return 0
    elif [[ "$status" == "stopped" ]]; then
        log_info "ensure_container_running: Container $lxc_id is stopped. Starting..."
        if retry_command 3 10 pct start "$lxc_id" 2>>"$PHOENIX_BASE_LOG_FILE"; then
            log_info "ensure_container_running: Container $lxc_id started successfully."
            if [[ "${QUIET_MODE:-false}" != "true" ]]; then
                echo "Container $lxc_id started successfully." >&2
            fi
            return 0
        else
            log_error "ensure_container_running: Failed to start container $lxc_id after retries."
            return 1
        fi
    else
        log_error "ensure_container_running: Container $lxc_id has unexpected status: $status"
        return 1
    fi
}

# --- Perform a Basic Network Connectivity Check Inside the Container ---
check_container_network() {
    local lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        if declare -F log_error >/dev/null 2>&1; then
            log_error "check_container_network: Container ID is required."
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] check_container_network: Container ID is required." | tee -a "$PHOENIX_BASE_LOG_FILE" >&2
        fi
        return 2
    fi

    log_info "check_container_network: Performing basic network check in container $lxc_id..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Performing network check in container $lxc_id..." >&2
    fi

    local network_check_cmd="set -e; timeout 10s ping -c 1 8.8.8.8 >/dev/null 2>&1 && echo '[SUCCESS] Network ping successful' || { echo '[ERROR] Network ping failed'; exit 1; }"

    if pct_exec_with_retry "$lxc_id" bash -c "$network_check_cmd" 2>>"$PHOENIX_BASE_LOG_FILE"; then
        log_info "check_container_network: Basic network connectivity verified for container $lxc_id."
    else
        log_warn "check_container_network: Basic network check failed in container $lxc_id."
        return 1
    fi

    # Portainer-specific port check
    if [[ "$lxc_id" == "999" || "$lxc_id" -ge 900 && "$lxc_id" -le 902 ]]; then
        local port_check_ip="10.0.0.99"
        local port_check_port
        port_check_port=$(get_portainer_port "$lxc_id")
        if [[ $? -ne 0 ]]; then
            log_warn "check_container_network: Failed to retrieve Portainer port for container $lxc_id, using default."
            port_check_port=$([[ "$lxc_id" == "999" ]] && echo "9443" || echo "9001")
        fi
        log_info "check_container_network: Checking Portainer endpoint $port_check_ip:$port_check_port in container $lxc_id..."
        local port_check_cmd="set -e; if command -v nc >/dev/null 2>&1; then timeout 5s nc -z $port_check_ip $port_check_port >/dev/null 2>&1 && echo '[SUCCESS] Portainer port check successful' || { echo '[ERROR] Portainer port check failed'; exit 1; }; else echo '[WARN] netcat not installed, skipping port check'; exit 0; fi"
        if pct_exec_with_retry "$lxc_id" bash -c "$port_check_cmd" 2>>"$PHOENIX_BASE_LOG_FILE"; then
            log_info "check_container_network: Portainer endpoint $port_check_ip:$port_check_port verified for container $lxc_id."
        else
            log_warn "check_container_network: Portainer endpoint $port_check_ip:$port_check_port check failed in container $lxc_id."
            return 1
        fi
    fi

    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Network connectivity verified for container $lxc_id." >&2
    fi
    return 0
}

# --- Set Temporary DNS Inside the Container ---
set_temporary_dns() {
    local lxc_id="$1"
    local dns_server="${2:-8.8.8.8}"

    if [[ -z "$lxc_id" ]]; then
        if declare -F log_error >/dev/null 2>&1; then
            log_error "set_temporary_dns: Container ID is required."
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] set_temporary_dns: Container ID is required." | tee -a "$PHOENIX_BASE_LOG_FILE" >&2
        fi
        return 2
    fi

    log_info "set_temporary_dns: Setting temporary DNS to $dns_server in container $lxc_id..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Setting temporary DNS to $dns_server in container $lxc_id..." >&2
    fi

    local dns_set_cmd="set -e; echo 'nameserver $dns_server' > /etc/resolv.conf && echo '[INFO] Temporary DNS set to $dns_server'"

    if pct_exec_with_retry "$lxc_id" bash -c "$dns_set_cmd" 2>>"$PHOENIX_BASE_LOG_FILE"; then
        log_info "set_temporary_dns: Temporary DNS set successfully in container $lxc_id."
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Temporary DNS set successfully in container $lxc_id." >&2
        fi
        return 0
    else
        log_error "set_temporary_dns: Failed to set temporary DNS in container $lxc_id."
        return 1
    fi
}

# --- Initialize Logging ---
if declare -F setup_logging >/dev/null 2>&1; then
    setup_logging
fi

# --- Signal Successful Loading ---
if declare -F log_info >/dev/null 2>&1; then
    log_info "phoenix_hypervisor_lxc_common_base.sh: Library loaded successfully."
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] phoenix_hypervisor_lxc_common_base.sh: Library loaded successfully." | tee -a "$PHOENIX_BASE_LOG_FILE"
fi