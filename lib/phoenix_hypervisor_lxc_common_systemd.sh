#!/usr/bin/env bash

# phoenix_hypervisor_lxc_common_systemd.sh
#
# Common functions for managing systemd services inside LXC containers.
# This script is intended to be sourced by other Phoenix Hypervisor scripts.
# Requires: pct, bash
# Assumes: phoenix_hypervisor_common.sh is sourced for logging (fallbacks included)
# Version: 1.1.0 (Enhanced for Ubuntu 25.04, non-systemd fallbacks, and improved error handling)

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

    # Use pct_exec_with_retry if available, otherwise direct exec
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

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
# Verify service file
if ! test -f '$service_file_path'; then
    echo '[ERROR] Service file not created at $service_file_path'
    exit 1
fi
if ! grep -q '\\[Unit\\]' '$service_file_path' || ! grep -q '\\[Service\\]' '$service_file_path' || ! grep -q '\\[Install\\]' '$service_file_path'; then
    echo '[ERROR] Service file at $service_file_path is missing required sections'
    exit 1
fi
echo '[SUCCESS] Systemd service file created and verified successfully.'
"

    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "create_systemd_service_in_container: Attempting service creation (attempt $attempt/$max_attempts)..."
        if "$exec_func" "$lxc_id" -- bash -c "$create_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
            "$log_func" "create_systemd_service_in_container: Systemd service '$service_name' created and verified successfully in container $lxc_id."
            return 0
        else
            "$log_func" "create_systemd_service_in_container: Failed on attempt $attempt. Retrying in 5 seconds..."
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

    # Use log_warn if available, otherwise fallback
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*"; }
    fi

    if [[ -z "$lxc_id" ]] || [[ -z "$service_name" ]]; then
        "$error_func" "enable_systemd_service_in_container: Missing lxc_id or service_name"
        return 1
    fi

    "$log_func" "enable_systemd_service_in_container: Enabling systemd service '$service_name' in container $lxc_id..."

    # Use pct_exec_with_retry if available, otherwise direct exec
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    local enable_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if ! command -v systemctl >/dev/null 2>&1 || ! systemctl is-system-running >/dev/null 2>&1; then
    echo '[WARN] Systemd not available in container.'
    if [[ '$service_name' == 'docker' ]] && command -v dockerd >/dev/null 2>&1; then
        echo '[INFO] Docker service detected, checking manual enablement...'
        if pgrep -x dockerd >/dev/null 2>&1; then
            echo '[SUCCESS] Docker daemon already running, considered enabled.'
            exit 0
        else
            echo '[INFO] Starting dockerd manually to enable...'
            /usr/bin/dockerd -H unix:///var/run/docker.sock --containerd=/run/containerd/containerd.sock > /tmp/systemd-docker.log 2>&1 &
            sleep 5
            if pgrep -x dockerd >/dev/null 2>&1; then
                echo '[SUCCESS] Docker daemon started manually and enabled.'
                exit 0
            else
                echo '[ERROR] Failed to start Docker daemon manually.'
                cat /tmp/systemd-docker.log
                exit 1
            fi
        fi
    else
        echo '[ERROR] Systemd not available and no fallback for service $service_name.'
        exit 1
    fi
fi
echo '[INFO] Enabling service...'
systemctl enable '$service_name' > /tmp/systemd-$service_name.log 2>&1 || { echo '[ERROR] Failed to enable service'; cat /tmp/systemd-$service_name.log; exit 1; }
echo '[SUCCESS] Service enabled successfully.'
"

    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "enable_systemd_service_in_container: Attempting service enable (attempt $attempt/$max_attempts)..."
        if "$exec_func" "$lxc_id" -- bash -c "$enable_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
            "$log_func" "enable_systemd_service_in_container: Systemd service '$service_name' enabled successfully in container $lxc_id."
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

    # Use log_warn if available, otherwise fallback
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*"; }
    fi

    if [[ -z "$lxc_id" ]] || [[ -z "$service_name" ]]; then
        "$error_func" "start_systemd_service_in_container: Missing lxc_id or service_name"
        return 1
    fi

    "$log_func" "start_systemd_service_in_container: Starting systemd service '$service_name' in container $lxc_id..."

    # Use pct_exec_with_retry if available, otherwise direct exec
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    local start_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if ! command -v systemctl >/dev/null 2>&1 || ! systemctl is-system-running >/dev/null 2>&1; then
    echo '[WARN] Systemd not available in container.'
    if [[ '$service_name' == 'docker' ]] && command -v dockerd >/dev/null 2>&1; then
        echo '[INFO] Docker service detected, checking manual start...'
        if pgrep -x dockerd >/dev/null 2>&1; then
            echo '[SUCCESS] Docker daemon already running.'
            exit 0
        else
            echo '[INFO] Starting dockerd manually...'
            /usr/bin/dockerd -H unix:///var/run/docker.sock --containerd=/run/containerd/containerd.sock > /tmp/systemd-docker.log 2>&1 &
            sleep 5
            if pgrep -x dockerd >/dev/null 2>&1; then
                echo '[SUCCESS] Docker daemon started manually.'
                exit 0
            else
                echo '[ERROR] Failed to start Docker daemon manually.'
                cat /tmp/systemd-docker.log
                exit 1
            fi
        fi
    else
        echo '[ERROR] Systemd not available and no fallback for service $service_name.'
        exit 1
    fi
fi
echo '[INFO] Starting service...'
systemctl start '$service_name' > /tmp/systemd-$service_name.log 2>&1 || { echo '[ERROR] Failed to start service'; cat /tmp/systemd-$service_name.log; exit 1; }
echo '[SUCCESS] Service started successfully.'
"

    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "start_systemd_service_in_container: Attempting service start (attempt $attempt/$max_attempts)..."
        if "$exec_func" "$lxc_id" -- bash -c "$start_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
            "$log_func" "start_systemd_service_in_container: Systemd service '$service_name' started successfully in container $lxc_id."
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

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    fi

    # Use log_warn if available, otherwise fallback
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*"; }
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

    # Use pct_exec_with_retry if available, otherwise direct exec
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    local stop_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if ! command -v systemctl >/dev/null 2>&1 || ! systemctl is-system-running >/dev/null 2>&1; then
    echo '[WARN] Systemd not available in container.'
    if [[ '$service_name' == 'docker' ]] && command -v dockerd >/dev/null 2>&1; then
        echo '[INFO] Docker service detected, checking manual stop...'
        if pgrep -x dockerd >/dev/null 2>&1; then
            echo '[INFO] Stopping dockerd manually...'
            pkill -x dockerd || { echo '[WARN] Failed to stop Docker daemon manually'; exit 0; }
            sleep 2
            if ! pgrep -x dockerd >/dev/null 2>&1; then
                echo '[SUCCESS] Docker daemon stopped manually.'
                exit 0
            else
                echo '[ERROR] Failed to stop Docker daemon manually.'
                exit 1
            fi
        else
            echo '[SUCCESS] Docker daemon not running, considered stopped.'
            exit 0
        fi
    else
        echo '[ERROR] Systemd not available and no fallback for service $service_name.'
        exit 1
    fi
fi
echo '[INFO] Stopping service...'
systemctl stop '$service_name' > /tmp/systemd-$service_name.log 2>&1 || { echo '[WARN] Failed to stop service (might not be running)'; cat /tmp/systemd-$service_name.log; exit 0; }
echo '[SUCCESS] Service stopped successfully.'
"

    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "stop_systemd_service_in_container: Attempting service stop (attempt $attempt/$max_attempts)..."
        if "$exec_func" "$lxc_id" -- bash -c "$stop_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
            "$log_func" "stop_systemd_service_in_container: Systemd service '$service_name' stopped successfully in container $lxc_id."
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

    # Use log_warn if available, otherwise fallback
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*"; }
    fi

    if [[ -z "$lxc_id" ]] || [[ -z "$service_name" ]]; then
        "$error_func" "restart_systemd_service_in_container: Missing lxc_id or service_name"
        return 1
    fi

    "$log_func" "restart_systemd_service_in_container: Restarting systemd service '$service_name' in container $lxc_id..."

    # Use pct_exec_with_retry if available, otherwise direct exec
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    local restart_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if ! command -v systemctl >/dev/null 2>&1 || ! systemctl is-system-running >/dev/null 2>&1; then
    echo '[WARN] Systemd not available in container.'
    if [[ '$service_name' == 'docker' ]] && command -v dockerd >/dev/null 2>&1; then
        echo '[INFO] Docker service detected, checking manual restart...'
        if pgrep -x dockerd >/dev/null 2>&1; then
            echo '[INFO] Stopping dockerd manually...'
            pkill -x dockerd || { echo '[ERROR] Failed to stop Docker daemon manually'; exit 1; }
            sleep 2
        fi
        echo '[INFO] Starting dockerd manually...'
        /usr/bin/dockerd -H unix:///var/run/docker.sock --containerd=/run/containerd/containerd.sock > /tmp/systemd-docker.log 2>&1 &
        sleep 5
        if pgrep -x dockerd >/dev/null 2>&1; then
            echo '[SUCCESS] Docker daemon restarted manually.'
            exit 0
        else
            echo '[ERROR] Failed to restart Docker daemon manually.'
            cat /tmp/systemd-docker.log
            exit 1
        fi
    else
        echo '[ERROR] Systemd not available and no fallback for service $service_name.'
        exit 1
    fi
fi
echo '[INFO] Restarting service...'
systemctl restart '$service_name' > /tmp/systemd-$service_name.log 2>&1 || { echo '[ERROR] Failed to restart service'; cat /tmp/systemd-$service_name.log; exit 1; }
echo '[SUCCESS] Service restarted successfully.'
"

    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "restart_systemd_service_in_container: Attempting service restart (attempt $attempt/$max_attempts)..."
        if "$exec_func" "$lxc_id" -- bash -c "$restart_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
            "$log_func" "restart_systemd_service_in_container: Systemd service '$service_name' restarted successfully in container $lxc_id."
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

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    fi

    # Use log_warn if available, otherwise fallback
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*"; }
    fi

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    if [[ -z "$lxc_id" ]] || [[ -z "$service_name" ]]; then
        "$error_func" "check_systemd_service_status_in_container: Missing lxc_id or service_name"
        return 2
    fi

    "$log_func" "check_systemd_service_status_in_container: Checking status of systemd service '$service_name' in container $lxc_id..."

    # Use pct_exec_with_retry if available, otherwise direct exec
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    local status_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if ! command -v systemctl >/dev/null 2>&1 || ! systemctl is-system-running >/dev/null 2>&1; then
    echo '[WARN] Systemd not available in container.'
    if [[ '$service_name' == 'docker' ]] && command -v dockerd >/dev/null 2>&1; then
        echo '[INFO] Docker service detected, checking manual status...'
        if pgrep -x dockerd >/dev/null 2>&1; then
            echo '[STATUS] active'
            echo '[INFO] Docker daemon running, details: $(ps -C dockerd -o pid,cmd)'
            exit 0
        else
            echo '[STATUS] inactive'
            echo '[INFO] Docker daemon not running.'
            exit 1
        fi
    else
        echo '[ERROR] Systemd not available and no fallback for service $service_name.'
        exit 2
    fi
fi
# Capture detailed status for debugging
systemctl status '$service_name' > /tmp/systemd-$service_name.log 2>&1 || true
# Use systemctl is-active which returns specific exit codes
if systemctl is-active --quiet '$service_name'; then
    echo '[STATUS] active'
    echo '[INFO] Service status details: $(cat /tmp/systemd-$service_name.log | head -n 10)'
    exit 0
elif systemctl is-failed --quiet '$service_name' 2>/dev/null; then
    echo '[STATUS] failed'
    echo '[INFO] Service status details: $(cat /tmp/systemd-$service_name.log | head -n 10)'
    exit 1
elif systemctl list-units --full --all | grep -q '$service_name'\.service; then
    echo '[STATUS] inactive'
    echo '[INFO] Service status details: $(cat /tmp/systemd-$service_name.log | head -n 10)'
    exit 1
else
    echo '[STATUS] not-found'
    echo '[INFO] Service not found.'
    exit 3
fi
"

    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "check_systemd_service_status_in_container: Attempting status check (attempt $attempt/$max_attempts)..."
        local output
        local exit_code
        output=$("$exec_func" "$lxc_id" -- bash -c "$status_cmd" 2>&1) || exit_code=$?
        exit_code=${exit_code:-0}

        case $exit_code in
            0)
                "$log_func" "check_systemd_service_status_in_container: Service '$service_name' is active in container $lxc_id. Output: $output"
                echo "active"
                return 0
                ;;
            1)
                if [[ "$output" == *"[STATUS] failed"* ]]; then
                    "$warn_func" "check_systemd_service_status_in_container: Service '$service_name' is failed in container $lxc_id. Output: $output"
                    echo "failed"
                else
                    "$log_func" "check_systemd_service_status_in_container: Service '$service_name' is inactive in container $lxc_id. Output: $output"
                    echo "inactive"
                fi
                return 1
                ;;
            3)
                "$warn_func" "check_systemd_service_status_in_container: Service '$service_name' not found in container $lxc_id. Output: $output"
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

    # Use log_warn if available, otherwise fallback
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*"; }
    fi

    if [[ -z "$lxc_id" ]]; then
        "$error_func" "reload_systemd_daemon_in_container: Missing lxc_id"
        return 1
    fi

    "$log_func" "reload_systemd_daemon_in_container: Reloading systemd daemon in container $lxc_id..."

    # Use pct_exec_with_retry if available, otherwise direct exec
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    local reload_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if ! command -v systemctl >/dev/null 2>&1 || ! systemctl is-system-running >/dev/null 2>&1; then
    echo '[WARN] Systemd not available in container, skipping daemon-reload.'
    exit 0
fi
echo '[INFO] Reloading systemd daemon...'
systemctl daemon-reload > /tmp/systemd-daemon-reload.log 2>&1 || { echo '[ERROR] Failed to reload systemd daemon'; cat /tmp/systemd-daemon-reload.log; exit 1; }
echo '[SUCCESS] Systemd daemon reloaded successfully.'
"

    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "reload_systemd_daemon_in_container: Attempting daemon reload (attempt $attempt/$max_attempts)..."
        if "$exec_func" "$lxc_id" -- bash -c "$reload_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
            "$log_func" "reload_systemd_daemon_in_container: Systemd daemon reloaded successfully in container $lxc_id."
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

echo "[INFO] phoenix_hypervisor_lxc_common_systemd.sh: Library loaded successfully."