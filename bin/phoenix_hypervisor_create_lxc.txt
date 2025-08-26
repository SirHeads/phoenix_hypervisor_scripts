#!/bin/bash
# Script to create an LXC container for Phoenix Hypervisor
# Version: 1.7.9 (Enhanced logging, token permissions, common validations, resource checks, quiet mode, Portainer validation)
# Author: Assistant
# Integration: Called by phoenix_establish_hypervisor.sh, uses phoenix_hypervisor_common.sh (v2.1.2) for core functions

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- Argument Parsing ---
if [[ $# -ne 1 ]]; then
    log_error "Usage: $0 <container_id>"
    exit 1
fi
container_id="$1"

if ! [[ "$container_id" =~ ^[0-9]+$ ]]; then
    log_error "Invalid container ID: $container_id"
    exit 1
fi
# --- END Argument Parsing ---

# --- Quiet Mode Check ---
QUIET_MODE="${QUIET_MODE:-false}"
log_debug "Script started. QUIET_MODE=$QUIET_MODE, container_id=$container_id"

# --- jq Check ---
if ! command -v jq >/dev/null 2>&1; then
    log_error "jq command not found. Install jq (apt install jq)."
    exit 1
fi
log_debug "jq command found."

# --- Load Configuration ---
container_config=$(jq -c ".lxc_configs.\"$container_id\"" "$PHOENIX_LXC_CONFIG_FILE" 2>>"$PHOENIX_LOG_FILE")
if [[ -z "$container_config" || "$container_config" == "null" ]]; then
    log_error "No configuration found for container ID $container_id in $PHOENIX_LXC_CONFIG_FILE"
    exit 1
fi

template_path=$(echo "$container_config" | jq -r '.template')
if [[ -z "$template_path" || "$template_path" == "null" ]]; then
    log_error "No template specified in configuration for container $container_id"
    exit 1
fi
if ! test -f "$template_path"; then
    log_error "Template file not found: $template_path"
    exit 1
fi
log_info "Using template: $template_path for container $container_id"

# --- Source Dependencies ---
if [[ -f "/usr/local/etc/phoenix_hypervisor_config.sh" ]]; then
    source /usr/local/etc/phoenix_hypervisor_config.sh
elif [[ -f "./phoenix_hypervisor_config.sh" ]]; then
    source ./phoenix_hypervisor_config.sh
    log_warn "Sourced config from current directory. Prefer /usr/local/etc/phoenix_hypervisor_config.sh"
else
    log_error "Configuration file not found: /usr/local/etc/phoenix_hypervisor_config.sh or ./phoenix_hypervisor_config.sh"
    exit 1
fi

if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh
elif [[ -f "/usr/local/bin/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/bin/phoenix_hypervisor_common.sh
    log_warn "Sourced common functions from /usr/local/bin/. Prefer /usr/local/lib/phoenix_hypervisor/."
elif [[ -f "./phoenix_hypervisor_common.sh" ]]; then
    source ./phoenix_hypervisor_common.sh
    log_warn "Sourced common functions from current directory. Prefer standard locations."
else
    log_error "Common functions file not found in standard locations."
    exit 1
fi

# --- Check for Core Container Priority ---
is_core_container() {
    local id="$1"
    if [[ "$id" =~ ^[0-9]+$ ]] && [[ "$id" -ge 990 ]] && [[ "$id" -le 999 ]]; then
        return 0
    else
        return 1
    fi
}

if is_core_container "$container_id"; then
    log_info "Identified container $container_id as a CORE container (IDs 990-999)."
else
    log_info "Identified container $container_id as a STANDARD workload container."
fi

# --- Resource Checks ---
check_proxmox_resources() {
    local memory_mb cores storage_size_gb
    memory_mb=$(echo "$container_config" | jq -r '.memory_mb')
    cores=$(echo "$container_config" | jq -r '.cores')
    storage_size_gb=$(echo "$container_config" | jq -r '.storage_size_gb')
    log_info "Checking Proxmox resources for container $container_id (memory: $memory_mb MB, cores: $cores, storage: $storage_size_gb GB)"

    if ! command -v pvesh >/dev/null 2>&1; then
        log_warn "pvesh not found. Skipping resource checks."
        return 0
    fi

    local node=$(hostname)
    local available_memory_mb available_cores available_storage_gb
    available_memory_mb=$(pvesh get /nodes/"$node"/hardware/memory --output-format=json | jq -r '.free / 1024 / 1024')
    available_cores=$(pvesh get /nodes/"$node"/hardware/cpuinfo --output-format=json | jq -r '.cores')
    available_storage_gb=$(pvesh get /nodes/"$node"/storage/"$PHOENIX_ZFS_LXC_POOL" --output-format=json | jq -r '.avail / 1024 / 1024 / 1024')

    if [[ $(echo "$available_memory_mb < $memory_mb" | bc -l) -eq 1 ]]; then
        log_error "Insufficient memory: $available_memory_mb MB available, $memory_mb MB required"
        return 1
    fi
    if [[ $(echo "$available_cores < $cores" | bc -l) -eq 1 ]]; then
        log_error "Insufficient CPU cores: $available_cores available, $cores required"
        return 1
    fi
    if [[ $(echo "$available_storage_gb < $storage_size_gb" | bc -l) -eq 1 ]]; then
        log_error "Insufficient storage: $available_storage_gb GB available, $storage_size_gb GB required"
        return 1
    fi
    log_info "Proxmox resources sufficient for container $container_id"
    return 0
}

# --- Token Permissions ---
check_token_permissions() {
    local token_file="$1"
    if [[ ! -f "$token_file" ]]; then
        log_error "Token file missing: $token_file"
        return 1
    fi
    local permissions
    permissions=$(stat -c "%a" "$token_file")
    if [[ "$permissions" != "600" ]]; then
        log_warn "Insecure permissions on $token_file ($permissions). Setting to 600."
        chmod 600 "$token_file" || log_error "Failed to set permissions on $token_file"
    fi
    return 0
}

# --- Temporary Functions (To be Replaced) ---
install_docker_ce_in_container() {
    local lxc_id="$1"
    log_info "Installing Docker CE in container $lxc_id..."
    if ! pct_exec_with_retry "$lxc_id" bash -c "apt update && apt install -y docker.io"; then
        log_error "Failed to install Docker CE in container $lxc_id"
        return 1
    fi
    log_info "Docker CE installed in container $lxc_id"
    return 0
}

authenticate_registry() {
    local lxc_id="$1"
    log_info "Authenticating with Docker Hub in container $lxc_id..."
    local docker_token=$(grep '^DOCKER_TOKEN=' "$PHOENIX_DOCKER_TOKEN_FILE" | cut -d'=' -f2-)
    if [[ -z "$docker_token" ]]; then
        log_error "DOCKER_TOKEN not found in $PHOENIX_DOCKER_TOKEN_FILE"
        return 1
    fi
    if ! pct_exec_with_retry "$lxc_id" bash -c "echo '$docker_token' | docker login -u phoenix --password-stdin"; then
        log_error "Failed to authenticate with Docker Hub in container $lxc_id"
        return 1
    fi
    log_info "Docker Hub authentication successful in container $lxc_id"
    return 0
}

install_portainer_agent() {
    local lxc_id="$1"
    log_info "Installing Portainer agent in container $lxc_id..."
    if ! pct_exec_with_retry "$lxc_id" bash -c "docker run -d -p 9001:9001 --name portainer_agent --restart=always -v /var/run/docker.sock:/var/run/docker.sock portainer/agent"; then
        log_error "Failed to install Portainer agent in container $lxc_id"
        return 1
    fi
    log_info "Portainer agent installed in container $lxc_id"
    return 0
}

# --- Main Execution ---
main() {
    if [[ "$QUIET_MODE" != "true" ]]; then
        echo "==============================================="
        echo "PHOENIX HYPERVISOR: CREATING CONTAINER $container_id"
        echo "==============================================="
    fi
    log_info "Starting creation of container $container_id..."

    # Check Proxmox resources
    if ! check_proxmox_resources; then
        log_error "Resource check failed for container $container_id"
        exit 1
    fi

    # Check token permissions for 900-902, 999
    if [[ "$container_id" -ge 900 && "$container_id" -le 902 ]] || [[ "$container_id" == "999" ]]; then
        if ! check_token_permissions "$PHOENIX_HF_TOKEN_FILE" || ! check_token_permissions "$PHOENIX_DOCKER_TOKEN_FILE"; then
            log_error "Token permission check failed for container $container_id"
            exit 1
        fi
    fi

    # Validate AI framework for 900-902
    if [[ "$container_id" -ge 900 && "$container_id" -le 902 ]]; then
        local ai_framework
        ai_framework=$(echo "$container_config" | jq -r '.ai_framework // "vllm"')
        if [[ ! "$ai_framework" =~ ^(vllm|llamacpp|ollama)$ ]]; then
            log_error "Invalid ai_framework '$ai_framework' for container $container_id. Must be vllm, llamacpp, or ollama."
            exit 1
        fi
        log_info "AI framework for container $container_id: $ai_framework"
        if ! validate_ai_workload_config "$container_id"; then
            log_error "AI workload configuration validation failed for container $container_id"
            exit 1
        fi
    fi

    # Create container
    if ! create_lxc_container "$container_id" "$container_config"; then
        log_error "Failed to create container $container_id"
        exit 1
    fi

    # Validate container status
    if ! validate_container_status "$container_id"; then
        log_error "Container $container_id is not running or has network issues"
        exit 1
    fi

    # Validate init system
    local init_system
    init_system=$(pct_exec_with_retry "$container_id" bash -c "ps -p 1 -o comm=")
    if [[ -z "$init_system" ]]; then
        log_error "Failed to retrieve init system for container $container_id"
        exit 1
    fi
    if [[ "$init_system" != "systemd" ]]; then
        log_error "Non-systemd init detected: $init_system. Docker requires systemd."
        exit 1
    fi
    log_info "Container init system: $init_system"

    # Get container codename
    local container_codename
    container_codename=$(pct_exec_with_retry "$container_id" bash -c "lsb_release -cs 2>/dev/null || echo 'unknown'")
    if [[ "$container_codename" != "unknown" ]]; then
        log_info "Container codename: $container_codename (template: $template_path)"
    else
        log_info "Container codename not available, continuing with setup"
    fi

    # Registry authentication for 900-902, 999
    if [[ "$container_id" -ge 900 && "$container_id" -le 902 ]] || [[ "$container_id" == "999" ]]; then
        log_info "Container $container_id requires registry authentication (Portainer agent or server)."
        if ! install_docker_ce_in_container "$container_id"; then
            log_error "Failed to install Docker in container $container_id"
            exit 1
        fi
        if ! authenticate_registry "$container_id"; then
            log_error "Failed to authenticate with Docker Hub for container $container_id"
            exit 1
        fi
        if ! authenticate_huggingface "$container_id"; then
            log_error "Failed to authenticate with Hugging Face for container $container_id"
            exit 1
        fi
    fi

    # Post-creation hooks
    if [[ "$container_id" -ge 900 && "$container_id" -le 902 ]]; then
        log_info "Container $container_id is a Portainer agent. Installing agent..."
        if ! install_portainer_agent "$container_id"; then
            log_error "Failed to install Portainer agent in container $container_id"
            exit 1
        fi
        if ! validate_portainer_network_in_container "$container_id"; then
            log_error "Portainer agent network validation failed for container $container_id"
            exit 1
        fi
    elif [[ "$container_id" == "999" ]]; then
        log_info "Container $container_id is Portainer server. Initiating setup..."
        local postcreate_script="/usr/local/bin/phoenix_hypervisor/phoenix_hypervisor_setup_portainer.sh"
        if [[ -x "$postcreate_script" ]]; then
            if ! "$postcreate_script" "$container_id"; then
                local postcreate_exit_code=$?
                log_error "Portainer server setup script '$postcreate_script $container_id' failed with exit code $postcreate_exit_code"
                exit $postcreate_exit_code
            fi
            if ! validate_portainer_network_in_container "$container_id"; then
                log_error "Portainer server network validation failed for container $container_id"
                exit 1
            fi
        else
            log_error "Portainer server setup script '$postcreate_script' not found or not executable"
            exit 1
        fi
    fi

    if [[ "$QUIET_MODE" != "true" ]]; then
        echo "==============================================="
        echo "PHOENIX HYPERVISOR: CONTAINER $container_id CREATED SUCCESSFULLY"
        echo "==============================================="
    fi
    log_info "Container $container_id created and configured successfully"
    exit 0
}

main