#!/usr/bin/env bash

# phoenix_hypervisor_lxc_common_validation.sh
#
# Common validation functions for Phoenix Hypervisor.
# Provides functions for validating containers, configurations, and host environment.
# Designed to be sourced by setup and management scripts.
# Version: 1.0.0

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
    local required_commands=("jq" "pct")
    for cmd in "${required_commands[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            "$log_func" "validate_host_environment: Found required command '$cmd'."
            ((checks_passed++)) || true
        else
            "$warn_func" "validate_host_environment: Required command '$cmd' not found."
            ((checks_failed++)) || true
        fi
    done

    # Check for apparmor service (generally good to have, but not always critical)
    if systemctl is-active --quiet apparmor; then
        "$log_func" "validate_host_environment: apparmor service is active."
        ((checks_passed++)) || true
    else
        "$warn_func" "validate_host_environment: apparmor service is not active. This might be OK depending on your setup."
        # Not incrementing failed count as it's a warning
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

    local check_cmd="set -e; if [[ -e '$path' ]]; then echo '[SUCCESS] Path exists: $path'; exit 0; else echo '[ERROR] Path does not exist: $path'; exit 1; fi"

    # Use pct_exec_with_retry if available (from base common lib), otherwise direct exec
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        if pct_exec_with_retry "$lxc_id" "$check_cmd"; then
            "$log_func" "validate_path_in_container: Path '$path' exists in container $lxc_id."
            return 0
        else
            # Use log_warn if available, otherwise fallback
            local warn_func="log_warn"
            if ! declare -F log_warn >/dev/null 2>&1; then
                warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" >&2; }
            fi
            "$warn_func" "validate_path_in_container: Path '$path' does not exist in container $lxc_id."
            return 1
        fi
    else
        # Fallback if pct_exec_with_retry is not available
        if pct exec "$lxc_id" -- bash -c "$check_cmd"; then
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
    fi
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


#echo "[INFO] phoenix_hypervisor_lxc_common_validation.sh: Library loaded successfully."
