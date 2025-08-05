#!/bin/bash
# Common functions for Phoenix Hypervisor scripts.
# Version: 1.7.3
# Author: Assistant

# --- Enhanced User Experience Functions ---
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $1" >&2
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $1" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $1" >&2
}

prompt_user() {
    local prompt="$1"
    local default="${2:-}"
    read -p "$prompt [$default]: " response
    echo "${response:-$default}"
}

# --- Enhanced Logging Function ---
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

# --- Enhanced Validation Functions ---
validate_storage_pool() {
    local pool_name="$1"
    log_info "Validating storage pool: $pool_name"
    
    # Check if ZFS pool exists
    if ! zpool list "$pool_name" >/dev/null 2>&1; then
        log_error "ZFS pool '$pool_name' not found. Please create it first."
        exit 1
    fi
    
    # Check if pool is healthy
    local pool_status
    pool_status=$(zpool status "$pool_name" | grep -E "online|degraded" | head -n1)
    if [[ ! "$pool_status" =~ online ]]; then
        log_warn "ZFS pool '$pool_name' is not in online state: $pool_status"
    fi
    
    log_info "Storage pool '$pool_name' validated successfully."
}

validate_lxc_id() {
    local lxc_id="$1"
    
    # Check if it's a valid numeric ID
    if ! [[ "$lxc_id" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    # Check if ID is in valid range (typically 100-999 for containers)
    if [[ "$lxc_id" -lt 100 ]] || [[ "$lxc_id" -gt 999 ]]; then
        log_warn "LXC ID $lxc_id is outside typical range (100-999)"
    fi
    
    return 0
}

# --- Enhanced Schema Validation ---
validate_json_schema() {
    local json_file="$1"
    local schema_file="$2"
    
    log_info "Validating JSON schema for $json_file against $schema_file"
    
    if [[ ! -f "$json_file" ]]; then
        log_error "JSON file not found: $json_file"
        return 1
    fi
    
    if [[ ! -f "$schema_file" ]]; then
        log_warn "Schema file not found: $schema_file. Skipping validation."
        return 0
    fi
    
    # Try to validate with jq (if available)
    if command -v jq >/dev/null 2>&1; then
        if ! jq -S -e --argjson schema "$(jq -c . "$schema_file")" '. as $data | $schema | . as $schema | ($data | $schema) | true' "$json_file" >/dev/null 2>&1; then
            log_error "JSON validation failed for $json_file"
            return 1
        fi
    else
        log_warn "jq not found, skipping JSON schema validation."
    fi
    
    log_info "JSON schema validation passed for $json_file"
}

# --- Enhanced Configuration Loading ---
load_hypervisor_config() {
    log_info "Loading hypervisor configuration..."
    
    # Validate configuration file exists
    if [[ ! -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $PHOENIX_LXC_CONFIG_FILE"
        exit 1
    fi
    
    # Validate JSON format
    if ! jq empty "$PHOENIX_LXC_CONFIG_FILE" >/dev/null 2>&1; then
        log_error "Invalid JSON in configuration file: $PHOENIX_LXC_CONFIG_FILE"
        exit 1
    fi
    
    # Load configuration into arrays
    declare -gA LXC_CONFIGS=()
    declare -gA LXC_SETUP_SCRIPTS=()
    
    # Get all LXC IDs from the config
    local lxc_ids
    lxc_ids=$(jq -r 'if (.lxc_configs | type == "object") then .lxc_configs | keys[] else empty end' "$PHOENIX_LXC_CONFIG_FILE")
    
    if [[ -z "$lxc_ids" ]]; then
        log_warn "No LXC configurations found in $PHOENIX_LXC_CONFIG_FILE"
        return 0
    fi
    
    # Process each LXC configuration
    for lxc_id in $lxc_ids; do
        local config
        config=$(jq -c ".lxc_configs[\"$lxc_id\"]" "$PHOENIX_LXC_CONFIG_FILE")
        
        if [[ -n "$config" && "$config" != "null" ]]; then
            LXC_CONFIGS["$lxc_id"]="$config"
            
            # Extract setup script path if present
            local setup_script
            setup_script=$(echo "$config" | jq -r '.setup_script // empty')
            if [[ -n "$setup_script" && "$setup_script" != "null" ]]; then
                LXC_SETUP_SCRIPTS["$lxc_id"]="$setup_script"
            fi
            
            log_info "Loaded configuration for LXC $lxc_id"
        else
            log_warn "Empty configuration for LXC $lxc_id"
        fi
    done
    
    # Show summary of loaded configurations
    local total_configs=${#LXC_CONFIGS[@]}
    if [[ "$total_configs" -gt 0 ]]; then
        echo ""
        echo "Configuration Summary:"
        echo "----------------------"
        echo "Total LXC configurations: $total_configs"
        for lxc_id in "${!LXC_CONFIGS[@]}"; do
            local name=$(echo "${LXC_CONFIGS[$lxc_id]}" | jq -r '.name')
            echo "  - Container $lxc_id: $name"
        done
        echo ""
    else
        log_warn "No LXC configurations loaded"
    fi
    
    # Validate configuration against schema if available
    local schema_file="${PHOENIX_LXC_CONFIG_SCHEMA_FILE:-/usr/local/etc/phoenix_lxc_configs.schema.json}"
    if [[ -f "$schema_file" ]]; then
        validate_json_schema "$PHOENIX_LXC_CONFIG_FILE" "$schema_file"
    else
        log_warn "JSON schema file not found at $schema_file. Skipping validation."
    fi
    
    # Ensure Hugging Face token is available
    prompt_for_hf_token
    
    log_info "Configuration loaded successfully"
}

# --- Enhanced Hugging Face Token Handling ---
prompt_for_hf_token() {
    log_info "Checking for Hugging Face token..."
    
    # Check if we have an override from command line
    if [[ -n "${HF_TOKEN_OVERRIDE:-}" ]]; then
        HUGGING_FACE_HUB_TOKEN="$HF_TOKEN_OVERRIDE"
        log_info "Using Hugging Face token from override."
        return 0
    fi
    
    # Check if token is already set in environment
    if [[ -n "${HUGGING_FACE_HUB_TOKEN:-}" ]]; then
        log_info "Hugging Face token found in environment."
        return 0
    fi
    
    # Check for existing token file
    if [[ -f "$PHOENIX_HF_TOKEN_FILE" ]]; then
        HUGGING_FACE_HUB_TOKEN=$(cat "$PHOENIX_HF_TOKEN_FILE")
        if [[ -n "$HUGGING_FACE_HUB_TOKEN" ]]; then
            log_info "Using Hugging Face token from file: $PHOENIX_HF_TOKEN_FILE"
            return 0
        fi
    fi
    
    # Prompt user for token
    echo ""
    echo "Hugging Face Token Required:"
    echo "============================="
    echo "A valid Hugging Face token is required to download models."
    echo "You can get a token from: https://huggingface.co/settings/tokens"
    echo ""
    
    while [[ -z "$HUGGING_FACE_HUB_TOKEN" ]]; do
        read -s -p "Enter your Hugging Face token: " HUGGING_FACE_HUB_TOKEN
        echo ""
        if [[ -z "$HUGGING_FACE_HUB_TOKEN" ]]; then
            echo "Token cannot be empty. Please try again."
        fi
    done
    
    # Save to file for future use (optional)
    read -p "Save token to file for future use? (yes/no): " save_token
    if [[ "$save_token" == "yes" ]]; then
        mkdir -p "$(dirname "$PHOENIX_HF_TOKEN_FILE")"
        echo "$HUGGING_FACE_HUB_TOKEN" > "$PHOENIX_HF_TOKEN_FILE"
        chmod 600 "$PHOENIX_HF_TOKEN_FILE"
        log_info "Token saved to $PHOENIX_HF_TOKEN_FILE"
    fi
    
    log_info "Hugging Face token configured successfully."
}

# --- Enhanced GPU Detection ---
detect_gpus() {
    log_info "Detecting NVIDIA GPUs..."
    
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        log_warn "nvidia-smi not found. NVIDIA drivers may not be installed."
        return 1
    fi
    
    local gpu_count
    gpu_count=$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits | tr -d ' ')
    
    if [[ "$gpu_count" -eq 0 ]]; then
        log_warn "No NVIDIA GPUs detected."
        return 1
    fi
    
    log_info "Detected $gpu_count NVIDIA GPU(s)"
    
    # Get GPU details
    local gpu_details
    gpu_details=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits | head -n1)
    log_info "GPU Details: $gpu_details"
    
    return 0
}

# --- Enhanced Retry Function ---
retry_command() {
    local max_attempts="${1:-3}"
    local delay="${2:-5}"
    shift 2
    local cmd="$*"
    
    log_info "Executing command with retries (max $max_attempts attempts): $cmd"
    
    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Attempt $attempt/$max_attempts: $cmd" >&2
        eval "$cmd"
        if [[ $? -eq 0 ]]; then
            log_info "Command succeeded on attempt $attempt"
            return 0
        fi
        log_warn "Command failed (attempt $attempt/$max_attempts): $cmd"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] Command failed, retrying in $delay seconds..." >&2
        sleep "$delay"
        ((attempt++))
    done
    
    log_error "Command failed after $max_attempts attempts: $cmd"
    return 1
}

# --- Enhanced Marker Functions ---
is_script_completed() {
    local marker_file="$1"
    if [[ -f "$marker_file" ]]; then
        grep -Fxq "$(basename "$0")" "$marker_file" 2>/dev/null
        return $?
    fi
    return 1
}

mark_script_completed() {
    local marker_file="$1"
    local script_name=$(basename "$0")
    
    # Ensure marker directory exists
    mkdir -p "$(dirname "$marker_file")"
    
    # Add to marker file
    echo "$script_name" >> "$marker_file"
    chmod 600 "$marker_file"
    
    log_info "Marked script $script_name as completed"
}

# --- Enhanced Required Tools Check ---
check_required_tools() {
    local required_tools=("jq" "pct" "pveversion" "lspci")
    local missing_tools=()
    
    log_info "Checking required tools: ${required_tools[*]}"
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Required tools missing: ${missing_tools[*]}"
        log_info "Please install them (e.g., 'apt-get install jq pciutils')."
        exit 1
    fi
    
    log_info "All required tools are installed"
}

# --- Enhanced Validation Functions ---
validate_lxc_network_config() {
    local network_config="$1"
    
    if [[ -z "$network_config" ]]; then
        log_warn "Network configuration is empty"
        return 1
    fi
    
    # Basic validation of CIDR format
    if ! echo "$network_config" | grep -qE '^[0-9.]+/[0-9]+,'; then
        log_warn "Network config may not be in expected format: $network_config"
    fi
    
    return 0
}

# --- Enhanced Initialization ---
init_hypervisor() {
    log_info "Initializing Phoenix Hypervisor environment..."
    
    # Create marker directory if needed
    mkdir -p "$HYPERVISOR_MARKER_DIR" || { log_error "Failed to create marker directory: $HYPERVISOR_MARKER_DIR"; exit 1; }
    
    # Set up logging
    if [[ -z "${HYPERVISOR_LOGFILE:-}" ]]; then
        HYPERVISOR_LOGFILE="/var/log/phoenix_hypervisor/hypervisor.log"
        mkdir -p "$(dirname "$HYPERVISOR_LOGFILE")" || { log_error "Failed to create log directory: $(dirname "$HYPERVISOR_LOGFILE")"; exit 1; }
    fi
    
    # Set permissions on log file
    touch "$HYPERVISOR_LOGFILE" || { log_error "Failed to create log file: $HYPERVISOR_LOGFILE"; exit 1; }
    chmod 600 "$HYPERVISOR_LOGFILE"
    
    log_info "Phoenix Hypervisor environment initialized"
}

# --- Load Configuration ---
log_info "Loading Phoenix Hypervisor common functions..."

# Validate that required variables are set
if [[ -z "${PHOENIX_LXC_CONFIG_FILE:-}" ]]; then
    log_error "PHOENIX_LXC_CONFIG_FILE must be set before sourcing this file."
    exit 1
fi

if [[ -z "${PHOENIX_HF_TOKEN_FILE:-}" ]]; then
    PHOENIX_HF_TOKEN_FILE="/usr/local/etc/phoenix_hf_token.conf"
fi

# Load configuration variables (this will validate and set defaults)
load_hypervisor_config

log_info "Phoenix Hypervisor common functions loaded and validated"