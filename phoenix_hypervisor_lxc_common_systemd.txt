#!/usr/bin/env bash

# phoenix_hypervisor_lxc_common_systemd.sh
#
# Common functions for managing systemd services inside LXC containers.
# This script is intended to be sourced by other Phoenix Hypervisor scripts.
# Requires: pct, bash
# Assumes: phoenix_hypervisor_common.sh is sourced for logging (fallbacks included)

# --- Systemd Service Management ---

# Create a systemd service file inside an LXC container
# Usage: create_systemd_service_in_container <container_id> <service_name> <service_content>
#   service_content: A string containing the full service file content (e.g., '[Unit]...\n[Service]...\n[Install]...')
create_systemd_service_in_container() {
    local lxc_id="$1"
    local service_name="$2"
    local service_content="$3" # Expecting a multi-line string

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

    if [[ -z "$lxc_id" ]] || [[ -z "$service_name" ]] || [[ -z "$service_content" ]]; then
        "$error_func" "create_systemd_service_in_container: Missing lxc_id, service_name, or service_content"
        return 1
    fi

    local service_file_path="/etc/systemd/system/${service_name}.service"

    "$log_func" "create_systemd_service_in_container: Creating systemd service '$service_name' in container $lxc_id at $service_file_path..."

    # Use pct_exec_with_retry if available (from base common lib), otherwise direct exec
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    # Command to create the service file inside the container
    # Using 'cat' with a heredoc to write multi-line content
    local create_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
# Ensure systemd directory exists
mkdir -p /etc/systemd/system
# Write service content using cat and heredoc
cat << 'EOF_SERVICE_CONTENT' > '$service_file_path'
$service_content
EOF_SERVICE_CONTENT
# Set appropriate permissions
chmod 644 '$service_file_path'
echo '[SUCCESS] Systemd service file created successfully.'
"

    if "$exec_func" "$lxc_id" -- bash -c "$create_cmd"; then
        "$log_func" "create_systemd_service_in_container: Systemd service '$service_name' created successfully in container $lxc_id."
        return 0
    else
        "$error_func" "create_systemd_service_in_container: Failed to create systemd service '$service_name' in container $lxc_id."
        return 1
    fi
}

# Enable a systemd service inside an LXC container
# Usage: enable_systemd_service_in_container <container_id> <service_name>
enable_systemd_service_in_container() {
    local lxc_id="$1"
    local service_name="$2"

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

    if [[ -z "$lxc_id" ]] || [[ -z "$service_name" ]]; then
        "$error_func" "enable_systemd_service_in_container: Missing lxc_id or service_name"
        return 1
    fi

    "$log_func" "enable_systemd_service_in_container: Enabling systemd service '$service_name' in container $lxc_id..."

    # Use pct_exec_with_retry if available (from base common lib), otherwise direct exec
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    local enable_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if ! command -v systemctl >/dev/null 2>&1; then
    echo '[ERROR] systemctl not found in container.'
    exit 1
fi
echo '[INFO] Enabling service...'
systemctl enable '$service_name' || { echo '[ERROR] Failed to enable service'; exit 1; }
echo '[SUCCESS] Service enabled successfully.'
"

    if "$exec_func" "$lxc_id" -- bash -c "$enable_cmd"; then
        "$log_func" "enable_systemd_service_in_container: Systemd service '$service_name' enabled successfully in container $lxc_id."
        return 0
    else
        "$error_func" "enable_systemd_service_in_container: Failed to enable systemd service '$service_name' in container $lxc_id."
        return 1
    fi
}

# Start a systemd service inside an LXC container
# Usage: start_systemd_service_in_container <container_id> <service_name>
start_systemd_service_in_container() {
    local lxc_id="$1"
    local service_name="$2"

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

    if [[ -z "$lxc_id" ]] || [[ -z "$service_name" ]]; then
        "$error_func" "start_systemd_service_in_container: Missing lxc_id or service_name"
        return 1
    fi

    "$log_func" "start_systemd_service_in_container: Starting systemd service '$service_name' in container $lxc_id..."

    # Use pct_exec_with_retry if available (from base common lib), otherwise direct exec
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    local start_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if ! command -v systemctl >/dev/null 2>&1; then
    echo '[ERROR] systemctl not found in container.'
    exit 1
fi
echo '[INFO] Starting service...'
systemctl start '$service_name' || { echo '[ERROR] Failed to start service'; exit 1; }
echo '[SUCCESS] Service started successfully.'
"

    if "$exec_func" "$lxc_id" -- bash -c "$start_cmd"; then
        "$log_func" "start_systemd_service_in_container: Systemd service '$service_name' started successfully in container $lxc_id."
        return 0
    else
        "$error_func" "start_systemd_service_in_container: Failed to start systemd service '$service_name' in container $lxc_id."
        return 1
    fi
}

# Stop a systemd service inside an LXC container
# Usage: stop_systemd_service_in_container <container_id> <service_name>
stop_systemd_service_in_container() {
    local lxc_id="$1"
    local service_name="$2"

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    fi

    # Use log_warn if available, otherwise fallback (stopping might fail if not running)
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" >&2; }
    fi

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    if [[ -z "$lxc_id" ]] || [[ -z "$service_name" ]]; then
        "$error_func" "stop_systemd_service_in_container: Missing lxc_id or service_name"
        return 1
    fi

    "$log_func" "stop_systemd_service_in_container: Stopping systemd service '$service_name' in container $lxc_id..."

    # Use pct_exec_with_retry if available (from base common lib), otherwise direct exec
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    local stop_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if ! command -v systemctl >/dev/null 2>&1; then
    echo '[ERROR] systemctl not found in container.'
    exit 1
fi
echo '[INFO] Stopping service...'
systemctl stop '$service_name' || { echo '[WARN] Failed to stop service (might not be running)'; exit 0; }
echo '[SUCCESS] Service stopped successfully.'
"

    if "$exec_func" "$lxc_id" -- bash -c "$stop_cmd"; then
        "$log_func" "stop_systemd_service_in_container: Systemd service '$service_name' stopped successfully in container $lxc_id."
        return 0
    else
        "$warn_func" "stop_systemd_service_in_container: Attempt to stop systemd service '$service_name' in container $lxc_id returned non-zero exit code. It might not have been running or failed to stop."
        # Not returning error code as stopping a non-running service is often not an error
        return 0
    fi
}

# Restart a systemd service inside an LXC container
# Usage: restart_systemd_service_in_container <container_id> <service_name>
restart_systemd_service_in_container() {
    local lxc_id="$1"
    local service_name="$2"

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

    if [[ -z "$lxc_id" ]] || [[ -z "$service_name" ]]; then
        "$error_func" "restart_systemd_service_in_container: Missing lxc_id or service_name"
        return 1
    fi

    "$log_func" "restart_systemd_service_in_container: Restarting systemd service '$service_name' in container $lxc_id..."

     # Use pct_exec_with_retry if available (from base common lib), otherwise direct exec
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    local restart_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if ! command -v systemctl >/dev/null 2>&1; then
    echo '[ERROR] systemctl not found in container.'
    exit 1
fi
echo '[INFO] Restarting service...'
systemctl restart '$service_name' || { echo '[ERROR] Failed to restart service'; exit 1; }
echo '[SUCCESS] Service restarted successfully.'
"

    if "$exec_func" "$lxc_id" -- bash -c "$restart_cmd"; then
        "$log_func" "restart_systemd_service_in_container: Systemd service '$service_name' restarted successfully in container $lxc_id."
        return 0
    else
        "$error_func" "restart_systemd_service_in_container: Failed to restart systemd service '$service_name' in container $lxc_id."
        return 1
    fi
}

# Check the status of a systemd service inside an LXC container
# Usage: check_systemd_service_status_in_container <container_id> <service_name>
# Returns 0 if active, 1 if inactive, 2 if not found/other error
check_systemd_service_status_in_container() {
    local lxc_id="$1"
    local service_name="$2"

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

    if [[ -z "$lxc_id" ]] || [[ -z "$service_name" ]]; then
        "$error_func" "check_systemd_service_status_in_container: Missing lxc_id or service_name"
        return 2 # Invalid arguments
    fi

    "$log_func" "check_systemd_service_status_in_container: Checking status of systemd service '$service_name' in container $lxc_id..."

    # Use pct_exec_with_retry if available (from base common lib), otherwise direct exec
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    local status_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if ! command -v systemctl >/dev/null 2>&1; then
    echo '[ERROR] systemctl not found in container.'
    exit 2
fi
# Use systemctl is-active which returns specific exit codes
# 0: active, 1: inactive (or failed), 3: unknown unit
if systemctl is-active --quiet '$service_name'; then
    echo '[STATUS] active'
    exit 0
elif systemctl is-failed --quiet '$service_name' 2>/dev/null; then
    echo '[STATUS] failed'
    exit 1
elif systemctl list-units --full --all | grep -q '$service_name'\.service; then
    echo '[STATUS] inactive'
    exit 1
else
    echo '[STATUS] not-found'
    exit 3
fi
"

    # Capture output and exit code
    local output
    local exit_code
    output=$("$exec_func" "$lxc_id" -- bash -c "$status_cmd" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0} # If command succeeded, exit_code might not be set

    case $exit_code in
        0)
            "$log_func" "check_systemd_service_status_in_container: Service '$service_name' is active in container $lxc_id."
            echo "active"
            return 0
            ;;
        1)
            if [[ "$output" == *"[STATUS] failed"* ]]; then
                "$warn_func" "check_systemd_service_status_in_container: Service '$service_name' is failed in container $lxc_id."
                echo "failed"
            else
                "$log_func" "check_systemd_service_status_in_container: Service '$service_name' is inactive in container $lxc_id."
                echo "inactive"
            fi
            return 1
            ;;
        3)
            "$warn_func" "check_systemd_service_status_in_container: Service '$service_name' not found in container $lxc_id."
            echo "not-found"
            return 2
            ;;
        *)
            "$error_func" "check_systemd_service_status_in_container: Failed to check status of service '$service_name' in container $lxc_id. Exit code: $exit_code. Output: $output"
            echo "error"
            return 2
            ;;
    esac
}

# Reload the systemd daemon inside an LXC container
# Usage: reload_systemd_daemon_in_container <container_id>
reload_systemd_daemon_in_container() {
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
        "$error_func" "reload_systemd_daemon_in_container: Missing lxc_id"
        return 1
    fi

    "$log_func" "reload_systemd_daemon_in_container: Reloading systemd daemon in container $lxc_id..."

    # Use pct_exec_with_retry if available (from base common lib), otherwise direct exec
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    local reload_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if ! command -v systemctl >/dev/null 2>&1; then
    echo '[ERROR] systemctl not found in container.'
    exit 1
fi
echo '[INFO] Reloading systemd daemon...'
systemctl daemon-reload || { echo '[ERROR] Failed to reload systemd daemon'; exit 1; }
echo '[SUCCESS] Systemd daemon reloaded successfully.'
"

    if "$exec_func" "$lxc_id" -- bash -c "$reload_cmd"; then
        "$log_func" "reload_systemd_daemon_in_container: Systemd daemon reloaded successfully in container $lxc_id."
        return 0
    else
        "$error_func" "reload_systemd_daemon_in_container: Failed to reload systemd daemon in container $lxc_id."
        return 1
    fi
}


echo "[INFO] phoenix_hypervisor_lxc_common_systemd.sh: Library loaded successfully."
