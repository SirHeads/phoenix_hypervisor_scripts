#!/bin/bash
# Common functions for Phoenix Hypervisor
# Provides reusable functions for logging, GPU handling, LXC creation, etc.
# Version: 1.7.4
# Author: Assistant

# --- Logging Functions ---
log_message() {
    local level="$1"
    local message="$2"
    # Log to file if PHOENIX_HYPERVISOR_LOGFILE is set and writable
    if [[ -n "${PHOENIX_HYPERVISOR_LOGFILE:-}" ]] && [[ -w "$(dirname "$PHOENIX_HYPERVISOR_LOGFILE" 2>/dev/null)" || -w "$PHOENIX_HYPERVISOR_LOGFILE" 2>/dev/null ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$PHOENIX_HYPERVISOR_LOGFILE"
    fi
    # Always echo to stdout/stderr
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
}

log_info() {
    log_message "INFO" "$1"
}

log_warn() {
    log_message "WARN" "$1" >&2 # Send warnings to stderr
}

log_error() {
    log_message "ERROR" "$1" >&2 # Send errors to stderr
}


# --- GPU Assignment Handling ---
get_gpu_assignment() {
    local container_id="$1"

    if [[ -z "$container_id" ]]; then
        log_error "get_gpu_assignment: Container ID cannot be empty"
        return 1
    fi

    # Get GPU assignment from the main configuration file
    # This relies on PHOENIX_LXC_CONFIG_FILE being set (from phoenix_hypervisor_config.sh)
    if command -v jq >/dev/null 2>&1 && [[ -n "${PHOENIX_LXC_CONFIG_FILE:-}" ]] && [[ -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        local gpu_assignment
        # Use .lxc_configs.<id>.gpu_assignment, fallback to "none"
        gpu_assignment=$(jq -r ".lxc_configs.\"$container_id\".gpu_assignment // \"none\"" "$PHOENIX_LXC_CONFIG_FILE" 2>/dev/null || echo "none")
        echo "$gpu_assignment"
        return 0
    else
        log_warn "get_gpu_assignment: jq not available or config file not found/readable, returning default GPU assignment"
        echo "none"
        # Returning 0 here as "none" is a valid state, not an error condition for the function itself
        return 0
    fi
}

# --- GPU Validation ---
validate_gpu_assignment() {
    local container_id="$1"
    local gpu_assignment="$2"

    # Skip validation if no GPUs assigned or explicitly "none"
    if [[ -z "$gpu_assignment" ]] || [[ "$gpu_assignment" == "none" ]]; then
        return 0
    fi

    # Validate that GPU indices are numeric and properly formatted
    IFS=',' read -ra indices <<< "$gpu_assignment"
    for index in "${indices[@]}"; do
        # Check if index is a valid non-negative integer
        if ! [[ "$index" =~ ^[0-9]+$ ]]; then
            log_error "validate_gpu_assignment: Invalid GPU index '$index' in assignment for container $container_id"
            return 1
        fi
        # Optional: Check if index is within a reasonable range (e.g., 0-15)
        # if [[ "$index" -gt 15 ]]; then
        #     log_warn "validate_gpu_assignment: GPU index '$index' for container $container_id seems unusually high."
        # fi
    done

    return 0
}

# --- GPU Passthrough Configuration ---
configure_lxc_gpu_passthrough() {
    local lxc_id="$1"
    local gpu_assignment="$2"

    # Validate inputs
    if [[ -z "$lxc_id" ]]; then
        log_error "configure_lxc_gpu_passthrough: LXC ID cannot be empty"
        return 1
    fi

    if [[ -z "$gpu_assignment" ]] || [[ "$gpu_assignment" == "none" ]]; then
        log_info "configure_lxc_gpu_passthrough: No GPU assignment for container $lxc_id, skipping GPU passthrough setup"
        return 0
    fi

    # Check for nvidia-smi on host to ensure drivers are installed
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        log_error "configure_lxc_gpu_passthrough: nvidia-smi not found on host. Cannot configure GPU passthrough."
        return 1
    fi

    # Get GPU details for logging
    local gpu_details=()
    IFS=',' read -ra indices <<< "$gpu_assignment"
    for index in "${indices[@]}"; do
        local gpu_name
        # Get GPU name for informational purposes
        gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits -i "$index" 2>/dev/null | tr -d ' ')
        if [[ -n "$gpu_name" ]]; then
           gpu_details+=("$gpu_name")
        else
           gpu_details+=("GPU_$index")
        fi
    done

    log_info "configure_lxc_gpu_passthrough: Configuring GPU passthrough for container $lxc_id with GPUs: ${gpu_details[*]}"

    # Define the LXC config file path
    local config_file="/etc/pve/lxc/$lxc_id.conf"
    if [[ ! -f "$config_file" ]]; then
        log_error "configure_lxc_gpu_passthrough: LXC configuration file not found: $config_file"
        return 1
    fi

    # --- Remove any existing conflicting GPU device entries to avoid duplicates ---
    # This is a cautious approach to prevent accumulating entries on multiple runs
    # Remove specific patterns related to NVIDIA devices
    sed -i '/^lxc\.cgroup2\.devices\.allow.*195:/d' "$config_file" # nvidia-uvm
    sed -i '/^lxc\.cgroup2\.devices\.allow.*235:/d' "$config_file" # nvidia-frontend (capability)
    sed -i '/^lxc\.cgroup2\.devices\.allow.*236:/d' "$config_file" # nvidiactl
    sed -i '/^lxc\.cgroup2\.devices\.allow.*237:/d' "$config_file" # nvidia-caps
    sed -i '/^lxc\.cgroup2\.devices\.allow.*506:/d' "$config_file" # nvidia-nvswitch
    sed -i '/^lxc\.cgroup2\.devices\.allow.*507:/d' "$config_file" # nvidia-nvswitch-mgmt
    sed -i '/^lxc\.mount\.entry.*\/dev\/nvidia/d' "$config_file"    # All /dev/nvidia mounts

    # --- Add required cgroup permissions for each GPU ---
    for index in "${indices[@]}"; do
        # Core NVIDIA device permissions (based on common LXC GPU passthrough guides)
        echo "lxc.cgroup2.devices.allow: c 195:* rwm" >> "$config_file" # nvidia-uvm
        echo "lxc.cgroup2.devices.allow: c 235:* rwm" >> "$config_file" # nvidia-frontend (capability devices)
        echo "lxc.cgroup2.devices.allow: c 236:$index rwm" >> "$config_file" # nvidiactl (control device for specific GPU)
        echo "lxc.cgroup2.devices.allow: c 237:$index rwm" >> "$config_file" # nvidia-caps (capability devices for specific GPU)
        # NVSwitch devices (if applicable for your setup, often not needed for single GPUs)
        echo "lxc.cgroup2.devices.allow: c 506:$index rwm" >> "$config_file" # nvidia-nvswitch
        echo "lxc.cgroup2.devices.allow: c 507:$index rwm" >> "$config_file" # nvidia-nvswitch-mgmt
    done

    # --- Add required mount entries for each GPU device file ---
    for index in "${indices[@]}"; do
        echo "lxc.mount.entry: /dev/nvidia$index dev/nvidia$index none bind,optional,create=file" >> "$config_file"
    done
    # Add common NVIDIA device files
    echo "lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file" >> "$config_file"
    echo "lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file" >> "$config_file"
    echo "lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file" >> "$config_file"
    echo "lxc.mount.entry: /dev/nvidia-modeset dev/nvidia-modeset none bind,optional,create=file" >> "$config_file"

    # --- Add capability device entries ---
    # This part can be tricky; the exact indices might vary or might need all.
    # A common approach is to bind-mount the whole directory or specific known caps.
    # For simplicity, and based on typical setups, binding the main caps directory or specific ones found is common.
    # If specific caps are needed, they can be added like:
    # echo "lxc.mount.entry: /dev/nvidia-caps/nvidia-cap$index dev/nvidia-caps/nvidia-cap$index none bind,optional,create=file" >> "$config_file"
    # However, often it's sufficient to bind the main uvm and control devices.
    # Let's stick to the core mounts added above for now.

    log_info "configure_lxc_gpu_passthrough: Full GPU passthrough configured for container $lxc_id with indices: $gpu_assignment"
    return 0
}


# --- System Prerequisites Check ---
check_system_requirements() {
    local checks_passed=0
    local checks_failed=0

    # Check if running as root (recommended for LXC operations)
    if [[ $EUID -eq 0 ]]; then
        log_info "check_system_requirements: Running with root privileges"
        ((checks_passed++))
    else
        log_warn "check_system_requirements: Not running as root. Some operations may fail."
        ((checks_failed++))
    fi

    # Check for required tools
    local required_tools=("jq" "pct" "nvidia-smi")
    for tool in "${required_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            log_info "check_system_requirements: Found required tool: $tool"
            ((checks_passed++))
        else
            log_error "check_system_requirements: Required tool not found: $tool"
            ((checks_failed++))
        fi
    done

    # Check available disk space (example check: at least 1GB free in root)
    local required_space_kb=1048576 # 1 GB in KB
    local available_space_kb
    available_space_kb=$(df / | awk 'NR==2 {print $4}')
    if [[ "$available_space_kb" -ge "$required_space_kb" ]]; then
        log_info "check_system_requirements: Available space on root partition: $available_space_kb KB"
        ((checks_passed++))
    else
        log_error "check_system_requirements: Insufficient space on root partition. Required: $required_space_kb KB, Available: $available_space_kb KB"
        ((checks_failed++))
    fi

    # Summary
    log_info "check_system_requirements: System requirements check: $checks_passed passed, $checks_failed failed"
    if [[ $checks_failed -gt 0 ]]; then
        return 1
    fi
    return 0
}

# --- System Information Display ---
show_system_info() {
    log_info "show_system_info: System Information:"
    log_info "show_system_info: -"

    # Show Proxmox version if available (basic check)
    if command -v pveversion >/dev/null 2>&1; then
        local pve_version
        pve_version=$(pveversion 2>/dev/null | head -n 1)
        log_info "show_system_info: Proxmox Version: $pve_version"
    elif command -v pct >/dev/null 2>&1; then
        log_info "show_system_info: Proxmox LXC tools: Available"
    else
        log_info "show_system_info: Proxmox LXC tools: Not found"
    fi

    # Show NVIDIA driver info
    if command -v nvidia-smi >/dev/null 2>&1; then
        local driver_version
        driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits | head -n 1 | tr -d ' ')
        log_info "show_system_info: Host NVIDIA driver version: $driver_version"

        local gpu_count
        gpu_count=$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits | head -n 1 | tr -d ' ')
        log_info "show_system_info: Available NVIDIA GPUs: $gpu_count"
    else
        log_info "show_system_info: NVIDIA tools (nvidia-smi): Not found"
    fi

    # Show available space
    local available_space_kb
    available_space_kb=$(df / | awk 'NR==2 {print $4}')
    log_info "show_system_info: Available space on root partition: $available_space_kb KB"
}


# --- LXC Creation Process ---
create_lxc_container() {
    local container_id="$1"
    local container_config="$2" # JSON string for the container config

    if [[ -z "$container_id" ]] || [[ -z "$container_config" ]]; then
        log_error "create_lxc_container: Container ID and configuration cannot be empty"
        return 1
    fi

    # Get container details from config using jq
    local name memory_mb cores template storage_pool storage_size_gb network_config features

    name=$(echo "$container_config" | jq -r ".name // \"container-$container_id\"")
    memory_mb=$(echo "$container_config" | jq -r ".memory_mb // 1024")
    cores=$(echo "$container_config" | jq -r ".cores // 1")
    template=$(echo "$container_config" | jq -r ".template // \"\"")
    storage_pool=$(echo "$container_config" | jq -r ".storage_pool // \"local\"")
    storage_size_gb=$(echo "$container_config" | jq -r ".storage_size_gb // \"32\"")
    network_config=$(echo "$container_config" | jq -r ".network_config // \"\"")
    features=$(echo "$container_config" | jq -r ".features // \"keyctl=1\"")

    # Validate required parameters
    if [[ -z "$template" ]]; then
        log_error "create_lxc_container: Template path is required for container $container_id"
        return 1
    fi

    # Build the pct create command
    local pct_cmd=("pct" "create" "$container_id" "$template")
    pct_cmd+=("--memory" "$memory_mb")
    pct_cmd+=("--cores" "$cores")
    pct_cmd+=("--storage" "$storage_pool")
    pct_cmd+=("--rootfs" "$storage_pool:$storage_size_gb")

    if [[ -n "$network_config" ]]; then
        pct_cmd+=("--net0" "name=eth0,bridge=vmbr0,$network_config")
    fi

    pct_cmd+=("--features" "$features")
    pct_cmd+=("--unprivileged" "0") # Run privileged for GPU access
    pct_cmd+=("--hostname" "$name")

    log_info "create_lxc_container: Creating LXC container $container_id with name '$name'"

    # Execute the command
    # Use '|| true' to prevent set -e from exiting the function/script if pct fails,
    # allowing us to handle the error explicitly.
    if "${pct_cmd[@]}" > /dev/null; then
        log_info "create_lxc_container: LXC container $container_id created successfully"
    else
        log_error "create_lxc_container: Failed to create LXC container $container_id"
        return 1
    fi

    # Configure GPU passthrough after creation
    local gpu_assignment
    gpu_assignment=$(get_gpu_assignment "$container_id")
    if [[ -n "$gpu_assignment" ]] && [[ "$gpu_assignment" != "none" ]]; then
        if ! configure_lxc_gpu_passthrough "$container_id" "$gpu_assignment"; then
            log_error "create_lxc_container: Failed to configure GPU passthrough for container $container_id"
            # Depending on policy, you might want to destroy the container here on failure
            # destroy_container "$container_id" # Uncomment if rollback is desired
            return 1
        fi
    fi

    # Start the container
    log_info "create_lxc_container: Starting container $container_id..."
    if pct start "$container_id" > /dev/null; then
        log_info "create_lxc_container: Container $container_id started successfully"
    else
        log_error "create_lxc_container: Failed to start container $container_id"
        return 1
    fi

    return 0
}

# --- Container Processing ---
process_container() {
    local container_id="$1"
    local container_config="$2"

    if [[ -z "$container_id" ]] || [[ -z "$container_config" ]]; then
        log_error "process_container: Container ID and configuration cannot be empty"
        return 1
    fi

    # Validate container configuration
    if ! validate_container_config "$container_id"; then
        log_error "process_container: Invalid configuration for container $container_id"
        return 1
    fi

    # Create the container
    if ! create_lxc_container "$container_id" "$container_config"; then
        log_error "process_container: Failed to create or start container $container_id"
        # Rollback if enabled
        if [[ "${ROLLBACK_ON_FAILURE:-false}" == "true" ]]; then
            log_warn "process_container: Rollback enabled. Attempting to destroy container $container_id..."
            # destroy_container "$container_id" # Implement destroy_container function if needed
        fi
        return 1
    fi

    log_info "process_container: Container $container_id processed successfully"
    return 0
}

# --- Container Configuration Validation ---
validate_container_config() {
    local container_id="$1"

    if [[ -z "$container_id" ]]; then
        log_error "validate_container_config: Container ID cannot be empty"
        return 1
    fi

    # Check if jq is available for detailed validation
    if ! command -v jq >/dev/null 2>&1; then
        log_warn "validate_container_config: jq not available, skipping detailed validation"
        return 0
    fi

    # This function now relies on the global LXC_CONFIGS being loaded
    # or the config file being readable.
    # Check if the container ID exists in the config file or LXC_CONFIGS
    local config_exists_via_file=false
    local config_exists_via_array=false

    # Check via LXC_CONFIGS array (if populated)
    if declare -p LXC_CONFIGS > /dev/null 2>&1; then
        if [[ -n "${LXC_CONFIGS[$container_id]:-}" ]]; then
            config_exists_via_array=true
        fi
    fi

    # Check via config file (fallback)
    if [[ -n "${PHOENIX_LXC_CONFIG_FILE:-}" ]] && [[ -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
         if jq -e ".lxc_configs | has(\"$container_id\")" "$PHOENIX_LXC_CONFIG_FILE" >/dev/null 2>&1; then
             config_exists_via_file=true
         fi
    fi

    if [[ "$config_exists_via_array" == "false" ]] && [[ "$config_exists_via_file" == "false" ]]; then
        log_error "validate_container_config: Configuration for container ID $container_id not found in LXC_CONFIGS or $PHOENIX_LXC_CONFIG_FILE"
        return 1
    fi

    # Validate GPU assignment if present
    local gpu_assignment
    gpu_assignment=$(get_gpu_assignment "$container_id")
    if ! validate_gpu_assignment "$container_id" "$gpu_assignment"; then
        log_error "validate_container_config: Invalid GPU assignment for container $container_id"
        return 1
    fi

    # Add more validation checks here as needed (e.g., template path exists, storage pool valid)
    # For now, assume basic structure from jq check and GPU validation is sufficient.

    return 0
}

# --- Hypervisor Configuration Loading ---
load_hypervisor_config() {
    log_info "load_hypervisor_config: Loading hypervisor configuration..."

    # Check if PHOENIX_LXC_CONFIG_FILE is set and file exists/readable
    if [[ -z "${PHOENIX_LXC_CONFIG_FILE:-}" ]]; then
        log_error "load_hypervisor_config: PHOENIX_LXC_CONFIG_FILE is not set. Please source phoenix_hypervisor_config.sh."
        return 1
    fi

    if [[ ! -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        log_error "load_hypervisor_config: Configuration file not found: $PHOENIX_LXC_CONFIG_FILE"
        return 1
    fi

    if [[ ! -r "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        log_error "load_hypervisor_config: Configuration file is not readable: $PHOENIX_LXC_CONFIG_FILE"
        return 1
    fi

    # Validate JSON structure
    if ! jq empty "$PHOENIX_LXC_CONFIG_FILE" >/dev/null 2>&1; then
        log_error "load_hypervisor_config: Configuration file is not valid JSON: $PHOENIX_LXC_CONFIG_FILE"
        return 1
    fi

    # Ensure the global associative array is declared
    if ! declare -p LXC_CONFIGS > /dev/null 2>&1; then
        declare -gA LXC_CONFIGS
    elif [[ "$(declare -p LXC_CONFIGS 2>/dev/null)" != "declare -A"* ]]; then
         # If LXC_CONFIGS exists but is not an associative array, error
         log_error "load_hypervisor_config: LXC_CONFIGS variable exists but is not an associative array."
         return 1
    fi

    # Clear the array to ensure fresh load
    # Commented out to allow additive loading if needed. Uncomment if full reset is required each time.
    # for key in "${!LXC_CONFIGS[@]}"; do unset LXC_CONFIGS["$key"]; done

    # Load configurations into the global associative array
    local container_ids
    container_ids=$(jq -r '.lxc_configs | keys[]' "$PHOENIX_LXC_CONFIG_FILE" 2>/dev/null || true)
    if [[ -z "$container_ids" ]]; then
        log_warn "load_hypervisor_config: No container configurations found in $PHOENIX_LXC_CONFIG_FILE"
        # Return 0 as loading an empty config is not necessarily an error, just a warning.
        return 0
    fi

    local count=0
    while IFS= read -r id; do
        if [[ -n "$id" ]]; then
            # Store the JSON string for the container config
            LXC_CONFIGS["$id"]=$(jq -c ".lxc_configs.\"$id\"" "$PHOENIX_LXC_CONFIG_FILE")
            ((count++))
        fi
    done <<< "$container_ids"

    log_info "load_hypervisor_config: Loaded $count LXC configurations"
    return 0
}


# --- Utility Functions ---
retry_command() {
    local max_attempts="$1"
    local delay="$2"
    shift 2
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if "$@"; then
            return 0
        else
            log_warn "retry_command: Command failed (attempt $attempt/$max_attempts). Retrying in $delay seconds..."
            sleep "$delay"
            ((attempt++))
        fi
    done
    log_error "retry_command: Command failed after $max_attempts attempts."
    return 1
}

# --- Signal successful loading ---
# This flag helps scripts that source this file know it's been loaded
export PHOENIX_HYPERVISOR_COMMON_LOADED=1
