#!/bin/bash
# Main script to establish Phoenix Hypervisor
# Creates and configures LXC containers based on phoenix_lxc_configs.json
# Version: 1.7.19 (Fixed insufficient memory error, added fallback memory adjustment, retained prior fixes)
# Author: Assistant
# Integration: Uses phoenix_hypervisor_common.sh (v2.1.2), phoenix_hypervisor_create_lxc.sh (v1.8.1), phoenix_hypervisor_initial_setup.sh (v1.0.2)

set -euo pipefail

# --- Global Variables ---
PHOENIX_LOG_DIR="/var/log/phoenix_hypervisor"
PHOENIX_LOG_FILE="$PHOENIX_LOG_DIR/phoenix_hypervisor.log"
PHOENIX_DOCKER_IMAGES_DIR="/mnt/phoenix_docker_images"
PHOENIX_PORTAINER_SCRIPT="/usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_setup_portainer.sh"
QUIET_MODE="${QUIET_MODE:-false}"
DEBUG_MODE="${DEBUG_MODE:-false}"
MAX_MEMORY_PERCENTAGE="${MAX_MEMORY_PERCENTAGE:-0.8}"  # Use up to 80% of available memory for any single container

# --- Fallback Logging (Before Common Script) ---
log_info_fallback() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $message" | tee -a "$PHOENIX_LOG_FILE" >&2
}

log_warn_fallback() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $message" | tee -a "$PHOENIX_LOG_FILE" >&2
}

log_error_fallback() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $message" | tee -a "$PHOENIX_LOG_FILE" >&2
    exit 1
}

# --- Terminal Handling ---
if [[ -t 0 ]]; then
    trap 'stty sane; [[ "$QUIET_MODE" != "true" ]] && echo "Terminal reset"' EXIT
else
    trap '[[ "$QUIET_MODE" != "true" ]] && echo "Terminal reset (non-interactive)"' EXIT
fi

# --- Sourcing Check ---
source_config() {
    if [[ -f "/usr/local/etc/phoenix_hypervisor_config.sh" ]]; then
        if ! bash -n "/usr/local/etc/phoenix_hypervisor_config.sh"; then
            log_error_fallback "Syntax error in /usr/local/etc/phoenix_hypervisor_config.sh"
            exit 1
        fi
        source /usr/local/etc/phoenix_hypervisor_config.sh
        log_info_fallback "Sourced config from /usr/local/etc/phoenix_hypervisor_config.sh"
    elif [[ -f "./phoenix_hypervisor_config.sh" ]]; then
        if ! bash -n "./phoenix_hypervisor_config.sh"; then
            log_error_fallback "Syntax error in ./phoenix_hypervisor_config.sh"
            exit 1
        fi
        source ./phoenix_hypervisor_config.sh
        log_warn_fallback "Sourced config from current directory. Prefer /usr/local/etc/phoenix_hypervisor_config.sh."
    else
        log_error_fallback "Configuration file not found."
        exit 1
    fi
}

source_common() {
    if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
        if ! bash -n "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh"; then
            log_error_fallback "Syntax error in /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh"
            exit 1
        fi
        if ! source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh 2>>"$PHOENIX_LOG_FILE"; then
            log_error_fallback "Failed to source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh due to invalid syntax or errors."
            exit 1
        fi
        log_info "Sourced common functions from /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh"
    elif [[ -f "./phoenix_hypervisor_common.sh" ]]; then
        if ! bash -n "./phoenix_hypervisor_common.sh"; then
            log_error_fallback "Syntax error in ./phoenix_hypervisor_common.sh"
            exit 1
        fi
        if ! source ./phoenix_hypervisor_common.sh 2>>"$PHOENIX_LOG_FILE"; then
            log_error_fallback "Failed to source ./phoenix_hypervisor_common.sh due to invalid syntax or errors."
            exit 1
        fi
        log_warn "Sourced common functions from current directory. Prefer /usr/local/lib/phoenix_hypervisor/."
    else
        log_error_fallback "phoenix_hypervisor_common.sh not found."
        exit 1
    fi
}

# Source config first to ensure variables like PHOENIX_LXC_CONFIG_FILE are defined
source_config
source_common

log_debug "Starting Phoenix Hypervisor setup. QUIET_MODE=$QUIET_MODE, DEBUG_MODE=$DEBUG_MODE"

# --- Validate Environment ---
validate_environment() {
    log_info "Validating environment..."

    # Check and create critical directories
    local required_dirs=(
        "/usr/local/etc"
        "/usr/local/lib/phoenix_hypervisor"
        "/usr/local/bin/phoenix_hypervisor"
        "$PHOENIX_LOG_DIR"
        "$HYPERVISOR_MARKER_DIR"
        "$PHOENIX_DOCKER_IMAGES_DIR"
    )
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log_info "Directory '$dir' not found, attempting to create it..."
            if ! mkdir -p "$dir" 2>>"$PHOENIX_LOG_FILE"; then
                log_error "Failed to create directory '$dir'. Check permissions."
                exit 1
            fi
            chmod 755 "$dir" || log_warn "Could not set permissions to 755 on $dir"
            log_info "Directory '$dir' created successfully."
        fi
    done

    # Check token files and permissions
    check_token_permissions() {
        local file="$1"
        if [[ ! -f "$file" ]]; then
            log_error "Critical token file missing: $file"
            exit 1
        fi
        if [[ ! -r "$file" ]]; then
            log_error "Token file not readable: $file"
            exit 1
        fi
        local permissions
        permissions=$(stat -c "%a" "$file")
        if [[ "$permissions" != "600" ]]; then
            log_warn "Insecure permissions on $file ($permissions). Setting to 600."
            chmod 600 "$file" || log_error "Failed to set permissions on $file"
        fi
        log_info "Token file $file permissions verified (600)"
    }
    local critical_files=(
        "$PHOENIX_HF_TOKEN_FILE"
        "$PHOENIX_DOCKER_TOKEN_FILE"
    )
    for file in "${critical_files[@]}"; do
        check_token_permissions "$file"
    done

    # Check initial setup marker
    local setup_script="/usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_initial_setup.sh"
    if [[ ! -f "$HYPERVISOR_MARKER" ]]; then
        log_info "Marker file '$HYPERVISOR_MARKER' not found. Running initial setup script..."
        if [[ -x "$setup_script" ]]; then
            if ! "$setup_script"; then
                log_error "Initial setup script failed. Check logs at $PHOENIX_LOG_DIR/phoenix_hypervisor_initial_setup.log."
                exit 1
            fi
        else
            log_error "Initial setup script not found or not executable at $setup_script."
            exit 1
        fi
        if [[ ! -f "$HYPERVISOR_MARKER" ]]; then
            log_error "Initial setup completed but marker file '$HYPERVISOR_MARKER' not found."
            exit 1
        fi
    fi

    # Other environment checks
    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq not installed. Install with 'apt install jq'"
        exit 1
    fi
    if ! command -v pct >/dev/null 2>&1; then
        log_error "pct not installed. Ensure Proxmox VE is installed"
        exit 1
    fi
    if ! systemctl is-active --quiet apparmor; then
        log_error "apparmor service not active."
        exit 1
    fi
    if ! zfs list "$PHOENIX_ZFS_LXC_POOL" >/dev/null 2>>"$PHOENIX_LOG_FILE"; then
        log_error "ZFS pool $PHOENIX_ZFS_LXC_POOL not found."
        exit 1
    fi
    if ! nvidia-smi >/dev/null 2>>"$PHOENIX_LOG_FILE"; then
        log_error "NVIDIA GPUs not detected."
        exit 1
    fi
    if [[ ! -x "$PHOENIX_PORTAINER_SCRIPT" ]]; then
        log_error "Portainer setup script $PHOENIX_PORTAINER_SCRIPT not found or not executable."
        exit 1
    fi
    if [[ -z "${PHOENIX_LXC_CONFIG_FILE:-}" ]]; then
        log_error "PHOENIX_LXC_CONFIG_FILE is not defined."
        exit 1
    fi
    local jq_output
    if [[ "$DEBUG_MODE" == "true" ]]; then
        log_warn "Skipping JSON configuration validation in debug mode"
    else
        jq_output=$(jq -e . "$PHOENIX_LXC_CONFIG_FILE" 2>>"$PHOENIX_LOG_FILE")
        if [[ $? -ne 0 ]]; then
            log_error "Invalid JSON in $PHOENIX_LXC_CONFIG_FILE: $jq_output"
            exit 1
        fi
    fi
    log_info "Environment validated successfully."
}

# --- Create Containers with Priority ---
create_containers() {
    log_info "Creating LXC containers from $PHOENIX_LXC_CONFIG_FILE with priority..."

    # Load LXC configurations
    if [[ -z "${PHOENIX_LXC_CONFIG_FILE:-}" ]]; then
        log_error "PHOENIX_LXC_CONFIG_FILE is not defined."
        exit 1
    fi
    if ! load_hypervisor_config 2>>"$PHOENIX_LOG_FILE"; then
        log_error "Failed to load hypervisor configuration."
        exit 1
    fi

    # Check Proxmox resources
    check_proxmox_resources() {
        local id="$1"
        local memory_mb cores storage_size_gb
        memory_mb=$(echo "${LXC_CONFIGS[$id]}" | jq -r '.memory_mb')
        cores=$(echo "${LXC_CONFIGS[$id]}" | jq -r '.cores')
        storage_size_gb=$(echo "${LXC_CONFIGS[$id]}" | jq -r '.storage_size_gb')
        log_info "Checking resources for container $id (memory: $memory_mb MB, cores: $cores, storage: $storage_size_gb GB)"

        local available_memory_mb available_cores available_storage_gb
        available_memory_mb=$(free -m | awk '/Mem:/ {print $4}')
        available_cores=$(nproc)
        available_storage_gb=$(zfs get -H -o value -p available "$PHOENIX_ZFS_LXC_POOL" | awk '{print $1 / 1024 / 1024 / 1024}')

        if [[ -z "$available_memory_mb" || "$available_memory_mb" == "0" ]]; then
            log_warn "Failed to retrieve available memory. Skipping memory check."
            available_memory_mb=$memory_mb
        fi
        if [[ -z "$available_cores" || "$available_cores" == "0" ]]; then
            log_warn "Failed to retrieve available CPU cores. Skipping CPU check."
            available_cores=$cores
        fi
        if [[ -z "$available_storage_gb" || "$available_storage_gb" == "0" ]]; then
            log_warn "Failed to retrieve available storage. Skipping storage check."
            available_storage_gb=$storage_size_gb
        fi

        # Adjust memory if it exceeds available resources
        local max_memory_mb
        max_memory_mb=$(echo "$available_memory_mb * $MAX_MEMORY_PERCENTAGE" | bc -l | awk '{printf "%.0f", $1}')
        if [[ $(echo "$memory_mb > $max_memory_mb" | bc -l 2>>"$PHOENIX_LOG_FILE") -eq 1 ]]; then
            log_warn "Requested memory ($memory_mb MB) for container $id exceeds $MAX_MEMORY_PERCENTAGE of available memory ($available_memory_mb MB). Adjusting to $max_memory_mb MB."
            memory_mb=$max_memory_mb
            # Update LXC_CONFIGS with adjusted memory
            LXC_CONFIGS[$id]=$(echo "${LXC_CONFIGS[$id]}" | jq --argjson mem "$memory_mb" '.memory_mb = $mem')
        fi

        if [[ $(echo "$available_memory_mb < $memory_mb" | bc -l 2>>"$PHOENIX_LOG_FILE") -eq 1 ]]; then
            log_error "Insufficient memory: $available_memory_mb MB available, $memory_mb MB required"
            return 1
        fi
        if [[ $(echo "$available_cores < $cores" | bc -l 2>>"$PHOENIX_LOG_FILE") -eq 1 ]]; then
            log_error "Insufficient CPU cores: $available_cores available, $cores required"
            return 1
        fi
        if [[ $(echo "$available_storage_gb < $storage_size_gb" | bc -l 2>>"$PHOENIX_LOG_FILE") -eq 1 ]]; then
            log_error "Insufficient storage: $available_storage_gb GB available, $storage_size_gb GB required"
            return 1
        fi
        log_info "Resources sufficient for container $id"
        return 0
    }

    # Identify core and standard containers
    local core_container_ids=()
    local standard_container_ids=()
    for id in "${!LXC_CONFIGS[@]}"; do
        if ! [[ "$id" =~ ^[0-9]+$ ]]; then
            log_warn "Skipping non-numeric container ID: $id"
            continue
        fi
        if [[ "$id" -ge 990 && "$id" -le 999 ]]; then
            log_info "Identified core container ID: $id"
            core_container_ids+=("$id")
        else
            # Validate ai_framework for 900-902
            if [[ "$id" -ge 900 && "$id" -le 902 ]]; then
                local ai_framework
                ai_framework=$(echo "${LXC_CONFIGS[$id]}" | jq -r '.ai_framework // "vllm"')
                if [[ ! "$ai_framework" =~ ^(vllm|llamacpp|ollama)$ ]]; then
                    log_error "Invalid ai_framework '$ai_framework' for container $id. Must be vllm, llamacpp, or ollama."
                    exit 1
                fi
                log_info "AI framework for container $id: $ai_framework"
                if ! validate_ai_workload_config "$id" 2>>"$PHOENIX_LOG_FILE"; then
                    log_error "AI workload configuration validation failed for container $id"
                    exit 1
                fi
            fi
            standard_container_ids+=("$id")
        fi
    done

    if command -v sort >/dev/null 2>&1; then
        mapfile -t core_container_ids < <(printf '%s\n' "${core_container_ids[@]}" | sort -n)
        mapfile -t standard_container_ids < <(printf '%s\n' "${standard_container_ids[@]}" | sort -n)
    else
        log_warn "'sort' command not found. Container order might be inconsistent."
    fi

    # Process core containers
    if [[ ${#core_container_ids[@]} -gt 0 ]]; then
        log_info "Starting creation of core containers: ${core_container_ids[*]}"
        for id in "${core_container_ids[@]}"; do
            log_info "Processing core container $id..."
            if ! check_proxmox_resources "$id"; then
                log_warn "Resource check failed for container $id. Skipping to next container."
                continue
            fi
            if pct status "$id" >/dev/null 2>&1; then
                log_info "Core container $id already exists, skipping creation."
                continue
            fi
            if ! /usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_create_lxc.sh "$id" 2>>"$PHOENIX_LOG_FILE"; then
                log_error "Failed to create core container $id."
                if [[ "${ROLLBACK_ON_FAILURE:-false}" == "true" ]]; then
                    log_info "Rolling back core container $id..."
                    /usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id" 2>>"$PHOENIX_LOG_FILE" || log_warn "Failed to destroy container $id during rollback"
                fi
                exit 1
            fi
            if [[ "$id" == "999" ]]; then
                log_info "Setting up Portainer server container $id..."
                if ! "$PHOENIX_PORTAINER_SCRIPT" "$id" 2>>"$PHOENIX_LOG_FILE"; then
                    local exit_code=$?
                    log_error "Failed to set up Portainer server container $id (exit code $exit_code)."
                    if [[ "${ROLLBACK_ON_FAILURE:-false}" == "true" ]]; then
                        log_info "Rolling back core container $id..."
                        /usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id" 2>>"$PHOENIX_LOG_FILE" || log_warn "Failed to destroy container $id during rollback"
                    fi
                    exit $exit_code
                fi
                if ! validate_portainer_network_in_container "$id" 2>>"$PHOENIX_LOG_FILE"; then
                    log_error "Portainer server network validation failed for container $id"
                    if [[ "${ROLLBACK_ON_FAILURE:-false}" == "true" ]]; then
                        log_info "Rolling back core container $id..."
                        /usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id" 2>>"$PHOENIX_LOG_FILE" || log_warn "Failed to destroy container $id during rollback"
                    fi
                    exit 1
                fi
            fi
            if ! validate_container_status "$id" 2>>"$PHOENIX_LOG_FILE"; then
                log_error "Container $id status validation failed"
                if [[ "${ROLLBACK_ON_FAILURE:-false}" == "true" ]]; then
                    log_info "Rolling back core container $id..."
                    /usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id" 2>>"$PHOENIX_LOG_FILE" || log_warn "Failed to destroy container $id during rollback"
                fi
                exit 1
            fi
            log_info "Core container $id created and configured successfully."
        done
        log_info "All core containers created successfully."
    else
        log_info "No core containers (IDs 990-999) found in configuration."
    fi

    # Process standard containers
    if [[ ${#standard_container_ids[@]} -gt 0 ]]; then
        log_info "Starting creation of standard containers: ${standard_container_ids[*]}"
        for id in "${standard_container_ids[@]}"; do
            log_info "Processing standard container $id..."
            if ! check_proxmox_resources "$id"; then
                log_warn "Resource check failed for container $id. Skipping to next container."
                continue
            fi
            if pct status "$id" >/dev/null 2>&1; then
                log_info "Standard container $id already exists, skipping creation."
                continue
            fi
            if ! /usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_create_lxc.sh "$id" 2>>"$PHOENIX_LOG_FILE"; then
                log_error "Failed to create standard container $id."
                if [[ "${ROLLBACK_ON_FAILURE:-false}" == "true" ]]; then
                    log_info "Rolling back standard container $id..."
                    /usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id" 2>>"$PHOENIX_LOG_FILE" || log_warn "Failed to destroy container $id during rollback"
                fi
                exit 1
            fi
            if [[ "$id" -ge 900 && "$id" -le 902 ]]; then
                log_info "Setting up Portainer agent container $id..."
                if ! install_portainer_agent "$id" 2>>"$PHOENIX_LOG_FILE"; then
                    log_error "Failed to set up Portainer agent container $id."
                    if [[ "${ROLLBACK_ON_FAILURE:-false}" == "true" ]]; then
                        log_info "Rolling back standard container $id..."
                        /usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id" 2>>"$PHOENIX_LOG_FILE" || log_warn "Failed to destroy container $id during rollback"
                    fi
                    exit 1
                fi
                if ! validate_portainer_network_in_container "$id" 2>>"$PHOENIX_LOG_FILE"; then
                    log_error "Portainer agent network validation failed for container $id"
                    if [[ "${ROLLBACK_ON_FAILURE:-false}" == "true" ]]; then
                        log_info "Rolling back standard container $id..."
                        /usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id" 2>>"$PHOENIX_LOG_FILE" || log_warn "Failed to destroy container $id during rollback"
                    fi
                    exit 1
                fi
            fi
            if ! validate_container_status "$id" 2>>"$PHOENIX_LOG_FILE"; then
                log_error "Container $id status validation failed"
                if [[ "${ROLLBACK_ON_FAILURE:-false}" == "true" ]]; then
                    log_info "Rolling back standard container $id..."
                    /usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_destroy.sh "$id" 2>>"$PHOENIX_LOG_FILE" || log_warn "Failed to destroy container $id during rollback"
                fi
                exit 1
            fi
            log_info "Standard container $id created and configured successfully."
        done
        log_info "All standard containers created successfully."
    else
        log_info "No standard containers found in configuration."
    fi
}

# --- Main Execution ---
main() {
    if [[ "$QUIET_MODE" != "true" ]]; then
        echo "==============================================="
        echo "PHOENIX HYPERVISOR SETUP"
        echo "==============================================="
    fi
    log_info "Starting Phoenix Hypervisor setup..."

    validate_environment
    create_containers

    if [[ "$QUIET_MODE" != "true" ]]; then
        echo "==============================================="
        echo "PHOENIX HYPERVISOR SETUP COMPLETED"
        echo "==============================================="
        echo "Check container status with: pct status <ID>"
        echo "Access Portainer server at: http://$PORTAINER_SERVER_IP:$PORTAINER_SERVER_PORT"
        echo "Access Portainer agents at: http://$PORTAINER_SERVER_IP:$PORTAINER_AGENT_PORT"
    fi
    log_info "Phoenix Hypervisor setup completed successfully."
}

main "$@"