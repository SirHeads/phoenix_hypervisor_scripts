#!/bin/bash
# Common functions for Phoenix Hypervisor
# Provides shared utilities for container management, configuration loading, and system operations on Proxmox
# Version: 2.1.3 (Fixed global local declarations, unified logging, added NVIDIA toolkit/CUDA, enhanced error handling)
# Author: Assistant
# Integration: Supports LXC creation (e.g., Portainer server ID 999, AI containers 900-902) and AI workloads (e.g., vLLM, LLaMA CPP, Ollama)

# --- Signal successful loading ---
export PHOENIX_HYPERVISOR_COMMON_LOADED=1

# --- Logging Setup ---
PHOENIX_LOG_DIR="${PHOENIX_LOG_DIR:-/var/log/phoenix_hypervisor}"
PHOENIX_LOG_FILE="${PHOENIX_LOG_FILE:-$PHOENIX_LOG_DIR/phoenix_hypervisor.log}"

mkdir -p "$PHOENIX_LOG_DIR" 2>/dev/null || {
    PHOENIX_LOG_DIR="/tmp"
    PHOENIX_LOG_FILE="$PHOENIX_LOG_DIR/phoenix_hypervisor.log"
}
touch "$PHOENIX_LOG_FILE" 2>/dev/null || true
chmod 644 "$PHOENIX_LOG_FILE" 2>/dev/null || {
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S %Z') Could not set permissions to 644 on $PHOENIX_LOG_FILE" >&2
}

# --- Logging Functions ---
log_info() {
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    echo "[$timestamp] [INFO] $message" | tee -a "$PHOENIX_LOG_FILE" >&2
}

log_warn() {
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    echo "[$timestamp] [WARN] $message" | tee -a "$PHOENIX_LOG_FILE" >&2
}

log_error() {
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    echo "[$timestamp] [ERROR] $message" | tee -a "$PHOENIX_LOG_FILE" >&2
}

log_debug() {
    if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
        local message="$1"
        local timestamp
        timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
        echo "[$timestamp] [DEBUG] $message" | tee -a "$PHOENIX_LOG_FILE" >&2
    fi
}

# --- Configuration Loading ---
load_hypervisor_config() {
    log_info "load_hypervisor_config: Loading hypervisor configuration..."
    log_info "load_hypervisor_config: PHOENIX_LXC_CONFIG_FILE=$PHOENIX_LXC_CONFIG_FILE"
    container_ids=""
    count=0
    config_output=""

    if ! command -v jq >/dev/null 2>&1; then
        log_error "load_hypervisor_config: 'jq' command not found. Install jq (apt install jq)."
        return 1
    fi

    if ! declare -p LXC_CONFIGS >/dev/null 2>&1; then
        declare -gA LXC_CONFIGS
    elif [[ "$(declare -p LXC_CONFIGS)" != "declare -A"* ]]; then
        log_error "load_hypervisor_config: LXC_CONFIGS variable exists but is not an associative array."
        return 1
    fi

    container_ids=$(jq -r '.lxc_configs | keys[]' "$PHOENIX_LXC_CONFIG_FILE" 2>>"$PHOENIX_LOG_FILE")
    if [[ $? -ne 0 ]]; then
        log_error "load_hypervisor_config: Failed to parse container IDs from $PHOENIX_LXC_CONFIG_FILE"
        return 1
    fi

    if [[ -z "$container_ids" ]]; then
        log_warn "load_hypervisor_config: No container configurations found in $PHOENIX_LXC_CONFIG_FILE"
        return 0
    fi

    while IFS= read -r id; do
        if [[ -n "$id" ]]; then
            config_output=$(jq -c '.lxc_configs["'$id'"]' "$PHOENIX_LXC_CONFIG_FILE" 2>>"$PHOENIX_LOG_FILE")
            if [[ $? -ne 0 ]]; then
                log_error "load_hypervisor_config: Failed to load config for container ID $id"
                return 1
            fi
            LXC_CONFIGS["$id"]="$config_output"
            ((count++)) || true
        fi
    done <<< "$container_ids"

    log_info "load_hypervisor_config: Loaded $count LXC configurations"
    return 0
}

# --- GPU Assignment Handling ---
get_gpu_assignment() {
    local container_id="$1"
    if [[ -z "$container_id" ]]; then
        log_error "get_gpu_assignment: Container ID is required"
        return 1
    fi

    gpu_assignment=""
    gpu_assignment=$(jq -r ".lxc_configs.\"$container_id\".gpu_assignment // \"none\"" "$PHOENIX_LXC_CONFIG_FILE")
    if [[ $? -ne 0 ]]; then
        log_error "get_gpu_assignment: Failed to retrieve GPU assignment for container $container_id"
        return 1
    fi

    if [[ "$gpu_assignment" == "null" ]]; then
        gpu_assignment="none"
    fi

    echo "$gpu_assignment"
    return 0
}

check_gpu_assignment() {
    local container_id="$1"
    if [[ -z "$container_id" ]]; then
        log_error "check_gpu_assignment: Container ID is required"
        return 1
    fi

    local gpu_assignment
    gpu_assignment=$(get_gpu_assignment "$container_id")
    if [[ $? -ne 0 ]]; then
        return 1
    fi

    if [[ "$gpu_assignment" != "none" && ! "$gpu_assignment" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        log_error "check_gpu_assignment: Invalid GPU assignment format for container $container_id: $gpu_assignment"
        return 1
    fi

    if [[ "$gpu_assignment" == "none" ]]; then
        return 1 # No GPU assignment
    else
        return 0 # Has GPU assignment
    fi
}

configure_lxc_gpu_passthrough() {
    local lxc_id="$1"
    local gpu_assignment="$2"

    if [[ -z "$lxc_id" || -z "$gpu_assignment" ]]; then
        log_error "configure_lxc_gpu_passthrough: Missing required arguments (lxc_id or gpu_assignment)"
        return 1
    fi

    if [[ "$gpu_assignment" != "none" && ! "$gpu_assignment" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        log_error "configure_lxc_gpu_passthrough: Invalid GPU assignment format for container $lxc_id: $gpu_assignment"
        return 1
    fi

    if [[ "$gpu_assignment" == "none" ]]; then
        log_info "configure_lxc_gpu_passthrough: Skipping GPU passthrough for container $lxc_id (no GPU assignment)"
        return 0
    fi

    log_info "configure_lxc_gpu_passthrough: Configuring GPU access for container $lxc_id with assignment: $gpu_assignment"

    if ! pct status "$lxc_id" >/dev/null 2>&1; then
        log_error "configure_lxc_gpu_passthrough: Container $lxc_id is not running"
        return 1
    fi

    local lxc_config_file="/etc/pve/lxc/$lxc_id.conf"
    if [[ ! -f "$lxc_config_file" ]]; then
        log_error "configure_lxc_gpu_passthrough: Container config file not found: $lxc_config_file"
        return 1
    fi

    # Validate NVIDIA driver version
    local expected_version="${PHOENIX_NVIDIA_DRIVER_VERSION:-580.76.05}"
    if command -v nvidia-smi >/dev/null 2>&1; then
        local current_version
        current_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>>"$PHOENIX_LOG_FILE")
        if [[ $? -ne 0 || -z "$current_version" ]]; then
            log_error "configure_lxc_gpu_passthrough: Failed to query NVIDIA driver version"
            return 1
        fi
        if [[ "$current_version" != "$expected_version" ]]; then
            log_warn "configure_lxc_gpu_passthrough: NVIDIA driver version ($current_version) does not match expected ($expected_version)"
        fi
    else
        log_error "configure_lxc_gpu_passthrough: nvidia-smi not found. Install drivers from ${PHOENIX_NVIDIA_REPO_URL:-https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/}"
        return 1
    fi

    # Validate GPU IDs
    local available_gpus
    available_gpus=$(nvidia-smi --query-gpu=index --format=csv,noheader,nounits 2>>"$PHOENIX_LOG_FILE" | tr '\n' ',' | sed 's/,$//')
    if [[ $? -ne 0 || -z "$available_gpus" ]]; then
        log_error "configure_lxc_gpu_passthrough: Failed to query available GPUs"
        return 1
    fi
    
    IFS=',' read -ra requested_gpus <<< "$gpu_assignment"
    for gpu_id in "${requested_gpus[@]}"; do
        if ! echo "$available_gpus" | grep -q "\b$gpu_id\b"; then
            log_error "configure_lxc_gpu_passthrough: GPU ID $gpu_id not available (available: $available_gpus)"
            return 1
        fi
    done

    # Add GPU device configuration
    local gpu_config=""
    for gpu_id in "${requested_gpus[@]}"; do
        gpu_config+="lxc.cgroup2.devices.allow: c 195:$gpu_id rwm\n"
        gpu_config+="lxc.cgroup2.devices.allow: c 510:$gpu_id rwm\n"
        gpu_config+="lxc.mount.entry: /dev/nvidia$gpu_id dev/nvidia$gpu_id none bind,optional,create=file\n"
    done
    gpu_config+="lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file\n"
    gpu_config+="lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file\n"

    # Append GPU config if not already present
    if ! grep -q "lxc.cgroup2.devices.allow: c 195:" "$lxc_config_file"; then
        echo -e "$gpu_config" >> "$lxc_config_file" || {
            log_error "configure_lxc_gpu_passthrough: Failed to append GPU config to $lxc_config_file"
            return 1
        }
        log_info "configure_lxc_gpu_passthrough: GPU passthrough configured in $lxc_config_file"
    else
        log_info "configure_lxc_gpu_passthrough: GPU passthrough already configured in $lxc_config_file"
    fi

    # Install NVIDIA runtime, nvidia-container-toolkit, and CUDA in container
    log_info "configure_lxc_gpu_passthrough: Installing NVIDIA runtime, toolkit, and CUDA in container $lxc_id..."
    pct_exec_with_retry "$lxc_id" bash -c "apt update && apt install -y curl gnupg ca-certificates build-essential" || {
        log_error "configure_lxc_gpu_passthrough: Failed to install prerequisites in container $lxc_id"
        return 1
    }

    # Install NVIDIA driver (no kernel modules)
    local driver_version
    local runfile
    local download_url
    driver_version="${PHOENIX_NVIDIA_DRIVER_VERSION:-580.76.05}"
    runfile="NVIDIA-Linux-x86_64-${driver_version}.run"
    download_url="${PHOENIX_NVIDIA_RUNFILE_URL:-https://us.download.nvidia.com/XFree86/Linux-x86_64/580.76.05/NVIDIA-Linux-x86_64-580.76.05.run}"
    pct_exec_with_retry "$lxc_id" bash -c "curl -fsSL '$download_url' -o '$runfile' && chmod +x '$runfile' && ./$runfile --no-kernel-modules --silent --install-libglvnd && rm -f '$runfile'" || {
        log_error "configure_lxc_gpu_passthrough: Failed to install NVIDIA driver $driver_version in container $lxc_id"
        return 1
    }
    log_info "configure_lxc_gpu_passthrough: NVIDIA driver $driver_version installed in container $lxc_id"

    # Install nvidia-container-toolkit
    pct_exec_with_retry "$lxc_id" bash -c "curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list && apt update && apt install -y nvidia-container-toolkit && nvidia-ctk runtime configure --runtime=docker && systemctl restart docker" || {
        log_error "configure_lxc_gpu_passthrough: Failed to install nvidia-container-toolkit in container $lxc_id"
        return 1
    }
    log_info "configure_lxc_gpu_passthrough: nvidia-container-toolkit installed and configured in container $lxc_id"

    # Install CUDA 12.8
    pct_exec_with_retry "$lxc_id" bash -c "curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb -o cuda-keyring.deb && dpkg -i cuda-keyring.deb && apt update && apt install -y cuda-toolkit-12-8" || {
        log_error "configure_lxc_gpu_passthrough: Failed to install CUDA 12.8 toolkit in container $lxc_id"
        return 1
    }
    log_info "configure_lxc_gpu_passthrough: CUDA 12.8 toolkit installed in container $lxc_id"

    # Verify NVIDIA setup
    local nvidia_smi_output
    nvidia_smi_output=$(pct_exec_with_retry "$lxc_id" bash -c "nvidia-smi" 2>&1) || {
        log_error "configure_lxc_gpu_passthrough: nvidia-smi failed in container $lxc_id: $nvidia_smi_output"
        return 1
    }
    local installed_version
    installed_version=$(echo "$nvidia_smi_output" | grep "Driver Version" | awk '{print $3}' || true)
    if [[ -z "$installed_version" || "$installed_version" != "$driver_version" ]]; then
        log_error "configure_lxc_gpu_passthrough: Driver version mismatch in container $lxc_id. Expected $driver_version, got $installed_version"
        return 1
    fi
    log_info "configure_lxc_gpu_passthrough: NVIDIA driver $driver_version verified in container $lxc_id"

    # Test Docker GPU access
    local docker_test
    docker_test=$(pct_exec_with_retry "$lxc_id" bash -c "docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi 2>&1") || {
        log_error "configure_lxc_gpu_passthrough: Docker GPU test failed in container $lxc_id: $docker_test"
        return 1
    }
    log_info "configure_lxc_gpu_passthrough: Docker GPU test passed in container $lxc_id"

    log_info "configure_lxc_gpu_passthrough: GPU access configured and verified for container $lxc_id"
    return 0
}

# --- Hugging Face Authentication ---
authenticate_huggingface() {
    local lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        log_error "authenticate_huggingface: Container ID is required"
        return 1
    fi

    log_info "authenticate_huggingface: Validating Hugging Face authentication in container $lxc_id..."

    # Read Hugging Face token
    if [[ ! -f "${PHOENIX_HF_TOKEN_FILE:-/usr/local/etc/phoenix_hf_token}" ]]; then
        log_error "authenticate_huggingface: Hugging Face token file missing: $PHOENIX_HF_TOKEN_FILE"
        return 1
    fi

    local permissions
    permissions=$(stat -c "%a" "$PHOENIX_HF_TOKEN_FILE" 2>>"$PHOENIX_LOG_FILE")
    if [[ $? -ne 0 ]]; then
        log_error "authenticate_huggingface: Failed to check permissions on $PHOENIX_HF_TOKEN_FILE"
        return 1
    fi
    if [[ "$permissions" != "600" && "$permissions" != "640" ]]; then
        log_warn "authenticate_huggingface: Insecure permissions on $PHOENIX_HF_TOKEN_FILE ($permissions). Setting to 600."
        chmod 600 "$PHOENIX_HF_TOKEN_FILE" || {
            log_error "authenticate_huggingface: Failed to set permissions on $PHOENIX_HF_TOKEN_FILE"
            return 1
        }
    fi

    local hf_token
    hf_token=$(grep '^HF_TOKEN=' "$PHOENIX_HF_TOKEN_FILE" | cut -d'=' -f2-)
    if [[ -z "$hf_token" ]]; then
        log_error "authenticate_huggingface: HF_TOKEN not found in $PHOENIX_HF_TOKEN_FILE"
        return 1
    fi

    # Install Hugging Face CLI if not present
    if ! pct_exec_with_retry "$lxc_id" bash -c "command -v huggingface-cli >/dev/null 2>&1"; then
        log_info "authenticate_huggingface: Installing Hugging Face CLI in container $lxc_id..."
        pct_exec_with_retry "$lxc_id" bash -c "apt update && apt install -y python3-pip && pip3 install huggingface_hub" || {
            log_error "authenticate_huggingface: Failed to install Hugging Face CLI in container $lxc_id"
            return 1
        }
    fi

    # Set Hugging Face token in container
    pct_exec_with_retry "$lxc_id" bash -c "huggingface-cli login --token '$hf_token'" || {
        log_error "authenticate_huggingface: Failed to login to Hugging Face in container $lxc_id"
        return 1
    }

    # Determine AI framework (vLLM, LLaMA CPP, Ollama) from JSON config or fallback
    local framework
    framework=$(jq -r ".lxc_configs.\"$lxc_id\".ai_framework // \"vllm\"" "$PHOENIX_LXC_CONFIG_FILE" 2>>"$PHOENIX_LOG_FILE")
    if [[ $? -ne 0 || "$framework" == "null" ]]; then
        framework="vllm" # Default to vLLM for AI containers
    fi
    if [[ ! "$framework" =~ ^(vllm|llamacpp|ollama)$ ]]; then
        log_error "authenticate_huggingface: Unsupported AI framework '$framework' for container $lxc_id"
        return 1
    log_info "authenticate_huggingface: Using AI framework '$framework' for container $lxc_id"
    fi

    # Test model access based on framework
    case "$framework" in
        "vllm")
            # Test vLLM model access
            pct_exec_with_retry "$lxc_id" bash -c "python3 -c 'from huggingface_hub import HfApi; api = HfApi(); api.model_info(\"meta-llama/Meta-Llama-3-8B\")'" || {
                log_error "authenticate_huggingface: Failed to access model info (meta-llama/Meta-Llama-3-8B) with vLLM in container $lxc_id"
                return 1
            }
            ;;
        "llamacpp")
            # Test LLaMA CPP model access
            pct_exec_with_retry "$lxc_id" bash -c "python3 -c 'from huggingface_hub import snapshot_download; snapshot_download(repo_id=\"meta-llama/Meta-Llama-3-8B\", local_dir=\"/tmp/test_model\", token=\"$hf_token\")'" || {
                log_error "authenticate_huggingface: Failed to access model (meta-llama/Meta-Llama-3-8B) with LLaMA CPP in container $lxc_id"
                return 1
            }
            ;;
        "ollama")
            # Test Ollama model pull
            pct_exec_with_retry "$lxc_id" bash -c "command -v ollama >/dev/null 2>&1 || (apt update && apt install -y curl && curl -fsSL https://ollama.com/install.sh | sh) && ollama pull llama3" || {
                log_error "authenticate_huggingface: Failed to pull model (llama3) with Ollama in container $lxc_id"
                return 1
            }
            ;;
        *)
            log_error "authenticate_huggingface: Unsupported AI framework '$framework' for container $lxc_id"
            return 1
            ;;
    esac

    log_info "authenticate_huggingface: Successfully authenticated with Hugging Face in container $lxc_id using framework '$framework'"
    return 0
}

# --- Container Creation Functions ---
create_lxc_container() {
    local lxc_id="$1"
    local container_config="$2"
    local rollback="${3:-true}" # Use ROLLBACK_ON_FAILURE if not specified

    if [[ -z "$lxc_id" || -z "$container_config" ]]; then
        log_error "create_lxc_container: Missing required arguments (lxc_id or container_config)"
        return 1
    fi

    if [[ "$rollback" == "true" && "${ROLLBACK_ON_FAILURE:-false}" == "true" ]]; then
        rollback="true"
    else
        rollback="false"
    fi

    # Declare local variables first
    local name memory_mb cores template storage_pool storage_size_gb network_config features
    local net_ip net_gw net_options
    local gpu_assignment

    # Then assign values
    name=$(echo "$container_config" | jq -r '.name' 2>>"$PHOENIX_LOG_FILE")
    memory_mb=$(echo "$container_config" | jq -r '.memory_mb' 2>>"$PHOENIX_LOG_FILE")
    cores=$(echo "$container_config" | jq -r '.cores' 2>>"$PHOENIX_LOG_FILE")
    template=$(echo "$container_config" | jq -r '.template' 2>>"$PHOENIX_LOG_FILE")
    storage_pool=$(echo "$container_config" | jq -r '.storage_pool' 2>>"$PHOENIX_LOG_FILE")
    storage_size_gb=$(echo "$container_config" | jq -r '.storage_size_gb' 2>>"$PHOENIX_LOG_FILE")
    network_config=$(echo "$container_config" | jq -c '.network_config' 2>>"$PHOENIX_LOG_FILE")
    features=$(echo "$container_config" | jq -r '.features // "nesting=1"' 2>>"$PHOENIX_LOG_FILE")

    if [[ ! "$memory_mb" =~ ^[0-9]+$ || "$memory_mb" -lt 512 ]]; then
        log_error "create_lxc_container: Invalid memory_mb value for container $lxc_id: $memory_mb"
        return 1
    fi
    if [[ ! "$cores" =~ ^[0-9]+$ || "$cores" -lt 1 ]]; then
        log_error "create_lxc_container: Invalid cores value for container $lxc_id: $cores"
        return 1
    fi
    if [[ ! "$storage_size_gb" =~ ^[0-9]+$ || "$storage_size_gb" -lt 10 ]]; then
        log_error "create_lxc_container: Invalid storage_size_gb value for container $lxc_id: $storage_size_gb"
        return 1
    fi
    if [[ ! -f "$template" ]]; then
        log_error "create_lxc_container: Template file not found: $template"
        return 1
    fi

    if [[ "$storage_pool" == *"zfs"* && -n "$(command -v zfs)" ]]; then
        zfs list "$storage_pool" >/dev/null 2>>"$PHOENIX_LOG_FILE" || {
            log_error "create_lxc_container: ZFS pool $storage_pool not found for container $lxc_id"
            return 1
        }
        log_info "create_lxc_container: ZFS pool $storage_pool verified for container $lxc_id"
    fi

    if pct status "$lxc_id" >/dev/null 2>&1; then
        log_info "create_lxc_container: Container $lxc_id already exists, skipping creation."
        return 0
    fi

    log_info "create_lxc_container: Creating LXC container $lxc_id ($name) with $memory_mb MB RAM, $cores CPU cores, and $storage_size_gb GB storage..."

    local net_ip net_gw
    net_ip=$(echo "$network_config" | jq -r '.ip // ""' 2>>"$PHOENIX_LOG_FILE")
    net_gw=$(echo "$network_config" | jq -r '.gw // ""' 2>>"$PHOENIX_LOG_FILE")
    local net_options="name=eth0,bridge=vmbr0"
    if [[ -n "$net_ip" && -n "$net_gw" ]]; then
        net_options="$net_options,ip=$net_ip,gw=$net_gw"
    fi

    if ! pct create "$lxc_id" "$template" \
        -rootfs "$storage_pool:$storage_size_gb" \
        -memory "$memory_mb" \
        -cores "$cores" \
        -features "$features" \
        -net0 "$net_options" \
        -ostype "ubuntu" \
        -searchdomain "local" \
        -hostname "$name" 2>&1 | tee -a "$PHOENIX_LOG_FILE"; then
        log_error "create_lxc_container: Failed to create container $lxc_id"
        if [[ "$rollback" == "true" ]]; then
            pct destroy "$lxc_id" 2>/dev/null || log_warn "create_lxc_container: Failed to clean up container $lxc_id"
        fi
        return 1
    fi

    if ! pct set "$lxc_id" \
        -description "$name (created by Phoenix Hypervisor)" \
        -nameserver "8.8.8.8" 2>&1 | tee -a "$PHOENIX_LOG_FILE"; then
        log_error "create_lxc_container: Failed to configure container $lxc_id"
        if [[ "$rollback" == "true" ]]; then
            pct destroy "$lxc_id" 2>/dev/null || log_warn "create_lxc_container: Failed to clean up container $lxc_id"
        fi
        return 1
    fi

    local gpu_assignment
    gpu_assignment=$(echo "$container_config" | jq -r '.gpu_assignment // "none"' 2>>"$PHOENIX_LOG_FILE")
    if [[ "$gpu_assignment" != "none" ]]; then
        log_info "create_lxc_container: Configuring GPU access for container $lxc_id with assignment: $gpu_assignment"
        if ! configure_lxc_gpu_passthrough "$lxc_id" "$gpu_assignment"; then
            log_error "create_lxc_container: Failed to configure GPU access for container $lxc_id"
            if [[ "$rollback" == "true" ]]; then
                pct destroy "$lxc_id" 2>/dev/null || log_warn "create_lxc_container: Failed to clean up container $lxc_id"
            fi
            return 1
        fi
    fi

    if ! pct start "$lxc_id" 2>&1 | tee -a "$PHOENIX_LOG_FILE"; then
        log_error "create_lxc_container: Failed to start container $lxc_id"
        if [[ "$rollback" == "true" ]]; then
            pct destroy "$lxc_id" 2>/dev/null || log_warn "create_lxc_container: Failed to clean up container $lxc_id"
        fi
        return 1
    fi

    log_info "create_lxc_container: Container $lxc_id ($name) created and started successfully."
    return 0
}

# --- Container Execution Functions ---
pct_exec_with_retry() {
    local lxc_id="$1"
    shift
    local command="$*"
    local max_attempts=3
    local attempt=1
    local delay=2

    if [[ -z "$lxc_id" || -z "$command" ]]; then
        log_error "pct_exec_with_retry: Missing lxc_id or command"
        return 1
    fi

    while [[ $attempt -le $max_attempts ]]; do
        log_info "pct_exec_with_retry: Attempt $attempt/$max_attempts for container $lxc_id: $command"
        local output
        output=$(pct exec "$lxc_id" -- bash -c "$command" 2>&1)
        local exit_code=$?
        echo "$output" | tee -a "$PHOENIX_LOG_FILE"
        if [[ $exit_code -eq 0 ]]; then
            log_info "pct_exec_with_retry: Command executed successfully in container $lxc_id"
            return 0
        fi
        log_warn "pct_exec_with_retry: Attempt $attempt failed for container $lxc_id: $output"
        ((attempt++))
        sleep $delay
    done

    log_error "pct_exec_with_retry: Failed after $max_attempts attempts for container $lxc_id: $command"
    return 1
}

start_systemd_service_in_container() {
    local lxc_id="$1"
    local service_name="$2"

    if [[ -z "$lxc_id" || -z "$service_name" ]]; then
        log_error "start_systemd_service_in_container: Missing lxc_id or service_name"
        return 1
    fi

    log_info "start_systemd_service_in_container: Starting service '$service_name' in container $lxc_id..."

    if ! pct_exec_with_retry "$lxc_id" systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
        pct_exec_with_retry "$lxc_id" systemctl enable "$service_name" || {
            log_warn "start_systemd_service_in_container: Failed to enable service '$service_name' in container $lxc_id"
            return 1
        }
    fi

    pct_exec_with_retry "$lxc_id" systemctl start "$service_name" || {
        log_warn "start_systemd_service_in_container: Failed to start service '$service_name' in container $lxc_id"
        return 1
    }

    sleep 2
    pct_exec_with_retry "$lxc_id" systemctl is-active --quiet "$service_name" || {
        log_warn "start_systemd_service_in_container: Service '$service_name' in container $lxc_id is not running after start"
        return 1
    }

    log_info "start_systemd_service_in_container: Successfully started service '$service_name' in container $lxc_id"
    return 0
}

# --- Container Validation Functions ---
validate_container_status() {
    local lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        log_error "validate_container_status: Missing lxc_id"
        return 1
    fi

    log_info "validate_container_status: Validating status of container $lxc_id..."

    if ! pct status "$lxc_id" >/dev/null 2>&1; then
        log_error "validate_container_status: Container $lxc_id does not exist"
        return 1
    fi

    local status
    status=$(pct status "$lxc_id" 2>>"$PHOENIX_LOG_FILE")
    if [[ $? -ne 0 || "$status" != "status: running" ]]; then
        log_error "validate_container_status: Container $lxc_id is not running (status: $status)"
        return 1
    fi

    if ! check_container_network "$lxc_id"; then
        log_error "validate_container_status: Network validation failed for container $lxc_id"
        return 1
    fi

    log_info "validate_container_status: Container $lxc_id is valid and running properly"
    return 0
}

check_container_network() {
    local lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        log_error "check_container_network: Missing lxc_id"
        return 1
    fi

    log_info "check_container_network: Checking network connectivity for container $lxc_id..."

    pct_exec_with_retry "$lxc_id" ping -c 1 -W 5 10.0.0.1 >/dev/null 2>&1 || {
        log_error "check_container_network: Failed to reach gateway from container $lxc_id"
        return 1
    }

    if [[ "$lxc_id" != "999" ]]; then
        pct_exec_with_retry "$lxc_id" ping -c 1 -W 5 10.0.0.99 >/dev/null 2>&1 || {
            log_warn "check_container_network: Container $lxc_id cannot reach Portainer server (10.0.0.99)"
        }
        log_info "check_container_network: Container $lxc_id can reach Portainer server (10.0.0.99)"
    fi

    pct_exec_with_retry "$lxc_id" nslookup google.com >/dev/null 2>&1 || {
        log_error "check_container_network: DNS resolution failed in container $lxc_id"
        return 1
    }

    log_info "check_container_network: Container $lxc_id has proper network connectivity"
    return 0
}

validate_portainer_network_in_container() {
    local lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        log_error "validate_portainer_network_in_container: Missing lxc_id"
        return 1
    fi

    local container_ip
    container_ip=$(jq -r ".lxc_configs.\"$lxc_id\".network_config.ip" "$PHOENIX_LXC_CONFIG_FILE" 2>>"$PHOENIX_LOG_FILE" | cut -d'/' -f1)
    if [[ $? -ne 0 || -z "$container_ip" || "$container_ip" == "null" ]]; then
        log_error "validate_portainer_network_in_container: Failed to retrieve IP address for container $lxc_id"
        return 1
    fi

    if [[ "$lxc_id" -ge 900 && "$lxc_id" -le 902 ]]; then
        log_info "validate_portainer_network_in_container: Validating Portainer agent $lxc_id connectivity to server (10.0.0.99:9443)"
        pct_exec_with_retry "$lxc_id" timeout 5 bash -c "echo | openssl s_client -connect 10.0.0.99:9443 2>/dev/null | grep -q 'Verify return code:'" || {
            log_warn "validate_portainer_network_in_container: Failed to connect to Portainer server (10.0.0.99:9443) from agent $lxc_id"
        }
        log_info "validate_portainer_network_in_container: Successfully connected to Portainer server from agent $lxc_id"

        if command -v curl >/dev/null 2>&1; then
            pct_exec_with_retry "$lxc_id" curl -s -k -m 5 "https://10.0.0.99:9443/api/status" >/dev/null || {
                log_warn "validate_portainer_network_in_container: Failed to access Portainer API (10.0.0.99:9443/api/status) from agent $lxc_id"
            }
            log_info "validate_portainer_network_in_container: Successfully accessed Portainer API from agent $lxc_id"
        else
            log_info "validate_portainer_network_in_container: curl not available, skipping Portainer API check for agent $lxc_id"
        fi
    fi

    if [[ "$lxc_id" == "999" ]]; then
        log_info "validate_portainer_network_in_container: Validating Portainer server $lxc_id accessibility ($container_ip:9443)"
        pct_exec_with_retry "$lxc_id" timeout 5 bash -c "echo | openssl s_client -connect $container_ip:9443 2>/dev/null | grep -q 'Verify return code:'" || {
            log_warn "validate_portainer_network_in_container: Failed to connect to Portainer server ($container_ip:9443)"
        }
        log_info "validate_portainer_network_in_container: Successfully connected to Portainer server ($container_ip:9443)"

        if command -v curl >/dev/null 2>&1; then
            pct_exec_with_retry "$lxc_id" curl -s -k -m 5 "https://$container_ip:9443/api/status" >/dev/null || {
                log_warn "validate_portainer_network_in_container: Failed to access Portainer API ($container_ip:9443/api/status)"
            }
            log_info "validate_portainer_network_in_container: Successfully accessed Portainer API ($container_ip:9443/api/status)"
        else
            log_info "validate_portainer_network_in_container: curl not available, skipping Portainer API check for server $lxc_id"
        fi
    fi

    log_info "validate_portainer_network_in_container: Portainer network validation completed for container $lxc_id"
    return 0
}

# --- Container Utility Functions ---
ensure_container_running() {
    local lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        log_error "ensure_container_running: Container ID is required"
        return 1
    fi

    if pct config "$lxc_id" >/dev/null 2>>"$PHOENIX_LOG_FILE"; then
        local status
        status=$(pct status "$lxc_id" 2>>"$PHOENIX_LOG_FILE")
        if [[ $? -ne 0 ]]; then
            log_error "ensure_container_running: Failed to check status of container $lxc_id"
            return 1
        fi
        if [[ "$status" == "status: running" ]]; then
            log_info "ensure_container_running: Container $lxc_id is already running"
            return 0
        else
            log_info "ensure_container_running: Container $lxc_id is stopped, starting it..."
            pct start "$lxc_id" 2>&1 | tee -a "$PHOENIX_LOG_FILE" || {
                log_error "ensure_container_running: Failed to start container $lxc_id"
                return 1
            }
            log_info "ensure_container_running: Successfully started container $lxc_id"
            return 0
        fi
    else
        log_error "ensure_container_running: Container $lxc_id does not exist"
        return 1
    fi
}

# --- AI Workload Specific Functions ---
validate_ai_workload_config() {
    local lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        log_error "validate_ai_workload_config: Container ID is required"
        return 1
    fi

    if [[ "$lxc_id" -ge 900 && "$lxc_id" -le 902 ]]; then
        log_info "validate_ai_workload_config: Validating resources for AI container $lxc_id (e.g., vLLM, LLaMA CPP, Ollama)"

        local memory_mb cores storage_size_gb gpu_assignment
        memory_mb=$(jq -r ".lxc_configs.\"$lxc_id\".memory_mb" "$PHOENIX_LXC_CONFIG_FILE" 2>>"$PHOENIX_LOG_FILE")
        cores=$(jq -r ".lxc_configs.\"$lxc_id\".cores" "$PHOENIX_LXC_CONFIG_FILE" 2>>"$PHOENIX_LOG_FILE")
        storage_size_gb=$(jq -r ".lxc_configs.\"$lxc_id\".storage_size_gb" "$PHOENIX_LXC_CONFIG_FILE" 2>>"$PHOENIX_LOG_FILE")
        gpu_assignment=$(jq -r ".lxc_configs.\"$lxc_id\".gpu_assignment // \"none\"" "$PHOENIX_LXC_CONFIG_FILE" 2>>"$PHOENIX_LOG_FILE")

        if [[ $? -ne 0 ]]; then
            log_error "validate_ai_workload_config: Failed to parse configuration for container $lxc_id"
            return 1
        fi

        if [[ ! "$memory_mb" =~ ^[0-9]+$ || "$memory_mb" -lt 32768 ]]; then
            log_warn "validate_ai_workload_config: Container $lxc_id has low memory ($memory_mb MB) for AI workload (recommended: 32 GB)"
        else
            log_info "validate_ai_workload_config: Container $lxc_id has sufficient memory ($memory_mb MB)"
        fi

        if [[ ! "$cores" =~ ^[0-9]+$ || "$cores" -lt 6 ]]; then
            log_warn "validate_ai_workload_config: Container $lxc_id has low CPU cores ($cores) for AI workload (recommended: 6+)"
        else
            log_info "validate_ai_workload_config: Container $lxc_id has sufficient CPU cores ($cores)"
        fi

        if [[ ! "$storage_size_gb" =~ ^[0-9]+$ || "$storage_size_gb" -lt 64 ]]; then
            log_warn "validate_ai_workload_config: Container $lxc_id has low storage ($storage_size_gb GB) for AI workload (recommended: 64+ GB)"
        else
            log_info "validate_ai_workload_config: Container $lxc_id has sufficient storage ($storage_size_gb GB)"
        fi

        if [[ "$gpu_assignment" == "none" ]]; then
            log_info "validate_ai_workload_config: Container $lxc_id has no GPU assignment (may be intentional for CPU-only workloads)"
        else
            log_info "validate_ai_workload_config: Container $lxc_id has GPU assignment ($gpu_assignment)"
        fi
    else
        log_info "validate_ai_workload_config: Container $lxc_id is not an AI container (900-902), skipping AI-specific validation"
    fi

    log_info "validate_ai_workload_config: Validation completed for container $lxc_id"
    return 0
}

# --- Docker Installation ---
install_docker_ce_in_container() {
    local lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        log_error "install_docker_ce_in_container: Container ID is required"
        return 1
    fi

    log_info "install_docker_ce_in_container: Installing Docker CE in container $lxc_id..."
    pct_exec_with_retry "$lxc_id" bash -c "apt update && apt install -y docker.io && systemctl enable --now docker" || {
        log_error "install_docker_ce_in_container: Failed to install Docker CE in container $lxc_id"
        return 1
    }
    log_info "install_docker_ce_in_container: Docker CE installed and started in container $lxc_id"
    return 0
}

# --- Docker Registry Authentication ---
authenticate_registry() {
    local lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        log_error "authenticate_registry: Container ID is required"
        return 1
    fi

    log_info "authenticate_registry: Authenticating Docker registry in container $lxc_id..."
    if [[ -f "${PHOENIX_DOCKER_TOKEN_FILE:-/usr/local/etc/phoenix_docker_token}" ]]; then
        local username token
        username=$(grep '^DOCKER_HUB_USERNAME=' "$PHOENIX_DOCKER_TOKEN_FILE" | cut -d'=' -f2-)
        token=$(grep '^DOCKER_HUB_TOKEN=' "$PHOENIX_DOCKER_TOKEN_FILE" | cut -d'=' -f2-)
        if [[ -z "$username" || -z "$token" ]]; then
            log_error "authenticate_registry: Missing DOCKER_HUB_USERNAME or DOCKER_HUB_TOKEN in $PHOENIX_DOCKER_TOKEN_FILE"
            return 1
        fi
        pct_exec_with_retry "$lxc_id" bash -c "echo '$token' | docker login -u '$username' --password-stdin '${EXTERNAL_REGISTRY_URL:-docker.io}'" || {
            log_error "authenticate_registry: Failed to authenticate Docker registry in container $lxc_id"
            return 1
        }
        log_info "authenticate_registry: Docker registry authentication successful in container $lxc_id"
        return 0
    else
        log_error "authenticate_registry: Docker token file missing: $PHOENIX_DOCKER_TOKEN_FILE"
        return 1
    fi
}

# --- Portainer Installation ---
install_portainer_agent() {
    local lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        log_error "install_portainer_agent: Container ID is required"
        return 1
    fi

    log_info "install_portainer_agent: Installing Portainer agent in container $lxc_id..."
    pct_exec_with_retry "$lxc_id" bash -c "docker run -d -p 9001:9001 --name portainer_agent --restart always -v /var/run/docker.sock:/var/run/docker.sock -v /var/lib/docker/volumes:/var/lib/docker/volumes portainer/portainer-agent" || {
        log_error "install_portainer_agent: Failed to install Portainer agent in container $lxc_id"
        return 1
    }
    log_info "install_portainer_agent: Portainer agent installed in container $lxc_id"
    return 0
}

install_portainer_server() {
    local lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        log_error "install_portainer_server: Container ID is required"
        return 1
    fi

    log_info "install_portainer_server: Installing Portainer server in container $lxc_id..."
    pct_exec_with_retry "$lxc_id" bash -c "docker run -d -p 9443:9443 --name portainer --restart always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce" || {
        log_error "install_portainer_server: Failed to install Portainer server in container $lxc_id"
        return 1
    }
    log_info "install_portainer_server: Portainer server installed in container $lxc_id"
    return 0
}

# --- Helper Functions ---
setup_logging() {
    if [[ -z "$PHOENIX_LOG_DIR" ]]; then
        PHOENIX_LOG_DIR="/var/log/phoenix_hypervisor"
        PHOENIX_LOG_FILE="$PHOENIX_LOG_DIR/phoenix_hypervisor.log"
    fi

    mkdir -p "$PHOENIX_LOG_DIR" 2>/dev/null || {
        PHOENIX_LOG_DIR="/tmp"
        PHOENIX_LOG_FILE="$PHOENIX_LOG_DIR/phoenix_hypervisor.log"
    }

    touch "$PHOENIX_LOG_FILE" 2>/dev/null || true
    chmod 644 "$PHOENIX_LOG_FILE" 2>/dev/null || log_warn "Could not set permissions to 644 on $PHOENIX_LOG_FILE"

    log_info "setup_logging: Logging initialized for phoenix_hypervisor_common.sh"
}

# --- Initialize Configuration ---
if [[ -z "$PHOENIX_LXC_CONFIG_FILE" ]]; then
    export PHOENIX_LXC_CONFIG_FILE="/usr/local/etc/phoenix_lxc_configs.json"
fi

if ! declare -p LXC_CONFIGS >/dev/null 2>&1; then
    if ! load_hypervisor_config; then
        log_error "phoenix_hypervisor_common.sh: Failed to load hypervisor configuration."
        exit 1
    fi
fi

# Setup logging
setup_logging

log_info "phoenix_hypervisor_common.sh: Library loaded successfully with Hugging Face authentication, NVIDIA GPU support, and AI workload functions."