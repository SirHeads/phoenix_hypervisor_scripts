#!/usr/bin/env bash

# phoenix_hypervisor_lxc_common_validation.sh
#
# Common validation functions for Phoenix Hypervisor.
# Provides functions for validating containers, configurations, and host environment.
# Designed to be sourced by setup and management scripts.
# Requires: pct, jq, bash, standard Unix tools
# Assumes: phoenix_hypervisor_common.sh is sourced for logging (fallbacks included)
# Version: 1.1.0
# Changelog:
#   - 1.1.0: Added Portainer-specific validations (Docker Hub auth, network settings).
#            Added Docker service and storage driver checks.
#            Enhanced container path validation for Portainer paths.
#            Improved error handling and logging.
#            Ensured compatibility with overlay2 storage driver in LXC.

# --- Host Environment Validation ---

# Validate essential host environment prerequisites
# Usage: validate_host_environment
validate_host_environment() {
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

    "$log_func" "validate_host_environment: Checking host environment prerequisites..."

    local checks_passed=0
    local checks_failed=0

    # Check for required commands
    local required_commands=("jq" "pct" "zfs" "docker")
    for cmd in "${required_commands[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            "$log_func" "validate_host_environment: Found required command '$cmd'."
            ((checks_passed++)) || true
        else
            "$warn_func" "validate_host_environment: Required command '$cmd' not found."
            ((checks_failed++)) || true
        fi
    done

    # Check for apparmor service (important for Docker in LXC)
    if systemctl is-active --quiet apparmor; then
        "$log_func" "validate_host_environment: apparmor service is active."
        ((checks_passed++)) || true
    else
        "$warn_func" "validate_host_environment: apparmor service is not active. This may cause issues with Docker in LXC."
        ((checks_failed++)) || true
    fi

    # Check for ZFS pool (assuming PHOENIX_ZFS_LXC_POOL is available from config)
    if [[ -n "${PHOENIX_ZFS_LXC_POOL:-}" ]]; then
        if zfs list "$PHOENIX_ZFS_LXC_POOL" >/dev/null 2>&1; then
            "$log_func" "validate_host_environment: ZFS pool '$PHOENIX_ZFS_LXC_POOL' found."
            ((checks_passed++)) || true
        else
            "$warn_func" "validate_host_environment: ZFS pool '$PHOENIX_ZFS_LXC_POOL' not found or accessible."
            ((checks_failed++)) || true
        fi
    else
        "$warn_func" "validate_host_environment: PHOENIX_ZFS_LXC_POOL not defined in configuration."
        ((checks_failed++)) || true
    fi

    # Check for NVIDIA GPUs (if NVIDIA setup is expected)
    if command -v nvidia-smi >/dev/null 2>&1; then
        if nvidia-smi -L >/dev/null 2>&1; then
            local gpu_count
            gpu_count=$(nvidia-smi -L | wc -l)
            "$log_func" "validate_host_environment: Found $gpu_count NVIDIA GPU(s) on host."
            ((checks_passed++)) || true
        else
            "$warn_func" "validate_host_environment: nvidia-smi found but failed to list GPUs."
            ((checks_failed++)) || true
        fi
    else
        "$warn_func" "validate_host_environment: nvidia-smi not found. Skipping GPU check."
        # Not incrementing failed count as it's a warning if no GPU setup is intended
    fi

    # Check Docker service status on host
    if systemctl is-active --quiet docker; then
        "$log_func" "validate_host_environment: Docker service is active on host."
        ((checks_passed++)) || true
    else
        "$warn_func" "validate_host_environment: Docker service is not active on host. Required for Portainer setup."
        ((checks_failed++)) || true
    fi

    # Check Docker Hub connectivity and authentication (for SirHeads)
    if command -v docker >/dev/null 2>&1; then
        local docker_login_check="docker login -u SirHeads --password-stdin >/dev/null 2>&1 <<< '${DOCKER_PASSWORD:-}'"
        if eval "$docker_login_check"; then
            "$log_func" "validate_host_environment: Docker Hub authentication successful for user 'SirHeads'."
            ((checks_passed++)) || true
        else
            "$warn_func" "validate_host_environment: Docker Hub authentication failed for user 'SirHeads'. Ensure DOCKER_PASSWORD is set or credentials are valid."
            ((checks_failed++)) || true
        fi
    else
        "$warn_func" "validate_host_environment: Docker not installed, cannot validate Docker Hub authentication."
        ((checks_failed++)) || true
    fi

    # Check network connectivity for Portainer (10.0.0.99:9443)
    if nc -z -w 5 10.0.0.99 9443 >/dev/null 2>&1; then
        "$log_func" "validate_host_environment: Network connectivity to 10.0.0.99:9443 (Portainer) is available."
        ((checks_passed++)) || true
    else
        "$warn_func" "validate_host_environment: Cannot connect to 10.0.0.99:9443 (Portainer). Check network configuration."
        ((checks_failed++)) || true
    fi

    "$log_func" "validate_host_environment: Host validation summary: $checks_passed passed, $checks_failed warnings/errors."

    if [[ $checks_failed -gt 0 ]]; then
        "$warn_func" "validate_host_environment: Host environment validation completed with $checks_failed warnings/errors. Check logs."
        return 1 # Indicate partial failure/warnings
    fi

    "$log_func" "validate_host_environment: Host environment validation completed successfully."
    return 0
}

# --- Container State Validation ---

# Check if a container exists
# Usage: validate_container_exists <container_id>
validate_container_exists() {
    local lxc_id="$1"

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    if [[ -z "$lxc_id" ]]; then
        "$error_func" "validate_container_exists: Container ID is required."
        return 2 # Invalid argument
    fi

    if pct config "$lxc_id" >/dev/null 2>&1; then
        return 0 # Exists
    else
        # Use log_warn if available, otherwise fallback
        local warn_func="log_warn"
        if ! declare -F log_warn >/dev/null 2>&1; then
            warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" >&2; }
        fi
        "$warn_func" "validate_container_exists: Container $lxc_id does not exist."
        return 1 # Does not exist
    fi
}

# Check if a container is running
# Usage: validate_container_running <container_id>
validate_container_running() {
    local lxc_id="$1"

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    fi

    if [[ -z "$lxc_id" ]]; then
        "$error_func" "validate_container_running: Container ID is required."
        return 2 # Invalid argument
    fi

    local status
    status=$(pct status "$lxc_id" 2>/dev/null | grep 'status' | awk '{print $2}')

    if [[ "$status" == "running" ]]; then
        "$log_func" "validate_container_running: Container $lxc_id is running."
        return 0
    else
        # Use log_warn if available, otherwise fallback
        local warn_func="log_warn"
        if ! declare -F log_warn >/dev/null 2>&1; then
            warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" >&2; }
        fi
        "$warn_func" "validate_container_running: Container $lxc_id is not running (status: $status)."
        return 1
    fi
}

# Validate GPU assignment string format (e.g., "0", "1", "0,1", "all", "none")
# Usage: validate_gpu_assignment_format <gpu_assignment_string>
validate_gpu_assignment_format() {
    local gpu_assignment="$1"

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    if [[ -z "$gpu_assignment" ]]; then
        "$error_func" "validate_gpu_assignment_format: GPU assignment string cannot be empty."
        return 2 # Invalid argument
    fi

    # Valid formats: "none", "all", comma-separated numbers (e.g., "0", "1", "0,1")
    if [[ "$gpu_assignment" =~ ^none$|^all$|^[0-9]+(,[0-9]+)*$ ]]; then
        return 0 # Valid format
    else
        "$error_func" "validate_gpu_assignment_format: Invalid GPU assignment format: '$gpu_assignment'. Expected 'none', 'all', or comma-separated GPU indices (e.g., '0', '1', '0,1')."
        return 1 # Invalid format
    fi
}

# --- File/Path Validation Inside Containers ---

# Check if a file or directory exists inside a container
# Usage: validate_path_in_container <container_id> <path_inside_container>
validate_path_in_container() {
    local lxc_id="$1"
    local path="$2"

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    fi

    if [[ -z "$lxc_id" ]] || [[ -z "$path" ]]; then
        "$error_func" "validate_path_in_container: Container ID and path are required."
        return 2 # Invalid argument
    fi

    local check_cmd="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    if [[ -e '$path' ]]; then
        echo '[SUCCESS] Path exists: $path'
        exit 0
    else
        echo '[ERROR] Path does not exist: $path'
        exit 1
    fi"

    # Use pct_exec_with_retry if available (from phoenix_hypervisor_lxc_common_base.sh)
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    if "$exec_func" "$lxc_id" bash -c "$check_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        "$log_func" "validate_path_in_container: Path '$path' exists in container $lxc_id."
        return 0
    else
        local warn_func="log_warn"
        if ! declare -F log_warn >/dev/null 2>&1; then
            warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" >&2; }
        fi
        "$warn_func" "validate_path_in_container: Path '$path' does not exist in container $lxc_id."
        return 1
    fi
}

# Validate Portainer-specific paths in a container
# Usage: validate_portainer_paths_in_container <container_id>
validate_portainer_paths_in_container() {
    local lxc_id="$1"

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

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

    if [[ -z "$lxc_id" ]]; then
        "$error_func" "validate_portainer_paths_in_container: Container ID is required."
        return 2 # Invalid argument
    fi

    "$log_func" "validate_portainer_paths_in_container: Validating Portainer paths in container $lxc_id..."

    local checks_passed=0
    local checks_failed=0
    local portainer_paths=("/var/lib/docker" "/etc/docker/daemon.json" "/usr/bin/docker")

    for path in "${portainer_paths[@]}"; do
        if validate_path_in_container "$lxc_id" "$path"; then
            ((checks_passed++)) || true
        else
            ((checks_failed++)) || true
        fi
    done

    # Check Docker service status inside container
    local docker_service_check="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    if systemctl is-active --quiet docker; then
        echo '[SUCCESS] Docker service is active.'
        exit 0
    else
        echo '[ERROR] Docker service is not active.'
        exit 1
    fi"

    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    if "$exec_func" "$lxc_id" bash -c "$docker_service_check" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        "$log_func" "validate_portainer_paths_in_container: Docker service is active in container $lxc_id."
        ((checks_passed++)) || true
    else
        "$warn_func" "validate_portainer_paths_in_container: Docker service is not active in container $lxc_id."
        ((checks_failed++)) || true
    fi

    # Check storage driver (expecting overlay2 for LXC compatibility)
    local storage_driver_check="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    if docker info --format '{{.Driver}}' | grep -q 'overlay2'; then
        echo '[SUCCESS] Docker storage driver is overlay2.'
        exit 0
    else
        echo '[ERROR] Docker storage driver is not overlay2: $(docker info --format '{{.Driver}}').'
        exit 1
    fi"

    if "$exec_func" "$lxc_id" bash -c "$storage_driver_check" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        "$log_func" "validate_portainer_paths_in_container: Docker storage driver is overlay2 in container $lxc_id."
        ((checks_passed++)) || true
    else
        "$warn_func" "validate_portainer_paths_in_container: Docker storage driver is not overlay2 in container $lxc_id."
        ((checks_failed++)) || true
    fi

    # Check Portainer-specific Docker image
    local portainer_image_check="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    if docker images -q portainer/portainer-ce:latest | grep -q .; then
        echo '[SUCCESS] Portainer image portainer/portainer-ce:latest found.'
        exit 0
    else
        echo '[ERROR] Portainer image portainer/portainer-ce:latest not found.'
        exit 1
    fi"

    if [[ "$lxc_id" == "999" ]]; then
        if "$exec_func" "$lxc_id" bash -c "$portainer_image_check" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
            "$log_func" "validate_portainer_paths_in_container: Portainer image portainer/portainer-ce:latest found in container $lxc_id."
            ((checks_passed++)) || true
        else
            "$warn_func" "validate_portainer_paths_in_container: Portainer image portainer/portainer-ce:latest not found in container $lxc_id."
            ((checks_failed++)) || true
        fi
    fi

    "$log_func" "validate_portainer_paths_in_container: Portainer path validation summary for container $lxc_id: $checks_passed passed, $checks_failed warnings/errors."

    if [[ $checks_failed -gt 0 ]]; then
        "$warn_func" "validate_portainer_paths_in_container: Validation completed with $checks_failed warnings/errors for container $lxc_id."
        return 1
    fi

    "$log_func" "validate_portainer_paths_in_container: Portainer path validation completed successfully for container $lxc_id."
    return 0
}

# --- Configuration File Validation ---

# Validate the syntax of a JSON configuration file
# Usage: validate_json_syntax <path_to_json_file>
validate_json_syntax() {
    local json_file="$1"

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    fi

    if [[ -z "$json_file" ]]; then
        "$error_func" "validate_json_syntax: Path to JSON file is required."
        return 2 # Invalid argument
    fi

    if [[ ! -f "$json_file" ]]; then
        "$error_func" "validate_json_syntax: File '$json_file' does not exist."
        return 1 # File not found
    fi

    if jq -e . >/dev/null 2>&1 < "$json_file"; then
        "$log_func" "validate_json_syntax: JSON syntax is valid for file '$json_file'."
        return 0 # Valid JSON
    else
        "$error_func" "validate_json_syntax: Invalid JSON syntax in file '$json_file'."
        return 1 # Invalid JSON
    fi
}

# Validate JSON configuration against a schema (requires jsonschema tool)
# Usage: validate_json_schema <path_to_json_file> <path_to_schema_file>
validate_json_schema() {
    local json_file="$1"
    local schema_file="$2"

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    fi

    if [[ -z "$json_file" ]] || [[ -z "$schema_file" ]]; then
        "$error_func" "validate_json_schema: Paths to JSON file and schema file are required."
        return 2 # Invalid argument
    fi

    if [[ ! -f "$json_file" ]]; then
        "$error_func" "validate_json_schema: JSON file '$json_file' does not exist."
        return 1
    fi

    if [[ ! -f "$schema_file" ]]; then
        "$error_func" "validate_json_schema: Schema file '$schema_file' does not exist."
        return 1
    fi

    # Check if jsonschema tool is available
    if ! command -v jsonschema >/dev/null 2>&1; then
        "$error_func" "validate_json_schema: 'jsonschema' tool is not installed. Please install python3-jsonschema."
        return 1
    fi

    "$log_func" "validate_json_schema: Validating '$json_file' against schema '$schema_file'..."

    # Run jsonschema validation, redirecting stdout to /dev/null to reduce noise on success
    if jsonschema -i "$json_file" "$schema_file" >/dev/null; then
        "$log_func" "validate_json_schema: JSON file '$json_file' conforms to schema '$schema_file'."
        return 0 # Valid according to schema
    else
        "$error_func" "validate_json_schema: JSON file '$json_file' does NOT conform to schema '$schema_file'. See errors above."
        return 1 # Invalid according to schema
    fi
}

# Validate Portainer-specific network configuration in a container
# Usage: validate_portainer_network_in_container <container_id> <ip_address> <port>
validate_portainer_network_in_container() {
    local lxc_id="$1"
    local ip_address="$2"
    local port="$3"

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

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

    if [[ -z "$lxc_id" ]] || [[ -z "$ip_address" ]] || [[ -z "$port" ]]; then
        "$error_func" "validate_portainer_network_in_container: Container ID, IP address, and port are required."
        return 2 # Invalid argument
    fi

    "$log_func" "validate_portainer_network_in_container: Validating network configuration for $ip_address:$port in container $lxc_id..."

    local net_check_cmd="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    if nc -z -w 5 $ip_address $port >/dev/null 2>&1; then
        echo '[SUCCESS] Network connectivity to $ip_address:$port is available.'
        exit 0
    else
        echo '[ERROR] Cannot connect to $ip_address:$port.'
        exit 1
    fi"

    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    if "$exec_func" "$lxc_id" bash -c "$net_check_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        "$log_func" "validate_portainer_network_in_container: Network connectivity to $ip_address:$port confirmed in container $lxc_id."
        return 0
    else
        "$warn_func" "validate_portainer_network_in_container: Failed to connect to $ip_address:$port in container $lxc_id."
        return 1
    fi
}

echo "[INFO] phoenix_hypervisor_lxc_common_validation.sh: Library loaded successfully."