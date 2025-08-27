#!/bin/bash
# Script to create an LXC container for Phoenix Hypervisor
# Version: 1.8.2 (Ensured no local errors, added validation for sourced files)
# Author: Assistant
# Integration: Called by phoenix_establish_hypervisor.sh, uses phoenix_hypervisor_common.sh

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- Check for Invalid 'local' Declarations in Sourced Files ---
check_for_local_errors() {
    local file="$1"
    if grep -E "^\s*local\s+[a-zA-Z_][a-zA-Z0-9_]*\s*=" "$file" >/dev/null 2>&1; then
        echo "ERROR: Invalid 'local' declaration found outside function in $file" >&2
        exit 1
    fi
}

# --- Argument Parsing ---
if [[ $# -ne 1 ]]; then
    echo "ERROR: Usage: $0 <container_id>" >&2
    exit 1
fi
container_id="$1"

if ! [[ "$container_id" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Invalid container ID: $container_id" >&2
    exit 1
fi
if command -v log_debug >/dev/null 2>&1; then
    log_debug "Script started. QUIET_MODE=${QUIET_MODE:-false}, container_id=$container_id"
fi

# --- jq Check ---
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq command not found. Install jq (apt install jq)." >&2
    exit 1
fi
if command -v log_debug >/dev/null 2>&1; then
    log_debug "jq command found."
fi

# --- Load Configuration ---
container_config=$(jq -c ".lxc_configs.\"$container_id\"" "$PHOENIX_LXC_CONFIG_FILE" 2>/dev/null)
if [[ $? -ne 0 || -z "$container_config" || "$container_config" == "null" ]]; then
    echo "ERROR: No configuration found for container ID $container_id in $PHOENIX_LXC_CONFIG_FILE" >&2
    exit 1
fi

template_path=$(echo "$container_config" | jq -r '.template')
if [[ -z "$template_path" || "$template_path" == "null" ]]; then
    echo "ERROR: No template specified in configuration for container $container_id" >&2
    exit 1
fi
if ! test -f "$template_path"; then
    echo "ERROR: Template file not found: $template_path" >&2
    exit 1
fi
if command -v log_info >/dev/null 2>&1; then
    log_info "Using template: $template_path for container $container_id"
fi

# --- Source Dependencies ---
for config_file in "/usr/local/etc/phoenix_hypervisor_config.sh" "./phoenix_hypervisor_config.sh"; do
    if [[ -f "$config_file" ]]; then
        if ! bash -n "$config_file"; then
            echo "ERROR: Syntax error in $config_file" >&2
            exit 1
        fi
        check_for_local_errors "$config_file"
        source "$config_file"
        if command -v log_info >/dev/null 2>&1; then
            log_info "Sourced config from $config_file"
        elif [[ "$config_file" != "/usr/local/etc/phoenix_hypervisor_config.sh" ]]; then
            echo "WARNING: Sourced config from current directory. Prefer /usr/local/etc/phoenix_hypervisor_config.sh" >&2
        fi
        break
    fi
done
if [[ -z "${PHOENIX_LXC_CONFIG_FILE:-}" ]]; then
    echo "ERROR: Configuration file not found: /usr/local/etc/phoenix_hypervisor_config.sh or ./phoenix_hypervisor_config.sh" >&2
    exit 1
fi

for common_file in "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" "/usr/local/bin/phoenix_hypervisor_common.sh" "./phoenix_hypervisor_common.sh"; do
    if [[ -f "$common_file" ]]; then
        if ! bash -n "$common_file"; then
            echo "ERROR: Syntax error in $common_file" >&2
            exit 1
        fi
        check_for_local_errors "$common_file"
        source "$common_file"
        if command -v log_info >/dev/null 2>&1; then
            log_info "Sourced common functions from $common_file"
        elif [[ "$common_file" != "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
            echo "WARNING: Sourced common functions from $common_file. Prefer /usr/local/lib/phoenix_hypervisor/" >&2
        fi
        break
    fi
done
if ! command -v log_info >/dev/null 2>&1; then
    echo "ERROR: Common functions file not found in standard locations." >&2
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

    local node available_memory_mb available_cores available_storage_gb
    node=$(hostname)
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
        log_warn "Token file $token_file permissions are $permissions, setting to 600"
        chmod 600 "$token_file" || {
            log_error "Failed to set permissions to 600 for $token_file"
            return 1
        }
    fi
    log_info "Token file $token_file has correct permissions (600)"
    return 0
}

# --- NVIDIA Setup for GPU Containers ---
install_nvidia_in_container() {
    local container_id="$1"
    log_info "Installing NVIDIA driver, toolkit, and CUDA 12.8 in container $container_id..."

    local has_gpu=false
    if pct config "$container_id" | grep -q "nvidia"; then
        has_gpu=true
        log_info "GPU devices detected in container $container_id configuration"
    else
        log_info "No GPU devices assigned to container $container_id, skipping NVIDIA setup"
        return 0
    fi

    pct exec "$container_id" -- bash -c "apt update && apt install -y curl gnupg ca-certificates build-essential" || {
        log_error "Failed to install prerequisites in container $container_id"
        return 1
    }

    local driver_version="${PHOENIX_NVIDIA_DRIVER_VERSION:-580.76.05}"
    local runfile="NVIDIA-Linux-x86_64-${driver_version}.run"
    local download_url="${PHOENIX_NVIDIA_RUNFILE_URL:-https://us.download.nvidia.com/XFree86/Linux-x86_64/580.76.05/NVIDIA-Linux-x86_64-580.76.05.run}"
    pct exec "$container_id" -- bash -c "curl -fsSL '$download_url' -o '$runfile' && chmod +x '$runfile'" || {
        log_error "Failed to download NVIDIA driver runfile in container $container_id"
        return 1
    }
    pct exec "$container_id" -- bash -c "./$runfile --no-kernel-modules --silent --install-libglvnd && rm -f '$runfile'" || {
        log_error "Failed to install NVIDIA driver $driver_version in container $container_id"
        return 1
    }
    log_info "NVIDIA driver $driver_version installed in container $container_id"

    pct exec "$container_id" -- bash -c "curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list && apt update && apt install -y nvidia-container-toolkit && nvidia-ctk runtime configure --runtime=docker && systemctl restart docker" || {
        log_error "Failed to install nvidia-container-toolkit in container $container_id"
        return 1
    }
    log_info "nvidia-container-toolkit installed and configured in container $container_id"

    pct exec "$container_id" -- bash -c "curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb -o cuda-keyring.deb && dpkg -i cuda-keyring.deb && apt update && apt install -y cuda-toolkit-12-8" || {
        log_error "Failed to install CUDA 12.8 toolkit in container $container_id"
        return 1
    }
    log_info "CUDA 12.8 toolkit installed in container $container_id"

    local nvidia_smi_output
    nvidia_smi_output=$(pct exec "$container_id" -- nvidia-smi 2>&1) || {
        log_error "nvidia-smi failed in container $container_id"
        return 1
    }
    local installed_version
    installed_version=$(echo "$nvidia_smi_output" | grep "Driver Version" | awk '{print $3}')
    if [[ "$installed_version" != "$driver_version" ]]; then
        log_error "Driver version mismatch in container $container_id. Expected $driver_version, got $installed_version"
        return 1
    }
    log_info "NVIDIA driver $driver_version verified in container $container_id"

    local docker_test
    docker_test=$(pct exec "$container_id" -- bash -c "docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi 2>&1") || {
        log_error "Docker GPU test failed in container $container_id: $docker_test"
        return 1
    }
    log_info "Docker GPU test passed in container $container_id"

    return 0
}

main() {
    local quiet_mode="${QUIET_MODE:-false}"
    if [[ "$quiet_mode" != "true" ]]; then
        echo "==============================================="
        echo "PHOENIX HYPERVISOR: CREATING LXC CONTAINER $container_id"
        echo "==============================================="
    fi
    log_info "Starting creation of container $container_id..."

    if [[ ! -d "/mnt/phoenix_docker_images" ]]; then
        log_info "Creating /mnt/phoenix_docker_images..."
        mkdir -p "/mnt/phoenix_docker_images" || {
            log_error "Failed to create /mnt/phoenix_docker_images"
            exit 1
        }
        chmod 755 "/mnt/phoenix_docker_images" || log_warn "Could not set permissions on /mnt/phoenix_docker_images"
        log_info "Created /mnt/phoenix_docker_images"
    fi

    if ! check_proxmox_resources; then
        log_error "Resource check failed for container $container_id"
        exit 1
    fi

    if [[ "$container_id" -ge 900 && "$container_id" -le 902 ]] || [[ "$container_id" == "999" ]]; then
        if ! check_token_permissions "$PHOENIX_HF_TOKEN_FILE" || ! check_token_permissions "$PHOENIX_DOCKER_TOKEN_FILE"; then
            log_error "Token permission check failed for container $container_id"
            exit 1
        fi
    fi

    local ai_framework
    if [[ "$container_id" -ge 900 && "$container_id" -le 902 ]]; then
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

    if ! create_lxc_container "$container_id" "$container_config"; then
        log_error "Failed to create container $container_id"
        exit 1
    fi

    if ! validate_container_status "$container_id"; then
        log_error "Container $container_id is not running or has network issues"
        exit 1
    fi

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

    local container_codename
    container_codename=$(pct_exec_with_retry "$container_id" bash -c "lsb_release -cs 2>/dev/null || echo 'unknown'")
    if [[ "$container_codename" != "unknown" ]]; then
        log_info "Container codename: $container_codename (template: $template_path)"
    else
        log_info "Container codename not available, continuing with setup"
    fi

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
        if ! install_nvidia_in_container "$container_id"; then
            log_error "Failed to install NVIDIA driver/toolkit/CUDA in container $container_id"
            exit 1
        fi
    fi

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

    if [[ "$quiet_mode" != "true" ]]; then
        echo "==============================================="
        echo "PHOENIX HYPERVISOR: CONTAINER $container_id CREATED SUCCESSFULLY"
        echo "==============================================="
    fi
    log_info "Container $container_id created and configured successfully"
    exit 0
}

main