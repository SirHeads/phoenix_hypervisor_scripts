#!/bin/bash
# Phoenix Hypervisor Common Functions
# Provides reusable functions for logging, error handling, script execution, LXC management, and configuration loading.
# Version: 1.7.4
# Author: Assistant
set -euo pipefail

# --- Source Configuration for Paths ---
# Ensure phoenix_hypervisor_config.sh is sourced by the caller
if [[ -z "${HYPERVISOR_MARKER_DIR:-}" ]] || [[ -z "${HYPERVISOR_LOGFILE:-}" ]] || [[ -z "${PHOENIX_LXC_CONFIG_FILE:-}" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $0: phoenix_hypervisor_config.sh must be sourced first." >&2
    exit 1
fi

# Secret key path for encryption
PHOENIX_SECRET_KEY_FILE="${PHOENIX_SECRET_KEY_FILE:-/etc/phoenix/secret.key}"
# Path to Hugging Face token file
PHOENIX_HF_TOKEN_FILE="${PHOENIX_HF_TOKEN_FILE:-/usr/local/etc/phoenix_hf_token.conf}"

# --- Check for root privileges ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $0: This script must be run as root." >&2
        exit 1
    fi
}

# --- Logging Function ---
# Uses fd 4 for log file and stderr for INFO/WARN/ERROR
log() {
    local level="$1"
    shift
    local message="$*"
    if [[ -z "${HYPERVISOR_LOGFILE:-}" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $0: HYPERVISOR_LOGFILE variable not set" >&2
        exit 1
    fi
    # Ensure log directory exists
    local log_dir
    log_dir=$(dirname "$HYPERVISOR_LOGFILE")
    mkdir -p "$log_dir" || { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $0: Failed to create log directory: $log_dir" >&2; exit 1; }
    # Log to file via fd 4
    if [[ ! -e /proc/self/fd/4 ]]; then
        exec 4>>"$HYPERVISOR_LOGFILE"
        chmod 600 "$HYPERVISOR_LOGFILE" || { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $0: Failed to set permissions on $HYPERVISOR_LOGFILE" >&2; }
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [$level] $message" >&4
    # Output INFO, WARN, ERROR to stderr for terminal visibility
    if [[ "$level" =~ ^(INFO|WARN|ERROR)$ ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [$level] $message" >&2
    fi
}

# --- Check required tools ---
check_required_tools() {
    local required_tools=("jq" "pct" "pveversion" "lspci")
    local missing_tools=()
    log "DEBUG" "$0: Checking required tools: ${required_tools[*]}"
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log "ERROR" "$0: Required tools missing: ${missing_tools[*]}"
        log "INFO" "$0: Please install them (e.g., 'apt-get install jq pciutils')."
        exit 1
    fi
    log "INFO" "$0: All required tools are installed"
}

# --- Validate storage pool ---
validate_storage_pool() {
    local storage_pool="$1"
    log "DEBUG" "$0: Validating storage pool: $storage_pool"
    if ! pvesm status | grep -q "^$storage_pool.*active.*1"; then
        log "ERROR" "$0: Storage pool $storage_pool is not active or does not exist"
        pvesm status | while read -r line; do log "DEBUG" "$0: pvesm: $line"; done
        exit 1
    fi
    # Determine ZFS pool name for validation
    if [[ "$storage_pool" == "lxc-disks" ]]; then
        local zfs_pool_name="${PHOENIX_ZFS_LXC_POOL:-quickOS/lxc-disks}"
        if ! validate_zfs_pool "$zfs_pool_name"; then
            log "ERROR" "$0: ZFS pool validation failed for $zfs_pool_name"
            exit 1
        fi
    fi
    log "INFO" "$0: Storage pool $storage_pool validated"
}

# --- Load hypervisor configuration ---
load_hypervisor_config() {
    check_root
    check_required_tools
    validate_json_config "$PHOENIX_LXC_CONFIG_FILE"

    # Schema Validation
    local schema_file="${PHOENIX_LXC_CONFIG_SCHEMA_FILE:-/usr/local/etc/phoenix_lxc_configs.schema.json}"
    if [[ -f "$schema_file" ]]; then
        validate_json_schema "$PHOENIX_LXC_CONFIG_FILE" "$schema_file"
    else
        log "WARN" "$0: JSON schema file not found at $schema_file. Skipping schema validation."
    fi

    # Ensure Hugging Face token is available
    prompt_for_hf_token

    declare -gA LXC_CONFIGS
    declare -gA LXC_SETUP_SCRIPTS

    log "INFO" "$0: Loading LXC configurations from $PHOENIX_LXC_CONFIG_FILE"

    while IFS=$'\t' read -r id name memory_mb cores template storage_pool storage_size_gb network_config features vllm_model vllm_tensor_parallel_size vllm_max_model_len vllm_kv_cache_dtype vllm_shm_size vllm_gpu_count vllm_quantization vllm_quantization_config_type vllm_api_port setup_script; do
        if [[ -n "$storage_pool" ]]; then
            validate_storage_pool "$storage_pool"
        fi

        LXC_CONFIGS["$id"]="$name"$'\t'"$memory_mb"$'\t'"$cores"$'\t'"$template"$'\t'"$storage_pool"$'\t'"$storage_size_gb"$'\t'"$network_config"$'\t'"$features"$'\t'"$vllm_model"$'\t'"$vllm_tensor_parallel_size"$'\t'"$vllm_max_model_len"$'\t'"$vllm_kv_cache_dtype"$'\t'"$vllm_shm_size"$'\t'"$vllm_gpu_count"$'\t'"$vllm_quantization"$'\t'"$vllm_quantization_config_type"$'\t'"$vllm_api_port"
        if [[ -n "$setup_script" ]]; then
            if [[ ! -x "$setup_script" ]]; then
                log "ERROR" "$0: Setup script for LXC $id is not executable: $setup_script"
                exit 1
            fi
            LXC_SETUP_SCRIPTS["$id"]="$setup_script"
            log "DEBUG" "$0: Loaded setup script for LXC $id: $setup_script"
        fi
        log "DEBUG" "$0: Loaded LXC $id: $name, storage_pool=$storage_pool, vllm_model=$vllm_model, vllm_api_port=$vllm_api_port"
    done < <(jq -r '.lxc_configs | to_entries[] |
        [.key, .value.name // "", .value.memory_mb // "", .value.cores // "", .value.template // "", .value.storage_pool // "", .value.storage_size_gb // "", .value.network_config // "", .value.features // "", .value.vllm_model // "", .value.vllm_tensor_parallel_size // "", .value.vllm_max_model_len // "", .value.vllm_kv_cache_dtype // "", .value.vllm_shm_size // "", .value.vllm_gpu_count // "", .value.vllm_quantization // "", .value.vllm_quantization_config_type // "", .value.vllm_api_port // "", .value.setup_script // ""] | @tsv' "$PHOENIX_LXC_CONFIG_FILE")

    if [[ ${#LXC_CONFIGS[@]} -eq 0 ]]; then
        log "WARN" "$0: No LXC configurations found in $PHOENIX_LXC_CONFIG_FILE"
    fi
    if [[ ${#LXC_SETUP_SCRIPTS[@]} -eq 0 ]]; then
        log "WARN" "$0: No setup scripts defined in LXC configurations"
    fi

    export LXC_CONFIGS
    export LXC_SETUP_SCRIPTS

    log "INFO" "$0: Phoenix Hypervisor configuration variables loaded and validated"
}

# --- Validate ZFS pool ---
validate_zfs_pool() {
    local pool_name="$1"
    log "DEBUG" "$0: Validating ZFS pool: $pool_name"
    if ! zfs list "$pool_name" >/dev/null 2>&1; then
        log "ERROR" "$0: ZFS dataset $pool_name does not exist"
        zpool list | while read -r line; do log "DEBUG" "$0: zpool: $line"; done
        return 1
    fi
    if ! zfs get -H -o value mounted "$pool_name" | grep -q "yes"; then
        log "INFO" "$0: ZFS dataset $pool_name not mounted, attempting to mount"
        zfs mount "$pool_name" || { log "ERROR" "$0: Failed to mount $pool_name"; return 1; }
    fi
    log "INFO" "$0: ZFS pool $pool_name is available and mounted"
    return 0
}

# --- Validate JSON config file ---
validate_json_config() {
    local config_file="$1"
    log "DEBUG" "$0: Validating JSON config file: $config_file"
    if [[ ! -f "$config_file" ]]; then
        log "ERROR" "$0: JSON config file not found: $config_file"
        exit 1
    fi
    if ! jq . "$config_file" >/dev/null 2>&1; then
        log "ERROR" "$0: JSON config file is invalid or unreadable: $config_file"
        exit 1
    fi
    log "INFO" "$0: JSON config file validated: $config_file"
}

# --- Generate Host Key for Encryption ---
generate_host_key() {
    local key_file="$PHOENIX_SECRET_KEY_FILE"
    local key_dir
    key_dir=$(dirname "$key_file")
    if [[ ! -f "$key_file" ]]; then
        log "INFO" "$0: Generating host-specific encryption key: $key_file"
        mkdir -p "$key_dir" || { log "ERROR" "$0: Failed to create key directory: $key_dir"; exit 1; }
        openssl rand -hex 32 > "$key_file" || { log "ERROR" "$0: Failed to generate encryption key"; exit 1; }
        chmod 600 "$key_file" || { log "ERROR" "$0: Failed to set permissions on $key_file"; exit 1; }
        log "INFO" "$0: Host encryption key generated and secured."
    else
        log "DEBUG" "$0: Host encryption key already exists: $key_file"
    fi
}

# --- Encrypt Data ---
encrypt_data() {
    local data="$1"
    local key_file="$PHOENIX_SECRET_KEY_FILE"
    if [[ ! -f "$key_file" ]]; then
        log "ERROR" "$0: Encryption key file not found: $key_file"
        exit 1
    fi
    echo -n "$data" | openssl enc -aes-256-gcm -pbkdf2 -iter 10000 -salt -pass "file:$key_file" -a -md sha256 2>/dev/null
}

# --- Decrypt Data ---
decrypt_data() {
    local encrypted_data_b64="$1"
    local key_file="$PHOENIX_SECRET_KEY_FILE"
    if [[ ! -f "$key_file" ]]; then
        log "ERROR" "$0: Encryption key file not found: $key_file"
        exit 1
    fi
    echo "$encrypted_data_b64" | openssl enc -aes-256-gcm -pbkdf2 -iter 10000 -salt -pass "file:$key_file" -d -a -md sha256 2>/dev/null
}

# --- Save Encrypted Secret ---
save_encrypted_secret() {
    local secret_data="$1"
    local secret_file_path="$2"
    local secret_dir
    secret_dir=$(dirname "$secret_file_path")
    generate_host_key || exit 1
    log "DEBUG" "$0: Saving encrypted secret to $secret_file_path"
    mkdir -p "$secret_dir" || { log "ERROR" "$0: Failed to create secret directory: $secret_dir"; exit 1; }
    local encrypted_b64
    encrypted_b64=$(encrypt_data "$secret_data") || { log "ERROR" "$0: Failed to encrypt secret data"; exit 1; }
    echo "$encrypted_b64" > "$secret_file_path" || { log "ERROR" "$0: Failed to write encrypted secret to $secret_file_path"; exit 1; }
    chmod 600 "$secret_file_path" || { log "WARN" "$0: Failed to set permissions on $secret_file_path"; }
    log "INFO" "$0: Encrypted secret saved to $secret_file_path"
}

# --- Load Encrypted Secret ---
load_encrypted_secret() {
    local secret_file_path="$1"
    if [[ ! -f "$secret_file_path" ]]; then
        log "DEBUG" "$0: Secret file not found: $secret_file_path"
        return 1
    fi
    log "DEBUG" "$0: Loading encrypted secret from $secret_file_path"
    if [[ ! -f "$PHOENIX_SECRET_KEY_FILE" ]]; then
        log "ERROR" "$0: Host encryption key not found: $PHOENIX_SECRET_KEY_FILE"
        exit 1
    fi
    local encrypted_b64
    encrypted_b64=$(cat "$secret_file_path") || { log "ERROR" "$0: Failed to read secret file: $secret_file_path"; exit 1; }
    local decrypted_data
    decrypted_data=$(decrypt_data "$encrypted_b64") || { log "ERROR" "$0: Failed to decrypt secret from $secret_file_path (wrong key or corrupt data)"; exit 1; }
    echo "$decrypted_data"
    log "INFO" "$0: Encrypted secret loaded from $secret_file_path"
}

# --- Prompt for Hugging Face token ---
prompt_for_hf_token() {
    local token_file="$PHOENIX_HF_TOKEN_FILE"
    local token_input
    local token_confirm
    local attempts=0
    local max_attempts=3
    log "DEBUG" "$0: Checking for HUGGING_FACE_HUB_TOKEN"
    if [[ -n "${HUGGING_FACE_HUB_TOKEN:-}" ]]; then
        log "INFO" "$0: HUGGING_FACE_HUB_TOKEN found in environment"
        return 0
    fi
    if [[ -f "$token_file" ]]; then
        log "DEBUG" "$0: Loading HUGGING_FACE_HUB_TOKEN from $token_file"
        HUGGING_FACE_HUB_TOKEN=$(load_encrypted_secret "$token_file")
        if [[ -n "$HUGGING_FACE_HUB_TOKEN" ]]; then
            export HUGGING_FACE_HUB_TOKEN
            log "INFO" "$0: HUGGING_FACE_HUB_TOKEN loaded from $token_file"
            return 0
        else
            log "WARN" "$0: Failed to load or decrypt HUGGING_FACE_HUB_TOKEN from $token_file"
        fi
    fi
    if [[ ! -t 0 ]]; then
        log "ERROR" "$0: Non-interactive environment detected and no HUGGING_FACE_HUB_TOKEN provided"
        exit 1
    fi
    log "INFO" "$0: HUGGING_FACE_HUB_TOKEN not found. Prompting user..."
    while [[ $attempts -lt $max_attempts ]]; do
        read -s -p "Enter Hugging Face Hub token: " token_input
        echo >&2
        if [[ -z "$token_input" ]]; then
            ((attempts++))
            log "WARN" "$0: Token cannot be empty. Attempt $attempts/$max_attempts."
            echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] Token cannot be empty. Attempt $attempts/$max_attempts." >&2
            continue
        fi
        read -s -p "Confirm token: " token_confirm
        echo >&2
        if [[ "$token_input" != "$token_confirm" ]]; then
            ((attempts++))
            log "WARN" "$0: Tokens do not match. Attempt $attempts/$max_attempts."
            echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] Tokens do not match. Attempt $attempts/$max_attempts." >&2
            continue
        fi
        log "INFO" "$0: Token confirmed"
        export HUGGING_FACE_HUB_TOKEN="$token_input"
        save_encrypted_secret "$token_input" "$token_file" || { log "ERROR" "$0: Failed to save encrypted token to $token_file"; exit 1; }
        log "INFO" "$0: HUGGING_FACE_HUB_TOKEN saved (encrypted) to $token_file"
        return 0
    done
    log "ERROR" "$0: Maximum token attempts ($max_attempts) reached"
    exit 1
}

# --- Retry a command ---
retry_command() {
    local command="$1"
    local retries="${2:-3}"
    local delay="${3:-5}"
    local attempt=0
    local output
    until [[ $attempt -ge $retries ]]; do
        attempt=$((attempt + 1))
        log "INFO" "$0: Executing (attempt $attempt/$retries): $command"
        if output=$(eval "$command" 2>&1); then
            log "INFO" "$0: Command succeeded: $command"
            return 0
        else
            local exit_code=$?
            log "WARN" "$0: Command failed (attempt $attempt/$retries, exit code: $exit_code): $command"
            log "DEBUG" "$0: Command output: $output"
            if [[ $attempt -lt $retries ]]; then
                log "INFO" "$0: Waiting $delay seconds before retrying..."
                sleep "$delay"
            fi
        fi
    done
    log "ERROR" "$0: Command failed after $retries attempts: $command"
    return $exit_code
}

# --- Execute command in LXC ---
execute_in_lxc() {
    local lxc_id="$1"
    local command="$2"
    local output
    if [[ -z "$lxc_id" ]] || [[ -z "$command" ]]; then
        log "ERROR" "$0: execute_in_lxc requires lxc_id and command arguments"
        exit 1
    fi
    log "DEBUG" "$0: Executing in LXC $lxc_id: $command"
    if output=$(pct exec "$lxc_id" -- bash -c "$command" 2>&1); then
        log "DEBUG" "$0: Command in LXC $lxc_id succeeded: $command"
        echo "$output"
        return 0
    else
        local exit_code=$?
        log "ERROR" "$0: Command in LXC $lxc_id failed (exit code: $exit_code): $command"
        log "DEBUG" "$0: Command output: $output"
        return $exit_code
    fi
}

# --- Check if a script has already been completed ---
is_script_completed() {
    local marker_file="$1"
    if [[ -f "$marker_file" ]]; then
        log "DEBUG" "$0: Marker file found: $marker_file"
        return 0
    else
        log "DEBUG" "$0: Marker file not found: $marker_file"
        return 1
    fi
}

# --- Mark a script as completed ---
mark_script_completed() {
    local marker_file="$1"
    local marker_dir
    marker_dir=$(dirname "$marker_file")
    mkdir -p "$marker_dir" || { log "ERROR" "$0: Failed to create marker directory: $marker_dir"; exit 1; }
    touch "$marker_file" || { log "ERROR" "$0: Failed to create marker file: $marker_file"; exit 1; }
    log "INFO" "$0: Marked script completed: $marker_file"
}

# --- Wait for LXC container to be running ---
wait_for_lxc_running() {
    local lxc_id="$1"
    local max_attempts=30
    local attempt=1
    log "INFO" "$0: Ensuring LXC $lxc_id is running..."
    while [[ $attempt -le $max_attempts ]]; do
        if pct status "$lxc_id" | grep -q "status: running"; then
            log "INFO" "$0: LXC $lxc_id is running."
            return 0
        fi
        log "DEBUG" "$0: LXC $lxc_id not running yet (attempt $attempt/$max_attempts). Waiting 2 seconds..."
        sleep 2
        ((attempt++))
    done
    log "ERROR" "$0: LXC $lxc_id failed to start after $max_attempts attempts."
    return 1
}

# --- Wait for networking to be available in LXC ---
wait_for_lxc_network() {
    local lxc_id="$1"
    local max_attempts=30
    local attempt=1
    log "INFO" "$0: Ensuring networking is available in LXC $lxc_id..."
    while [[ $attempt -le $max_attempts ]]; do
        if execute_in_lxc "$lxc_id" "ping -c 1 8.8.8.8" >/dev/null 2>&1; then
            log "INFO" "$0: Networking is ready in LXC $lxc_id."
            return 0
        fi
        log "DEBUG" "$0: Networking not ready in LXC $lxc_id (attempt $attempt/$max_attempts). Waiting 2 seconds..."
        sleep 2
        ((attempt++))
    done
    log "ERROR" "$0: Networking failed to become available in LXC $lxc_id after $max_attempts attempts."
    return 1
}

# --- Input Sanitization Utilities ---
sanitize_input() {
    local input="$1"
    local sanitized
    sanitized=$(echo "$input" | sed 's/[;&|><`$(){}\[\]*?!~#^"'"'"']//g')
    echo "$sanitized"
}

validate_lxc_id() {
    local id="$1"
    if [[ "$id" =~ ^[0-9]+$ ]] && [[ "$id" -gt 0 ]]; then
        return 0
    else
        return 1
    fi
}

validate_network_cidr() {
    local cidr="$1"
    if [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2},([0-9]{1,3}\.){3}[0-9]{1,3},([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$cidr" =~ ^name=[a-zA-Z0-9_-]+,bridge=[a-zA-Z0-9_-]+,ip=dhcp$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_numeric() {
    local value="$1"
    if [[ "$value" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
        return 0
    else
        return 1
    fi
}

# --- Get GPU device details for passthrough ---
detect_gpu_details() {
    local gpu_indices="$1"
    declare -gA GPU_DETAILS
    declare -g GPU_MAJOR_NUMBERS=""
    local major_numbers=()
    log "INFO" "$0: Detecting GPU details for indices: $gpu_indices"
    if [[ -z "$gpu_indices" ]]; then
        log "INFO" "$0: No GPU indices provided. Skipping GPU detection."
        return 0
    fi
    # Try nvidia-smi first
    local all_gpu_info=""
    if command -v nvidia-smi >/dev/null 2>&1; then
        all_gpu_info=$(nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader,nounits 2>/dev/null)
        if [[ $? -eq 0 ]] && [[ -n "$all_gpu_info" ]]; then
            log "DEBUG" "$0: nvidia-smi output: $all_gpu_info"
        else
            log "WARN" "$0: nvidia-smi failed or returned no data. Falling back to lspci."
            all_gpu_info=""
        fi
    fi
    # Fallback to lspci if nvidia-smi is unavailable or failed
    if [[ -z "$all_gpu_info" ]]; then
        all_gpu_info=$(lspci -d 10de: -n | awk '{print NR-1 "," $1}' 2>/dev/null)
        if [[ $? -ne 0 ]] || [[ -z "$all_gpu_info" ]]; then
            log "ERROR" "$0: No NVIDIA GPUs detected via lspci for indices: $gpu_indices"
            return 1
        fi
        log "DEBUG" "$0: lspci output (formatted): $all_gpu_info"
    fi
    local found_valid_gpu=0
    for index in $gpu_indices; do
        if ! validate_lxc_id "$index"; then
            log "ERROR" "$0: Invalid GPU index format: '$index'"
            return 1
        fi
        local gpu_line
        gpu_line=$(echo "$all_gpu_info" | grep "^$index,")
        if [[ -z "$gpu_line" ]]; then
            log "ERROR" "$0: GPU index $index not found in GPU information"
            return 1
        fi
        local pci_bus_id
        pci_bus_id=$(echo "$gpu_line" | cut -d',' -f2 | sed 's/^00000000:/0000:/')
        log "DEBUG" "$0: Found GPU $index with PCI Bus ID: $pci_bus_id"
        # Define NVIDIA device files
        local device_files=("/dev/nvidia${index}" "/dev/nvidia-ctl" "/dev/nvidia-modeset" "/dev/nvidia-uvm" "/dev/nvidia-uvm-tools" "/dev/nvidia-caps/nvidia-cap1" "/dev/nvidia-caps/nvidia-cap2")
        device_files+=("/dev/dri/card${index}" "/dev/dri/renderD$((128 + index))")
        local existing_device_files=()
        for device in "${device_files[@]}"; do
            if [[ -e "$device" ]]; then
                existing_device_files+=("$device")
                local major
                major=$(stat -c %t "$device" 2>/dev/null)
                if [[ -n "$major" ]]; then
                    local dec_major
                    dec_major=$((16#$major))
                    if [[ ! " ${major_numbers[*]} " =~ " ${dec_major} " ]]; then
                        major_numbers+=("$dec_major")
                        log "DEBUG" "$0: Detected major number $dec_major for device $device"
                    fi
                fi
            else
                log "DEBUG" "$0: Device file $device for GPU $index does not exist, skipping."
            fi
        done
        if [[ ${#existing_device_files[@]} -gt 0 ]]; then
            GPU_DETAILS["$index"]="$pci_bus_id,$(IFS=','; echo "${existing_device_files[*]}")"
            log "INFO" "$0: Detected GPU $index (PCI: $pci_bus_id) with devices: $(IFS=','; echo "${existing_device_files[*]}")"
            found_valid_gpu=1
        else
            log "ERROR" "$0: No device files found for GPU $index (PCI: $pci_bus_id)"
            return 1
        fi
    done
    if [[ $found_valid_gpu -eq 0 ]]; then
        log "ERROR" "$0: No valid GPUs detected for indices: $gpu_indices"
        return 1
    fi
    GPU_MAJOR_NUMBERS=$(IFS=','; echo "${major_numbers[*]}")
    log "INFO" "$0: Detected GPU major device numbers for cgroup rules: $GPU_MAJOR_NUMBERS"
    return 0
}

# --- Configure GPU passthrough for LXC ---
configure_lxc_gpu_passthrough() {
    local lxc_id="$1"
    local gpu_indices="$2"
    local config_file="/etc/pve/lxc/$lxc_id.conf"
    local marker_file="${PHOENIX_HYPERVISOR_LXC_GPU_MARKER/lxc_id/$lxc_id}"
    if is_script_completed "$marker_file"; then
        log "INFO" "$0: GPU passthrough for LXC $lxc_id already configured. Skipping."
        return 0
    fi
    if [[ -z "$lxc_id" ]] || [[ -z "$gpu_indices" ]]; then
        log "ERROR" "$0: No LXC ID or GPU indices provided for $lxc_id"
        return 1
    fi
    if [[ ! -f "$config_file" ]]; then
        log "ERROR" "$0: LXC config file not found: $config_file"
        return 1
    fi
    log "INFO" "$0: Configuring GPU passthrough for LXC $lxc_id using indices: '$gpu_indices'"
    if ! detect_gpu_details "$gpu_indices"; then
        log "ERROR" "$0: GPU detection failed for LXC $lxc_id with indices: $gpu_indices"
        return 1
    fi
    if [[ ${#GPU_DETAILS[@]} -eq 0 ]]; then
        log "ERROR" "$0: No valid GPU details detected for LXC $lxc_id with indices: $gpu_indices"
        return 1
    fi
    local tmpfile
    tmpfile=$(mktemp) || { log "ERROR" "$0: Failed to create temporary file for LXC config"; return 1; }
    cp "$config_file" "${config_file}.backup-$(date +%Y%m%d%H%M%S)" || { log "ERROR" "$0: Failed to backup $config_file"; return 1; }
    grep -v -E "^(lxc\.cgroup2\.devices\.allow.*c (195|510|226):|lxc\.mount\.entry.*(nvidia|dri))" "$config_file" > "$tmpfile"
    if [[ -n "$GPU_MAJOR_NUMBERS" ]]; then
        IFS=',' read -ra major_nums <<< "$GPU_MAJOR_NUMBERS"
        for major in "${major_nums[@]}"; do
            echo "lxc.cgroup2.devices.allow: c $major:* rwm" >> "$tmpfile"
            log "DEBUG" "$0: Added cgroup rule for major $major to $config_file"
        done
    else
        log "ERROR" "$0: No GPU major numbers detected for LXC $lxc_id"
        mv "${config_file}.backup-$(date +%Y%m%d%H%M%S)" "$config_file" || log "WARN" "$0: Failed to restore $config_file backup"
        rm -f "$tmpfile"
        return 1
    fi
    for index in $gpu_indices; do
        if [[ -n "${GPU_DETAILS[$index]}" ]]; then
            local gpu_data="${GPU_DETAILS[$index]}"
            IFS=',' read -ra device_files <<< "${gpu_data#*,}"
            for dev in "${device_files[@]}"; do
                if [[ -n "$dev" && -e "$dev" ]] && ! grep -q "lxc.mount.entry: $dev" "$config_file"; then
                    echo "lxc.mount.entry: $dev ${dev#/dev/} none bind,optional,create=file" >> "$tmpfile"
                    log "DEBUG" "$0: Added mount entry for $dev to $config_file"
                fi
            done
        fi
    done
    mv "$tmpfile" "$config_file" || { log "ERROR" "$0: Failed to update $config_file"; mv "${config_file}.backup-$(date +%Y%m%d%H%M%S)" "$config_file" || log "WARN" "$0: Failed to restore $config_file backup"; return 1; }
    chmod 600 "$config_file" || { log "WARN" "$0: Failed to set permissions on $config_file"; }
    log "INFO" "$0: GPU passthrough configured for LXC $lxc_id."
    mark_script_completed "$marker_file"
    return 0
}

# --- Schema Validation Hook ---
validate_json_schema() {
    local config_file="$1"
    local schema_file="$2"
    log "DEBUG" "$0: Attempting to validate JSON schema"
    if ! command -v check-jsonschema >/dev/null 2>&1; then
        log "INFO" "$0: check-jsonschema not found, attempting to install..."
        if ! apt-get update && apt-get install -y python3-pip && pip3 install check-jsonschema; then
            log "ERROR" "$0: Failed to install check-jsonschema"
            echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] check-jsonschema is required for JSON validation." >&2
            exit 1
        fi
    fi
    log "INFO" "$0: Validating $config_file against $schema_file using check-jsonschema"
    if check-jsonschema --schemafile "$schema_file" "$config_file"; then
        log "INFO" "$0: JSON schema validation passed."
        return 0
    else
        log "ERROR" "$0: JSON schema validation failed with check-jsonschema."
        exit 1
    fi
}