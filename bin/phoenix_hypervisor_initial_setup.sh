#!/bin/bash
# Script to initialize Phoenix Hypervisor environment and create LXC containers
# Version: 1.0.2 (Fixed local errors, /mnt/phoenix_docker_images, Portainer setup, robust jq handling)
# Author: Assistant
# Integration: Calls phoenix_hypervisor_create_lxc.sh, uses phoenix_hypervisor_common.sh

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- Global Variables ---
EXIT_CODE=0
PHOENIX_LOG_DIR="/var/log/phoenix_hypervisor"
PHOENIX_LOG_FILE="$PHOENIX_LOG_DIR/phoenix_hypervisor_initial_setup.log"
PHOENIX_LXC_CONFIG_FILE="/usr/local/etc/phoenix_lxc_configs.json"
PHOENIX_LXC_SCHEMA_FILE="/usr/local/etc/phoenix_lxc_configs.schema.json"
PHOENIX_HF_TOKEN_FILE="/usr/local/etc/phoenix_hf_token"
PHOENIX_DOCKER_TOKEN_FILE="/usr/local/etc/phoenix_docker_token"
PHOENIX_DOCKER_IMAGES_DIR="/mnt/phoenix_docker_images"
PHOENIX_PORTAINER_SCRIPT="/usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_setup_portainer.sh"
DEBUG_MODE="${DEBUG_MODE:-false}"

# --- Check for Invalid 'local' Declarations in Sourced Files ---
check_for_local_errors() {
    local file="$1"
    if grep -E "^\s*local\s+[a-zA-Z_][a-zA-Z0-9_]*\s*=" "$file" >/dev/null 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Invalid 'local' declaration found outside function in $file" | tee -a "$PHOENIX_LOG_FILE" >&2
        exit 1
    fi
}

# --- Setup Logging ---
setup_logging() {
    mkdir -p "$PHOENIX_LOG_DIR" 2>/dev/null || {
        PHOENIX_LOG_DIR="/tmp"
        PHOENIX_LOG_FILE="$PHOENIX_LOG_DIR/phoenix_hypervisor_initial_setup.log"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] Failed to create $PHOENIX_LOG_DIR, using /tmp" >&2
    }
    touch "$PHOENIX_LOG_FILE" 2>/dev/null || true
    chmod 644 "$PHOENIX_LOG_FILE" 2>/dev/null || {
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] Could not set permissions to 644 on $PHOENIX_LOG_FILE" >&2
    }
}

# --- Logging Functions (Fallback Before Common Script) ---
log_info_fallback() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $message" | tee -a "$PHOENIX_LOG_FILE" >&2
}

log_error_fallback() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $message" | tee -a "$PHOENIX_LOG_FILE" >&2
    EXIT_CODE=1
}

# --- Source Dependencies ---
source_config() {
    for config_file in "/usr/local/etc/phoenix_hypervisor_config.sh" "./phoenix_hypervisor_config.sh"; do
        if [[ -f "$config_file" ]]; then
            if ! bash -n "$config_file"; then
                log_error_fallback "Syntax error in $config_file"
                exit 1
            fi
            check_for_local_errors "$config_file"
            source "$config_file"
            log_info_fallback "Sourced config from $config_file"
            return 0
        fi
    done
    log_error_fallback "Configuration file not found: /usr/local/etc/phoenix_hypervisor_config.sh or ./phoenix_hypervisor_config.sh"
    exit 1
}

source_common() {
    for common_file in "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" "/usr/local/bin/phoenix_hypervisor_common.sh" "./phoenix_hypervisor_common.sh"; do
        if [[ -f "$common_file" ]]; then
            if ! bash -n "$common_file"; then
                log_error_fallback "Syntax error in $common_file"
                exit 1
            fi
            check_for_local_errors "$common_file"
            source "$common_file"
            log_info "Sourced common functions from $common_file"
            return 0
        fi
    done
    log_error_fallback "Common functions file not found in standard locations"
    exit 1
}

# --- System Prerequisite Checks ---
check_prerequisites() {
    local errors=0
    log_info "Checking system prerequisites..."

    # Create Docker images directory
    if [[ ! -d "$PHOENIX_DOCKER_IMAGES_DIR" ]]; then
        log_info "Creating $PHOENIX_DOCKER_IMAGES_DIR..."
        mkdir -p "$PHOENIX_DOCKER_IMAGES_DIR" || {
            log_error "Failed to create $PHOENIX_DOCKER_IMAGES_DIR"
            ((errors++))
        }
        chmod 755 "$PHOENIX_DOCKER_IMAGES_DIR" || {
            log_warn "Could not set permissions to 755 on $PHOENIX_DOCKER_IMAGES_DIR"
        }
        log_info "Created $PHOENIX_DOCKER_IMAGES_DIR"
    else
        log_info "$PHOENIX_DOCKER_IMAGES_DIR exists"
    fi

    # Check Proxmox VE
    if ! command -v pveversion >/dev/null 2>&1; then
        log_error "Proxmox VE not detected (pveversion not found)"
        ((errors++))
    else
        log_info "Proxmox VE detected: $(pveversion)"
    fi

    # Check jq
    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq command not found. Install jq (apt install jq)"
        ((errors++))
    else
        log_info "jq command found"
    fi

    # Check check-jsonschema
    if ! command -v check-jsonschema >/dev/null 2>&1; then
        log_error "check-jsonschema not found. Install with 'pipx install check-jsonschema'"
        ((errors++))
    else
        log_info "check-jsonschema command found"
    fi

    # Check ZFS pool
    if [[ -n "$PHOENIX_ZFS_LXC_POOL" ]]; then
        if ! zfs list "$PHOENIX_ZFS_LXC_POOL" >/dev/null 2>>"$PHOENIX_LOG_FILE"; then
            log_error "ZFS pool $PHOENIX_ZFS_LXC_POOL not found"
            ((errors++))
        else
            log_info "ZFS pool $PHOENIX_ZFS_LXC_POOL verified"
        fi
    else
        log_error "PHOENIX_ZFS_LXC_POOL not defined"
        ((errors++))
    fi

    # Check NVIDIA drivers
    if command -v nvidia-smi >/dev/null 2>&1; then
        local driver_version
        driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>>"$PHOENIX_LOG_FILE")
        if [[ -z "$driver_version" ]]; then
            log_error "Failed to query NVIDIA driver version"
            ((errors++))
        else
            log_info "NVIDIA driver version: $driver_version"
        fi
    else
        log_warn "nvidia-smi not found. GPU support may be unavailable."
    fi

    # Check token files
    for token_file in "$PHOENIX_HF_TOKEN_FILE" "$PHOENIX_DOCKER_TOKEN_FILE"; do
        if [[ -f "$token_file" ]]; then
            local permissions
            permissions=$(stat -c "%a" "$token_file" 2>>"$PHOENIX_LOG_FILE")
            if [[ "$permissions" != "600" ]]; then
                log_warn "Token file $token_file permissions are $permissions, setting to 600"
                chmod 600 "$token_file" || {
                    log_error "Failed to set permissions to 600 for $token_file"
                    ((errors++))
                }
            else
                log_info "Token file $token_file has correct permissions (600)"
            fi
        else
            log_error "Token file missing: $token_file"
            ((errors++))
        fi
    done

    # Check Portainer setup script
    if [[ ! -x "$PHOENIX_PORTAINER_SCRIPT" ]]; then
        log_error "Portainer setup script $PHOENIX_PORTAINER_SCRIPT not found or not executable"
        ((errors++))
    else
        log_info "Portainer setup script $PHOENIX_PORTAINER_SCRIPT verified"
    fi

    if [[ $errors -ne 0 ]]; then
        log_error "Prerequisite checks failed with $errors errors"
        return 1
    fi
    log_info "All prerequisite checks passed"
    return 0
}

# --- Validate JSON Configuration ---
validate_json_config() {
    if [[ "$DEBUG_MODE" == "true" ]]; then
        log_warn "Skipping JSON configuration validation in debug mode"
        return 0
    fi
    if [[ ! -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $PHOENIX_LXC_CONFIG_FILE"
        return 1
    fi
    if [[ ! -f "$PHOENIX_LXC_SCHEMA_FILE" ]]; then
        log_error "Schema file not found: $PHOENIX_LXC_SCHEMA_FILE"
        return 1
    fi
    local jq_output
    jq_output=$(jq -c . "$PHOENIX_LXC_CONFIG_FILE" 2>>"$PHOENIX_LOG_FILE")
    if [[ $? -ne 0 ]]; then
        log_error "JSON parsing failed for $PHOENIX_LXC_CONFIG_FILE: $jq_output"
        return 1
    fi
    if ! check-jsonschema "$PHOENIX_LXC_CONFIG_FILE" --schemafile "$PHOENIX_LXC_SCHEMA_FILE" 2>>"$PHOENIX_LOG_FILE"; then
        log_error "JSON configuration validation failed for $PHOENIX_LXC_CONFIG_FILE"
        return 1
    fi
    log_info "JSON configuration validated successfully"
    return 0
}

# --- Create Containers ---
create_containers() {
    local container_ids
    container_ids=$(jq -r '.lxc_configs | keys[]' "$PHOENIX_LXC_CONFIG_FILE" 2>>"$PHOENIX_LOG_FILE")
    if [[ $? -ne 0 ]]; then
        log_error "Failed to parse container IDs from $PHOENIX_LXC_CONFIG_FILE"
        return 1
    fi
    if [[ -z "$container_ids" ]]; then
        log_warn "No container configurations found in $PHOENIX_LXC_CONFIG_FILE"
        return 0
    fi

    local count=0
    # Create Portainer server (999) first
    if echo "$container_ids" | grep -q "^999$"; then
        log_info "Creating Portainer server container (ID 999) first"
        if ! /usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_create_lxc.sh 999; then
            log_error "Failed to create Portainer server container (ID 999)"
            return 1
        fi
        ((count++))
    fi

    # Create other containers
    while IFS= read -r id; do
        if [[ -n "$id" && "$id" != "999" ]]; then
            log_info "Creating container ID $id"
            if ! /usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_create_lxc.sh "$id"; then
                log_error "Failed to create container ID $id"
                return 1
            fi
            ((count++))
        fi
    done <<< "$container_ids"

    log_info "Successfully created $count containers"
    return 0
}

main() {
    local start_time
    start_time=$(date '+%Y-%m-%d %H:%M:%S %Z')
    log_info "Starting Phoenix Hypervisor initial setup at $start_time"

    # Setup logging
    setup_logging

    # Source dependencies
    if ! source_config; then
        log_error "Failed to source configuration"
        exit 1
    fi
    if ! source_common; then
        log_error "Failed to source common functions"
        exit 1
    fi

    # Check prerequisites
    if ! check_prerequisites; then
        log_error "Prerequisite checks failed"
        exit 1
    fi

    # Validate JSON configuration
    if ! validate_json_config; then
        log_error "JSON configuration validation failed"
        exit 1
    fi

    # Create containers
    if ! create_containers; then
        log_error "Container creation failed"
        exit 1
    fi

    log_info "Phoenix Hypervisor initial setup completed successfully"
    exit 0
}

main