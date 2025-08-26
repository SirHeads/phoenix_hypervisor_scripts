#!/usr/bin/env bash
# Common functions for managing systemd services inside LXC containers.
# This script is intended to be sourced by other Phoenix Hypervisor scripts.
# Requires: pct, bash, jq, standard Unix tools
# Assumes: phoenix_hypervisor_common.sh is sourced for logging/retry functions
# Assumes: phoenix_hypervisor_lxc_common_base.sh is sourced for pct_exec_with_retry
# Version: 2.0.1 (Dedicated log file, QUIET_MODE, enhanced GPU checks, service validation, timeouts)
# Author: Assistant
# Integration: Supports Portainer containers (900-902, 999) with dynamic configuration

# --- Logging Setup ---
PHOENIX_SYSTEMD_LOG_DIR="/var/log/phoenix_hypervisor"
PHOENIX_SYSTEMD_LOG_FILE="$PHOENIX_SYSTEMD_LOG_DIR/phoenix_hypervisor_lxc_common_systemd.log"

mkdir -p "$PHOENIX_SYSTEMD_LOG_DIR" 2>>"$PHOENIX_SYSTEMD_LOG_FILE" || {
    log_warn "Failed to create $PHOENIX_SYSTEMD_LOG_DIR, falling back to /tmp"
    PHOENIX_SYSTEMD_LOG_DIR="/tmp"
    PHOENIX_SYSTEMD_LOG_FILE="$PHOENIX_SYSTEMD_LOG_DIR/phoenix_hypervisor_lxc_common_systemd.log"
}
touch "$PHOENIX_SYSTEMD_LOG_FILE" 2>>"$PHOENIX_SYSTEMD_LOG_FILE" || log_warn "Failed to create $PHOENIX_SYSTEMD_LOG_FILE"
chmod 644 "$PHOENIX_SYSTEMD_LOG_FILE" 2>>"$PHOENIX_SYSTEMD_LOG_FILE" || log_warn "Could not set permissions to 644 on $PHOENIX_SYSTEMD_LOG_FILE"

# --- Source Dependencies ---
if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh
    log_info "phoenix_hypervisor_lxc_common_systemd.sh: Sourced common functions."
elif [[ -f "/usr/local/bin/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/bin/phoenix_hypervisor_common.sh
    log_info "phoenix_hypervisor_lxc_common_systemd.sh: Sourced common functions from /usr/local/bin/."
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] phoenix_hypervisor_lxc_common_systemd.sh: Cannot find phoenix_hypervisor_common.sh" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE" >&2
    exit 1
fi

if [[ -z "$PHOENIX_HYPERVISOR_COMMON_LOADED" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] phoenix_hypervisor_lxc_common_systemd.sh: Failed to load phoenix_hypervisor_common.sh" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE" >&2
    exit 1
fi

if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_lxc_common_base.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_lxc_common_base.sh
    log_info "phoenix_hypervisor_lxc_common_systemd.sh: Sourced base functions."
elif [[ -f "/usr/local/bin/phoenix_hypervisor_lxc_common_base.sh" ]]; then
    source /usr/local/bin/phoenix_hypervisor_lxc_common_base.sh
    log_info "phoenix_hypervisor_lxc_common_systemd.sh: Sourced base functions from /usr/local/bin/."
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] phoenix_hypervisor_lxc_common_systemd.sh: Cannot find phoenix_hypervisor_lxc_common_base.sh" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE" >&2
    exit 1
fi

if [[ -z "$PHOENIX_HYPERVISOR_LXC_COMMON_BASE_LOADED" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] phoenix_hypervisor_lxc_common_systemd.sh: Failed to load phoenix_hypervisor_lxc_common_base.sh" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE" >&2
    exit 1
fi

# --- Get Configuration Value ---
get_config_value() {
    local lxc_id="$1"
    local key="$2"
    local config_file="${PHOENIX_LXC_CONFIG_FILE:-/usr/local/etc/phoenix_lxc_configs.json}"
    if [[ ! -f "$config_file" ]]; then
        log_error "get_config_value: Configuration file $config_file not found"
        return 1
    fi
    local value
    if ! value=$(retry_command 3 5 jq -r ".lxc_configs.\"$lxc_id\".\"$key\" // null" "$config_file" 2>>"$PHOENIX_SYSTEMD_LOG_FILE"); then
        log_error "get_config_value: Failed to parse $key for container $lxc_id"
        return 1
    fi
    if [[ "$value" == "null" ]]; then
        log_warn "get_config_value: Key $key not found for container $lxc_id"
        return 1
    fi
    echo "$value"
}

# --- Helper Function: Check GPU Assignment ---
check_gpu_assignment() {
    local lxc_id="$1"
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE"; }
    fi
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE" >&2; return 1; }
    fi
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE" >&2; }
    fi
    if [[ -z "$lxc_id" ]]; then
        "$error_func" "check_gpu_assignment: Missing lxc_id"
        return 1
    fi
    if [[ ! "$lxc_id" =~ ^[0-9]+$ ]]; then
        "$error_func" "check_gpu_assignment: Invalid lxc_id format: $lxc_id (must be numeric)"
        return 1
    fi
    if [[ "$lxc_id" == "999" ]]; then
        "$log_func" "check_gpu_assignment: Container $lxc_id (Portainer server) does not require GPU assignment. Skipping."
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Skipping GPU assignment check for container $lxc_id (Portainer server)." >&2
        fi
        return 1
    fi
    if [[ "$lxc_id" -ge 900 && "$lxc_id" -le 902 ]]; then
        "$warn_func" "check_gpu_assignment: Container $lxc_id (Portainer agent) may require GPU access for vLLM."
    fi
    local config_file="${PHOENIX_LXC_CONFIG_FILE:-/usr/local/etc/phoenix_lxc_configs.json}"
    if [[ ! -f "$config_file" ]]; then
        "$error_func" "check_gpu_assignment: Configuration file $config_file not found"
        return 1
    fi
    local gpu_assignment
    if ! gpu_assignment=$(retry_command 3 5 jq -r ".lxc_configs.\"$lxc_id\".gpu_assignment // \"none\"" "$config_file" 2>>"$PHOENIX_SYSTEMD_LOG_FILE"); then
        "$error_func" "check_gpu_assignment: Failed to parse gpu_assignment for container $lxc_id"
        return 1
    fi
    if [[ "$gpu_assignment" == "none" || -z "$gpu_assignment" ]]; then
        "$log_func" "check_gpu_assignment: No GPU assignment for container $lxc_id (gpu_assignment: $gpu_assignment)"
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "No GPU assignment for container $lxc_id." >&2
        fi
        return 1
    elif [[ ! "$gpu_assignment" =~ ^[a-zA-Z0-9_,]+$ ]]; then
        "$error_func" "check_gpu_assignment: Invalid gpu_assignment format for container $lxc_id: $gpu_assignment (alphanumeric, comma, underscore only)"
        return 1
    else
        "$log_func" "check_gpu_assignment: GPU assignment found for container $lxc_id: $gpu_assignment"
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "GPU assignment found for container $lxc_id: $gpu_assignment" >&2
        fi
        echo "$gpu_assignment"
        return 0
    fi
}

# --- Systemd Service Management ---

# Create a systemd service file inside an LXC container
# Usage: create_systemd_service_in_container <container_id> <service_name> <service_content>
create_systemd_service_in_container() {
    local lxc_id="$1"
    local service_name="$2"
    local service_content="$3"
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE"; }
    fi
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE" >&2; return 1; }
    fi
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE" >&2; }
    fi
    if [[ -z "$lxc_id" || -z "$service_name" || -z "$service_content" ]]; then
        "$error_func" "create_systemd_service_in_container: Missing lxc_id, service_name, or service_content"
        return 1
    fi
    if [[ ! "$lxc_id" =~ ^[0-9]+$ ]]; then
        "$error_func" "create_systemd_service_in_container: Invalid lxc_id format: $lxc_id (must be numeric)"
        return 1
    fi
    if [[ ! "$service_name" =~ ^[a-zA-Z0-9_-]+\.service$ ]]; then
        "$error_func" "create_systemd_service_in_container: Invalid service_name format: $service_name (must be alphanumeric, hyphen, underscore, ending with .service)"
        return 1
    fi
    if [[ "$lxc_id" == "999" && "$service_name" == "docker.service" ]]; then
        "$log_func" "create_systemd_service_in_container: Container $lxc_id (Portainer server) does not require Docker service. Skipping."
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Skipping Docker service creation for container $lxc_id (Portainer server)." >&2
        fi
        return 0
    fi
    if [[ "$lxc_id" -ge 900 && "$lxc_id" -le 902 && "$service_name" == "docker.service" ]]; then
        "$warn_func" "create_systemd_service_in_container: Container $lxc_id (Portainer agent) may require Docker service for vLLM."
    fi
    local service_file_path="/etc/systemd/system/$service_name"
    "$log_func" "create_systemd_service_in_container: Creating systemd service '$service_name' in container $lxc_id at $service_file_path..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Creating systemd service '$service_name' in container $lxc_id..." >&2
    fi
    local create_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
mkdir -p /etc/systemd/system || { echo '[ERROR] Failed to create /etc/systemd/system'; exit 1; }
if [ -f '$service_file_path' ]; then
    cp '$service_file_path' '$service_file_path.bak' || echo '[WARN] Failed to backup $service_file_path' >>/tmp/systemd-$service_name-backup.log
fi
cat << 'EOF_SERVICE_CONTENT' > '$service_file_path'
$service_content
EOF_SERVICE_CONTENT
chmod 644 '$service_file_path' || { echo '[ERROR] Failed to set permissions on $service_file_path'; exit 1; }
if ! test -f '$service_file_path' || ! test -s '$service_file_path'; then
    echo '[ERROR] Service file not created or empty at $service_file_path'
    exit 1
fi
if ! grep -q '\\[Unit\\]' '$service_file_path' || ! grep -q '\\[Service\\]' '$service_file_path' || ! grep -q '\\[Install\\]' '$service_file_path'; then
    echo '[ERROR] Service file at $service_file_path is missing required sections'
    exit 1
fi
echo '[SUCCESS] Systemd service file created and verified successfully.' >/tmp/systemd-$service_name.log
"
    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "create_systemd_service_in_container: Attempting service creation (attempt $attempt/$max_attempts)..."
        if pct_exec_with_retry "$lxc_id" bash -c "$create_cmd" 2>>"$PHOENIX_SYSTEMD_LOG_FILE"; then
            "$log_func" "create_systemd_service_in_container: Systemd service '$service_name' created and verified successfully in container $lxc_id."
            if [[ "${QUIET_MODE:-false}" != "true" ]]; then
                echo "Systemd service '$service_name' created successfully in container $lxc_id." >&2
            fi
            return 0
        else
            "$warn_func" "create_systemd_service_in_container: Failed on attempt $attempt. Retrying in 5 seconds..."
            sleep 5
            ((attempt++))
        fi
    done
    "$error_func" "create_systemd_service_in_container: Failed to create systemd service '$service_name' in container $lxc_id after $max_attempts attempts."
    return 1
}

# Enable a systemd service inside an LXC container
# Usage: enable_systemd_service_in_container <container_id> <service_name>
enable_systemd_service_in_container() {
    local lxc_id="$1"
    local service_name="$2"
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE"; }
    fi
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE" >&2; return 1; }
    fi
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE" >&2; }
    fi
    if [[ -z "$lxc_id" || -z "$service_name" ]]; then
        "$error_func" "enable_systemd_service_in_container: Missing lxc_id or service_name"
        return 1
    fi
    if [[ ! "$lxc_id" =~ ^[0-9]+$ ]]; then
        "$error_func" "enable_systemd_service_in_container: Invalid lxc_id format: $lxc_id (must be numeric)"
        return 1
    fi
    if [[ ! "$service_name" =~ ^[a-zA-Z0-9_-]+\.service$ ]]; then
        "$error_func" "enable_systemd_service_in_container: Invalid service_name format: $service_name (must be alphanumeric, hyphen, underscore, ending with .service)"
        return 1
    fi
    if [[ "$lxc_id" == "999" && "$service_name" == "docker.service" ]]; then
        "$log_func" "enable_systemd_service_in_container: Skipping Docker service enablement for container $lxc_id (Portainer server)"
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Skipping Docker service enablement for container $lxc_id (Portainer server)." >&2
        fi
        return 0
    fi
    if [[ "$lxc_id" -ge 900 && "$lxc_id" -le 902 && "$service_name" == "docker.service" ]]; then
        "$warn_func" "enable_systemd_service_in_container: Container $lxc_id (Portainer agent) may require Docker service for vLLM."
    fi
    if [[ "$service_name" == "docker.service" ]] && ! check_gpu_assignment "$lxc_id"; then
        "$log_func" "enable_systemd_service_in_container: Skipping Docker service enablement for container $lxc_id (no GPU assignment)"
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Skipping Docker service enablement for container $lxc_id (no GPU assignment)." >&2
        fi
        return 0
    fi
    "$log_func" "enable_systemd_service_in_container: Enabling systemd service '$service_name' in container $lxc_id..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Enabling systemd service '$service_name' in container $lxc_id..." >&2
    fi
    local enable_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
touch /tmp/systemd-$service_name.log || { echo '[ERROR] Cannot create /tmp/systemd-$service_name.log'; exit 1; }
if ! command -v systemctl >/dev/null 2>&1 || ! systemctl is-system-running >/dev/null 2>&1; then
    echo '[WARN] Systemd not available in container.' >>/tmp/systemd-$service_name.log
    if [[ '$service_name' == 'docker.service' ]] && command -v dockerd >/dev/null 2>&1 && command -v containerd >/dev/null 2>&1; then
        echo '[INFO] Docker service detected, checking manual enablement...' >>/tmp/systemd-$service_name.log
        if pgrep -x dockerd >/dev/null 2>&1; then
            echo '[SUCCESS] Docker daemon already running, considered enabled.' >>/tmp/systemd-$service_name.log
            exit 0
        else
            echo '[INFO] Starting containerd and dockerd manually to enable...' >>/tmp/systemd-$service_name.log
            containerd >/tmp/systemd-containerd.log 2>&1 &
            sleep 2
            if ! pgrep -x containerd >/dev/null 2>&1; then
                echo '[ERROR] Failed to start containerd.' >>/tmp/systemd-$service_name.log
                cat /tmp/systemd-containerd.log >>/tmp/systemd-$service_name.log
                exit 1
            fi
            /usr/bin/dockerd -H unix:///var/run/docker.sock --containerd=/run/containerd/containerd.sock >/tmp/systemd-docker.log 2>&1 &
            sleep 5
            if pgrep -x dockerd >/dev/null 2>&1; then
                echo '[SUCCESS] Docker daemon started manually and enabled.' >>/tmp/systemd-$service_name.log
                exit 0
            else
                echo '[ERROR] Failed to start Docker daemon manually.' >>/tmp/systemd-$service_name.log
                cat /tmp/systemd-docker.log >>/tmp/systemd-$service_name.log
                exit 1
            fi
        fi
    else
        echo '[ERROR] Systemd not available and no fallback for service $service_name.' >>/tmp/systemd-$service_name.log
        exit 1
    fi
fi
if systemctl is-enabled --quiet '$service_name' 2>/dev/null; then
    echo '[INFO] Service $service_name already enabled.' >>/tmp/systemd-$service_name.log
    exit 0
fi
echo '[INFO] Enabling service...' >>/tmp/systemd-$service_name.log
timeout 30s systemctl enable '$service_name' >>/tmp/systemd-$service_name.log 2>&1 || { echo '[ERROR] Failed to enable service'; cat /tmp/systemd-$service_name.log; exit 1; }
echo '[SUCCESS] Service enabled successfully.' >>/tmp/systemd-$service_name.log
"
    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "enable_systemd_service_in_container: Attempting service enable (attempt $attempt/$max_attempts)..."
        if pct_exec_with_retry "$lxc_id" bash -c "$enable_cmd" 2>>"$PHOENIX_SYSTEMD_LOG_FILE"; then
            "$log_func" "enable_systemd_service_in_container: Systemd service '$service_name' enabled successfully in container $lxc_id."
            if [[ "${QUIET_MODE:-false}" != "true" ]]; then
                echo "Systemd service '$service_name' enabled successfully in container $lxc_id." >&2
            fi
            return 0
        else
            "$warn_func" "enable_systemd_service_in_container: Failed on attempt $attempt. Retrying in 5 seconds..."
            sleep 5
            ((attempt++))
        fi
    done
    "$error_func" "enable_systemd_service_in_container: Failed to enable systemd service '$service_name' in container $lxc_id after $max_attempts attempts."
    return 1
}

# Start a systemd service inside an LXC container
# Usage: start_systemd_service_in_container <container_id> <service_name>
start_systemd_service_in_container() {
    local lxc_id="$1"
    local service_name="$2"
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE"; }
    fi
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE" >&2; return 1; }
    fi
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE" >&2; }
    fi
    if [[ -z "$lxc_id" || -z "$service_name" ]]; then
        "$error_func" "start_systemd_service_in_container: Missing lxc_id or service_name"
        return 1
    fi
    if [[ ! "$lxc_id" =~ ^[0-9]+$ ]]; then
        "$error_func" "start_systemd_service_in_container: Invalid lxc_id format: $lxc_id (must be numeric)"
        return 1
    fi
    if [[ ! "$service_name" =~ ^[a-zA-Z0-9_-]+\.service$ ]]; then
        "$error_func" "start_systemd_service_in_container: Invalid service_name format: $service_name (must be alphanumeric, hyphen, underscore, ending with .service)"
        return 1
    fi
    if [[ "$lxc_id" == "999" && "$service_name" == "docker.service" ]]; then
        "$log_func" "start_systemd_service_in_container: Skipping Docker service start for container $lxc_id (Portainer server)"
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Skipping Docker service start for container $lxc_id (Portainer server)." >&2
        fi
        return 0
    fi
    if [[ "$lxc_id" -ge 900 && "$lxc_id" -le 902 && "$service_name" == "docker.service" ]]; then
        "$warn_func" "start_systemd_service_in_container: Container $lxc_id (Portainer agent) may require Docker service for vLLM."
    fi
    if [[ "$service_name" == "docker.service" ]] && ! check_gpu_assignment "$lxc_id"; then
        "$log_func" "start_systemd_service_in_container: Skipping Docker service start for container $lxc_id (no GPU assignment)"
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Skipping Docker service start for container $lxc_id (no GPU assignment)." >&2
        fi
        return 0
    fi
    "$log_func" "start_systemd_service_in_container: Starting systemd service '$service_name' in container $lxc_id..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Starting systemd service '$service_name' in container $lxc_id..." >&2
    fi
    local start_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
touch /tmp/systemd-$service_name.log || { echo '[ERROR] Cannot create /tmp/systemd-$service_name.log'; exit 1; }
if ! command -v systemctl >/dev/null 2>&1 || ! systemctl is-system-running >/dev/null 2>&1; then
    echo '[WARN] Systemd not available in container.' >>/tmp/systemd-$service_name.log
    if [[ '$service_name' == 'docker.service' ]] && command -v dockerd >/dev/null 2>&1 && command -v containerd >/dev/null 2>&1; then
        echo '[INFO] Docker service detected, checking manual start...' >>/tmp/systemd-$service_name.log
        if pgrep -x dockerd >/dev/null 2>&1; then
            echo '[SUCCESS] Docker daemon already running.' >>/tmp/systemd-$service_name.log
            exit 0
        else
            echo '[INFO] Starting containerd and dockerd manually...' >>/tmp/systemd-$service_name.log
            containerd >/tmp/systemd-containerd.log 2>&1 &
            sleep 2
            if ! pgrep -x containerd >/dev/null 2>&1; then
                echo '[ERROR] Failed to start containerd.' >>/tmp/systemd-$service_name.log
                cat /tmp/systemd-containerd.log >>/tmp/systemd-$service_name.log
                exit 1
            fi
            /usr/bin/dockerd -H unix:///var/run/docker.sock --containerd=/run/containerd/containerd.sock >/tmp/systemd-docker.log 2>&1 &
            sleep 5
            if pgrep -x dockerd >/dev/null 2>&1; then
                echo '[SUCCESS] Docker daemon started manually.' >>/tmp/systemd-$service_name.log
                exit 0
            else
                echo '[ERROR] Failed to start Docker daemon manually.' >>/tmp/systemd-$service_name.log
                cat /tmp/systemd-docker.log >>/tmp/systemd-$service_name.log
                exit 1
            fi
        fi
    else
        echo '[ERROR] Systemd not available and no fallback for service $service_name.' >>/tmp/systemd-$service_name.log
        exit 1
    fi
fi
if systemctl is-active --quiet '$service_name' 2>/dev/null; then
    echo '[INFO] Service $service_name already running.' >>/tmp/systemd-$service_name.log
    exit 0
fi
echo '[INFO] Starting service...' >>/tmp/systemd-$service_name.log
timeout 30s systemctl start '$service_name' >>/tmp/systemd-$service_name.log 2>&1 || { echo '[ERROR] Failed to start service'; cat /tmp/systemd-$service_name.log; exit 1; }
echo '[SUCCESS] Service started successfully.' >>/tmp/systemd-$service_name.log
"
    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "start_systemd_service_in_container: Attempting service start (attempt $attempt/$max_attempts)..."
        if pct_exec_with_retry "$lxc_id" bash -c "$start_cmd" 2>>"$PHOENIX_SYSTEMD_LOG_FILE"; then
            "$log_func" "start_systemd_service_in_container: Systemd service '$service_name' started successfully in container $lxc_id."
            if [[ "${QUIET_MODE:-false}" != "true" ]]; then
                echo "Systemd service '$service_name' started successfully in container $lxc_id." >&2
            fi
            return 0
        else
            "$warn_func" "start_systemd_service_in_container: Failed on attempt $attempt. Retrying in 5 seconds..."
            sleep 5
            ((attempt++))
        fi
    done
    "$error_func" "start_systemd_service_in_container: Failed to start systemd service '$service_name' in container $lxc_id after $max_attempts attempts."
    return 1
}

# Stop a systemd service inside an LXC container
# Usage: stop_systemd_service_in_container <container_id> <service_name>
stop_systemd_service_in_container() {
    local lxc_id="$1"
    local service_name="$2"
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE"; }
    fi
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE" >&2; return 1; }
    fi
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE" >&2; }
    fi
    if [[ -z "$lxc_id" || -z "$service_name" ]]; then
        "$error_func" "stop_systemd_service_in_container: Missing lxc_id or service_name"
        return 1
    fi
    if [[ ! "$lxc_id" =~ ^[0-9]+$ ]]; then
        "$error_func" "stop_systemd_service_in_container: Invalid lxc_id format: $lxc_id (must be numeric)"
        return 1
    fi
    if [[ ! "$service_name" =~ ^[a-zA-Z0-9_-]+\.service$ ]]; then
        "$error_func" "stop_systemd_service_in_container: Invalid service_name format: $service_name (must be alphanumeric, hyphen, underscore, ending with .service)"
        return 1
    fi
    if [[ "$lxc_id" == "999" && "$service_name" == "docker.service" ]]; then
        "$log_func" "stop_systemd_service_in_container: Skipping Docker service stop for container $lxc_id (Portainer server)"
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Skipping Docker service stop for container $lxc_id (Portainer server)." >&2
        fi
        return 0
    fi
    if [[ "$lxc_id" -ge 900 && "$lxc_id" -le 902 && "$service_name" == "docker.service" ]]; then
        "$warn_func" "stop_systemd_service_in_container: Container $lxc_id (Portainer agent) may require Docker service for vLLM."
    fi
    if [[ "$service_name" == "docker.service" ]] && ! check_gpu_assignment "$lxc_id"; then
        "$log_func" "stop_systemd_service_in_container: Skipping Docker service stop for container $lxc_id (no GPU assignment)"
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Skipping Docker service stop for container $lxc_id (no GPU assignment)." >&2
        fi
        return 0
    fi
    "$log_func" "stop_systemd_service_in_container: Stopping systemd service '$service_name' in container $lxc_id..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Stopping systemd service '$service_name' in container $lxc_id..." >&2
    fi
    local stop_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
touch /tmp/systemd-$service_name.log || { echo '[ERROR] Cannot create /tmp/systemd-$service_name.log'; exit 1; }
if ! command -v systemctl >/dev/null 2>&1 || ! systemctl is-system-running >/dev/null 2>&1; then
    echo '[WARN] Systemd not available in container.' >>/tmp/systemd-$service_name.log
    if [[ '$service_name' == 'docker.service' ]] && command -v dockerd >/dev/null 2>&1; then
        echo '[INFO] Docker service detected, checking manual stop...' >>/tmp/systemd-$service_name.log
        if pgrep -x dockerd >/dev/null 2>&1; then
            echo '[INFO] Stopping dockerd manually...' >>/tmp/systemd-$service_name.log
            pkill -x dockerd || { echo '[WARN] Failed to stop Docker daemon manually' >>/tmp/systemd-$service_name.log; exit 0; }
            sleep 2
            if ! pgrep -x dockerd >/dev/null 2>&1; then
                echo '[SUCCESS] Docker daemon stopped manually.' >>/tmp/systemd-$service_name.log
                exit 0
            else
                echo '[ERROR] Failed to stop Docker daemon manually.' >>/tmp/systemd-$service_name.log
                exit 1
            fi
        else
            echo '[SUCCESS] Docker daemon not running, considered stopped.' >>/tmp/systemd-$service_name.log
            exit 0
        fi
    else
        echo '[ERROR] Systemd not available and no fallback for service $service_name.' >>/tmp/systemd-$service_name.log
        exit 1
    fi
fi
if ! systemctl is-active --quiet '$service_name' 2>/dev/null; then
    echo '[INFO] Service $service_name not running, considered stopped.' >>/tmp/systemd-$service_name.log
    exit 0
fi
echo '[INFO] Stopping service...' >>/tmp/systemd-$service_name.log
timeout 30s systemctl stop '$service_name' >>/tmp/systemd-$service_name.log 2>&1 || { echo '[WARN] Failed to stop service (might not be running)' >>/tmp/systemd-$service_name.log; exit 0; }
echo '[SUCCESS] Service stopped successfully.' >>/tmp/systemd-$service_name.log
"
    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "stop_systemd_service_in_container: Attempting service stop (attempt $attempt/$max_attempts)..."
        if pct_exec_with_retry "$lxc_id" bash -c "$stop_cmd" 2>>"$PHOENIX_SYSTEMD_LOG_FILE"; then
            "$log_func" "stop_systemd_service_in_container: Systemd service '$service_name' stopped successfully in container $lxc_id."
            if [[ "${QUIET_MODE:-false}" != "true" ]]; then
                echo "Systemd service '$service_name' stopped successfully in container $lxc_id." >&2
            fi
            return 0
        else
            "$warn_func" "stop_systemd_service_in_container: Failed on attempt $attempt. Retrying in 5 seconds..."
            sleep 5
            ((attempt++))
        fi
    done
    "$warn_func" "stop_systemd_service_in_container: Failed to stop systemd service '$service_name' in container $lxc_id after $max_attempts attempts. It might not have been running."
    return 0
}

# Restart a systemd service inside an LXC container
# Usage: restart_systemd_service_in_container <container_id> <service_name>
restart_systemd_service_in_container() {
    local lxc_id="$1"
    local service_name="$2"
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE"; }
    fi
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE" >&2; return 1; }
    fi
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE" >&2; }
    fi
    if [[ -z "$lxc_id" || -z "$service_name" ]]; then
        "$error_func" "restart_systemd_service_in_container: Missing lxc_id or service_name"
        return 1
    fi
    if [[ ! "$lxc_id" =~ ^[0-9]+$ ]]; then
        "$error_func" "restart_systemd_service_in_container: Invalid lxc_id format: $lxc_id (must be numeric)"
        return 1
    fi
    if [[ ! "$service_name" =~ ^[a-zA-Z0-9_-]+\.service$ ]]; then
        "$error_func" "restart_systemd_service_in_container: Invalid service_name format: $service_name (must be alphanumeric, hyphen, underscore, ending with .service)"
        return 1
    fi
    if [[ "$lxc_id" == "999" && "$service_name" == "docker.service" ]]; then
        "$log_func" "restart_systemd_service_in_container: Skipping Docker service restart for container $lxc_id (Portainer server)"
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Skipping Docker service restart for container $lxc_id (Portainer server)." >&2
        fi
        return 0
    fi
    if [[ "$lxc_id" -ge 900 && "$lxc_id" -le 902 && "$service_name" == "docker.service" ]]; then
        "$warn_func" "restart_systemd_service_in_container: Container $lxc_id (Portainer agent) may require Docker service for vLLM."
    fi
    if [[ "$service_name" == "docker.service" ]] && ! check_gpu_assignment "$lxc_id"; then
        "$log_func" "restart_systemd_service_in_container: Skipping Docker service restart for container $lxc_id (no GPU assignment)"
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Skipping Docker service restart for container $lxc_id (no GPU assignment)." >&2
        fi
        return 0
    fi
    "$log_func" "restart_systemd_service_in_container: Restarting systemd service '$service_name' in container $lxc_id..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Restarting systemd service '$service_name' in container $lxc_id..." >&2
    fi
    local restart_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
touch /tmp/systemd-$service_name.log || { echo '[ERROR] Cannot create /tmp/systemd-$service_name.log'; exit 1; }
if ! command -v systemctl >/dev/null 2>&1 || ! systemctl is-system-running >/dev/null 2>&1; then
    echo '[WARN] Systemd not available in container.' >>/tmp/systemd-$service_name.log
    if [[ '$service_name' == 'docker.service' ]] && command -v dockerd >/dev/null 2>&1 && command -v containerd >/dev/null 2>&1; then
        echo '[INFO] Docker service detected, checking manual restart...' >>/tmp/systemd-$service_name.log
        if pgrep -x dockerd >/dev/null 2>&1; then
            echo '[INFO] Stopping dockerd manually...' >>/tmp/systemd-$service_name.log
            pkill -x dockerd || { echo '[ERROR] Failed to stop Docker daemon manually' >>/tmp/systemd-$service_name.log; exit 1; }
            sleep 2
        fi
        echo '[INFO] Starting containerd and dockerd manually...' >>/tmp/systemd-$service_name.log
        containerd >/tmp/systemd-containerd.log 2>&1 &
        sleep 2
        if ! pgrep -x containerd >/dev/null 2>&1; then
            echo '[ERROR] Failed to start containerd.' >>/tmp/systemd-$service_name.log
            cat /tmp/systemd-containerd.log >>/tmp/systemd-$service_name.log
            exit 1
        fi
        /usr/bin/dockerd -H unix:///var/run/docker.sock --containerd=/run/containerd/containerd.sock >/tmp/systemd-docker.log 2>&1 &
        sleep 5
        if pgrep -x dockerd >/dev/null 2>&1; then
            echo '[SUCCESS] Docker daemon restarted manually.' >>/tmp/systemd-$service_name.log
            exit 0
        else
            echo '[ERROR] Failed to restart Docker daemon manually.' >>/tmp/systemd-$service_name.log
            cat /tmp/systemd-docker.log >>/tmp/systemd-$service_name.log
            exit 1
        fi
    else
        echo '[ERROR] Systemd not available and no fallback for service $service_name.' >>/tmp/systemd-$service_name.log
        exit 1
    fi
fi
echo '[INFO] Restarting service...' >>/tmp/systemd-$service_name.log
timeout 30s systemctl restart '$service_name' >>/tmp/systemd-$service_name.log 2>&1 || { echo '[ERROR] Failed to restart service' >>/tmp/systemd-$service_name.log; cat /tmp/systemd-$service_name.log; exit 1; }
echo '[SUCCESS] Service restarted successfully.' >>/tmp/systemd-$service_name.log
"
    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "restart_systemd_service_in_container: Attempting service restart (attempt $attempt/$max_attempts)..."
        if pct_exec_with_retry "$lxc_id" bash -c "$restart_cmd" 2>>"$PHOENIX_SYSTEMD_LOG_FILE"; then
            "$log_func" "restart_systemd_service_in_container: Systemd service '$service_name' restarted successfully in container $lxc_id."
            if [[ "${QUIET_MODE:-false}" != "true" ]]; then
                echo "Systemd service '$service_name' restarted successfully in container $lxc_id." >&2
            fi
            return 0
        else
            "$warn_func" "restart_systemd_service_in_container: Failed on attempt $attempt. Retrying in 5 seconds..."
            sleep 5
            ((attempt++))
        fi
    done
    "$error_func" "restart_systemd_service_in_container: Failed to restart systemd service '$service_name' in container $lxc_id after $max_attempts attempts."
    return 1
}

# Check the status of a systemd service inside an LXC container
# Usage: check_systemd_service_status_in_container <container_id> <service_name>
# Returns 0 if active, 1 if inactive/failed, 2 if not found/other error
check_systemd_service_status_in_container() {
    local lxc_id="$1"
    local service_name="$2"
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE"; }
    fi
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE" >&2; return 1; }
    fi
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE" >&2; }
    fi
    if [[ -z "$lxc_id" || -z "$service_name" ]]; then
        "$error_func" "check_systemd_service_status_in_container: Missing lxc_id or service_name"
        return 2
    fi
    if [[ ! "$lxc_id" =~ ^[0-9]+$ ]]; then
        "$error_func" "check_systemd_service_status_in_container: Invalid lxc_id format: $lxc_id (must be numeric)"
        return 2
    fi
    if [[ ! "$service_name" =~ ^[a-zA-Z0-9_-]+\.service$ ]]; then
        "$error_func" "check_systemd_service_status_in_container: Invalid service_name format: $service_name (must be alphanumeric, hyphen, underscore, ending with .service)"
        return 2
    fi
    if [[ "$lxc_id" == "999" && "$service_name" == "docker.service" ]]; then
        "$log_func" "check_systemd_service_status_in_container: Skipping Docker service status check for container $lxc_id (Portainer server)"
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Skipping Docker service status check for container $lxc_id (Portainer server)." >&2
        fi
        echo "not-found"
        return 2
    fi
    if [[ "$lxc_id" -ge 900 && "$lxc_id" -le 902 && "$service_name" == "docker.service" ]]; then
        "$warn_func" "check_systemd_service_status_in_container: Container $lxc_id (Portainer agent) may require Docker service for vLLM."
    fi
    if [[ "$service_name" == "docker.service" ]] && ! check_gpu_assignment "$lxc_id"; then
        "$log_func" "check_systemd_service_status_in_container: Skipping Docker service status check for container $lxc_id (no GPU assignment)"
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Skipping Docker service status check for container $lxc_id (no GPU assignment)." >&2
        fi
        echo "not-found"
        return 2
    fi
    "$log_func" "check_systemd_service_status_in_container: Checking status of systemd service '$service_name' in container $lxc_id..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Checking status of systemd service '$service_name' in container $lxc_id..." >&2
    fi
    local status_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
touch /tmp/systemd-$service_name.log || { echo '[ERROR] Cannot create /tmp/systemd-$service_name.log'; exit 1; }
if ! command -v systemctl >/dev/null 2>&1 || ! systemctl is-system-running >/dev/null 2>&1; then
    echo '[WARN] Systemd not available in container.' >>/tmp/systemd-$service_name.log
    if [[ '$service_name' == 'docker.service' ]] && command -v dockerd >/dev/null 2>&1 && command -v containerd >/dev/null 2>&1; then
        echo '[INFO] Docker service detected, checking manual status...' >>/tmp/systemd-$service_name.log
        if pgrep -x dockerd >/dev/null 2>&1; then
            echo '[STATUS] active' >>/tmp/systemd-$service_name.log
            echo '[INFO] Docker daemon running, details: $(ps -C dockerd -o pid,cmd)' >>/tmp/systemd-$service_name.log
            exit 0
        else
            echo '[STATUS] inactive' >>/tmp/systemd-$service_name.log
            echo '[INFO] Docker daemon not running.' >>/tmp/systemd-$service_name.log
            exit 1
        fi
    else
        echo '[ERROR] Systemd not available and no fallback for service $service_name.' >>/tmp/systemd-$service_name.log
        exit 2
    fi
fi
timeout 30s systemctl status '$service_name' >>/tmp/systemd-$service_name.log 2>&1 || true
if systemctl is-active --quiet '$service_name'; then
    echo '[STATUS] active' >>/tmp/systemd-$service_name.log
    echo '[INFO] Service status details: $(cat /tmp/systemd-$service_name.log | head -n 10)' >>/tmp/systemd-$service_name.log
    exit 0
elif systemctl is-failed --quiet '$service_name' 2>/dev/null; then
    echo '[STATUS] failed' >>/tmp/systemd-$service_name.log
    echo '[INFO] Service status details: $(cat /tmp/systemd-$service_name.log | head -n 10)' >>/tmp/systemd-$service_name.log
    exit 1
elif systemctl list-units --full --all | grep -q '$service_name'; then
    echo '[STATUS] inactive' >>/tmp/systemd-$service_name.log
    echo '[INFO] Service status details: $(cat /tmp/systemd-$service_name.log | head -n 10)' >>/tmp/systemd-$service_name.log
    exit 1
else
    echo '[STATUS] not-found' >>/tmp/systemd-$service_name.log
    echo '[INFO] Service not found.' >>/tmp/systemd-$service_name.log
    exit 2
fi
"
    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "check_systemd_service_status_in_container: Attempting status check (attempt $attempt/$max_attempts)..."
        local output
        local exit_code
        output=$(pct_exec_with_retry "$lxc_id" bash -c "$status_cmd" 2>>"$PHOENIX_SYSTEMD_LOG_FILE") || exit_code=$?
        exit_code=${exit_code:-0}
        case $exit_code in
            0)
                "$log_func" "check_systemd_service_status_in_container: Service '$service_name' is active in container $lxc_id. Output: $output"
                if [[ "${QUIET_MODE:-false}" != "true" ]]; then
                    echo "Service '$service_name' is active in container $lxc_id." >&2
                fi
                echo "active"
                return 0
                ;;
            1)
                if [[ "$output" == *"[STATUS] failed"* ]]; then
                    "$warn_func" "check_systemd_service_status_in_container: Service '$service_name' is failed in container $lxc_id. Output: $output"
                    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
                        echo "Service '$service_name' is failed in container $lxc_id." >&2
                    fi
                    echo "failed"
                else
                    "$log_func" "check_systemd_service_status_in_container: Service '$service_name' is inactive in container $lxc_id. Output: $output"
                    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
                        echo "Service '$service_name' is inactive in container $lxc_id." >&2
                    fi
                    echo "inactive"
                fi
                return 1
                ;;
            2)
                "$warn_func" "check_systemd_service_status_in_container: Service '$service_name' not found in container $lxc_id. Output: $output"
                if [[ "${QUIET_MODE:-false}" != "true" ]]; then
                    echo "Service '$service_name' not found in container $lxc_id." >&2
                fi
                echo "not-found"
                return 2
                ;;
            *)
                "$warn_func" "check_systemd_service_status_in_container: Failed to check status of service '$service_name' in container $lxc_id on attempt $attempt. Exit code: $exit_code. Output: $output"
                sleep 5
                ((attempt++))
                if [[ $attempt -gt $max_attempts ]]; then
                    "$error_func" "check_systemd_service_status_in_container: Failed after $max_attempts attempts."
                    echo "error"
                    return 2
                fi
                ;;
        esac
    done
}

# Reload the systemd daemon inside an LXC container
# Usage: reload_systemd_daemon_in_container <container_id>
reload_systemd_daemon_in_container() {
    local lxc_id="$1"
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE"; }
    fi
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE" >&2; return 1; }
    fi
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" | tee -a "$PHOENIX_SYSTEMD_LOG_FILE" >&2; }
    fi
    if [[ -z "$lxc_id" ]]; then
        "$error_func" "reload_systemd_daemon_in_container: Missing lxc_id"
        return 1
    fi
    if [[ ! "$lxc_id" =~ ^[0-9]+$ ]]; then
        "$error_func" "reload_systemd_daemon_in_container: Invalid lxc_id format: $lxc_id (must be numeric)"
        return 1
    fi
    if [[ "$lxc_id" == "999" ]]; then
        "$log_func" "reload_systemd_daemon_in_container: Skipping systemd daemon reload for container $lxc_id (Portainer server)"
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Skipping systemd daemon reload for container $lxc_id (Portainer server)." >&2
        fi
        return 0
    fi
    if [[ "$lxc_id" -ge 900 && "$lxc_id" -le 902 ]]; then
        "$warn_func" "reload_systemd_daemon_in_container: Container $lxc_id (Portainer agent) may require systemd daemon reload for vLLM."
    fi
    "$log_func" "reload_systemd_daemon_in_container: Reloading systemd daemon in container $lxc_id..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Reloading systemd daemon in container $lxc_id..." >&2
    fi
    local reload_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
touch /tmp/systemd-daemon-reload.log || { echo '[ERROR] Cannot create /tmp/systemd-daemon-reload.log'; exit 1; }
if ! command -v systemctl >/dev/null 2>&1 || ! systemctl is-system-running >/dev/null 2>&1; then
    echo '[WARN] Systemd not available in container, skipping daemon-reload.' >>/tmp/systemd-daemon-reload.log
    exit 0
fi
echo '[INFO] Reloading systemd daemon...' >>/tmp/systemd-daemon-reload.log
timeout 30s systemctl daemon-reload >>/tmp/systemd-daemon-reload.log 2>&1 || { echo '[ERROR] Failed to reload systemd daemon' >>/tmp/systemd-daemon-reload.log; cat /tmp/systemd-daemon-reload.log; exit 1; }
echo '[SUCCESS] Systemd daemon reloaded successfully.' >>/tmp/systemd-daemon-reload.log
"
    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "reload_systemd_daemon_in_container: Attempting daemon reload (attempt $attempt/$max_attempts)..."
        if pct_exec_with_retry "$lxc_id" bash -c "$reload_cmd" 2>>"$PHOENIX_SYSTEMD_LOG_FILE"; then
            "$log_func" "reload_systemd_daemon_in_container: Systemd daemon reloaded successfully in container $lxc_id."
            if [[ "${QUIET_MODE:-false}" != "true" ]]; then
                echo "Systemd daemon reloaded successfully in container $lxc_id." >&2
            fi
            return 0
        else
            "$warn_func" "reload_systemd_daemon_in_container: Failed on attempt $attempt. Retrying in 5 seconds..."
            sleep 5
            ((attempt++))
        fi
    done
    "$error_func" "reload_systemd_daemon_in_container: Failed to reload systemd daemon in container $lxc_id after $max_attempts attempts."
    return 1
}

# Signal that this library has been loaded
export PHOENIX_HYPERVISOR_LXC_COMMON_SYSTEMD_LOADED=1
if declare -F log_info >/dev/null 2>&1; then
    log_info "phoenix_hypervisor_lxc_common_systemd.sh: Library loaded successfully."
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] phoenix_hypervisor_lxc_common_systemd.sh: Library loaded successfully." | tee -a "$PHOENIX_SYSTEMD_LOG_FILE"
fi