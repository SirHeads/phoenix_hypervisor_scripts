```bash
#!/bin/bash
# Container-specific setup script for drdevstral (LXC ID 901)
# Installs NVIDIA drivers, vLLM, and sets up the AI model
# Version: 1.7.5
# Author: Assistant

# --- Enhanced Sourcing ---
# Source configuration from the standard location
if [[ -f "/usr/local/etc/phoenix_hypervisor_config.sh" ]]; then
    source /usr/local/etc/phoenix_hypervisor_config.sh
else
    # Fallback to current directory if standard location not found (less ideal)
    if [[ -f "./phoenix_hypervisor_config.sh" ]]; then
        source ./phoenix_hypervisor_config.sh
        # Use log function if available, else echo
        if declare -f log_warn > /dev/null 2>&1; then
            log_warn "phoenix_hypervisor_setup_drdevstral.sh: Sourced config from current directory. Prefer /usr/local/etc/phoenix_hypervisor_config.sh"
        else
             echo "[WARN] phoenix_hypervisor_setup_drdevstral.sh: Sourced config from current directory. Prefer /usr/local/etc/phoenix_hypervisor_config.sh" >&2
        fi
    else
        echo "[ERROR] phoenix_hypervisor_setup_drdevstral.sh: Configuration file not found: /usr/local/etc/phoenix_hypervisor_config.sh or ./phoenix_hypervisor_config.sh" >&2
        exit 1
    fi
fi

# Source common functions from the standard location (as defined in corrected common.sh)
# Priority: 1. Standard lib location, 2. Standard bin location, 3. Current directory
if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh
elif [[ -f "/usr/local/bin/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/bin/phoenix_hypervisor_common.sh
    # Use log function if available, else echo
    if declare -f log_warn > /dev/null 2>&1; then
        log_warn "phoenix_hypervisor_setup_drdevstral.sh: Sourced common functions from /usr/local/bin/. Prefer /usr/local/lib/phoenix_hypervisor/."
    else
        echo "[WARN] phoenix_hypervisor_setup_drdevstral.sh: Sourced common functions from /usr/local/bin/. Prefer /usr/local/lib/phoenix_hypervisor/." >&2
    fi
elif [[ -f "./phoenix_hypervisor_common.sh" ]]; then
    source ./phoenix_hypervisor_common.sh
    # Use log function if available, else echo
    if declare -f log_warn > /dev/null 2>&1; then
        log_warn "phoenix_hypervisor_setup_drdevstral.sh: Sourced common functions from current directory. Prefer standard locations."
    else
         echo "[WARN] phoenix_hypervisor_setup_drdevstral.sh: Sourced common functions from current directory. Prefer standard locations." >&2
    fi
else
    echo "[ERROR] phoenix_hypervisor_setup_drdevstral.sh: Common functions file not found in standard locations." >&2
    exit 1
fi

# --- CRITICAL: Source LXC NVIDIA Functions ---
# This script depends on functions like install_nvidia_driver_in_container
# which are defined in phoenix_hypervisor_lxc_common_nvidia.sh
if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_lxc_common_nvidia.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_lxc_common_nvidia.sh
elif [[ -f "./phoenix_hypervisor_lxc_common_nvidia.sh" ]]; then
     source ./phoenix_hypervisor_lxc_common_nvidia.sh
     # Use log function if available, else echo
     if declare -f log_warn > /dev/null 2>&1; then
         log_warn "phoenix_hypervisor_setup_drdevstral.sh: Sourced LXC NVIDIA functions from current directory. Prefer /usr/local/lib/phoenix_hypervisor/."
     else
          echo "[WARN] phoenix_hypervisor_setup_drdevstral.sh: Sourced LXC NVIDIA functions from current directory. Prefer /usr/local/lib/phoenix_hypervisor/." >&2
     fi
else
    echo "[ERROR] phoenix_hypervisor_setup_drdevstral.sh: Required LXC NVIDIA functions file (phoenix_hypervisor_lxc_common_nvidia.sh) not found." >&2
    exit 1
fi

# --- Setup Functions ---

# - Validate Container Configuration -
# Validates the container configuration exists and is valid
validate_container() {
    local container_id="$1"
    # --- START DEBUGGING OUTPUT ---
    log_info "DEBUG validate_container: Starting validation for container_id=$container_id"

    # Ensure jq is available (good practice)
    if ! command -v jq >/dev/null 2>&1; then
        log_error "DEBUG validate_container: 'jq' command not found."
        return 1
    fi

    # Debug: Print the config file path and check existence/readability
    log_info "DEBUG validate_container: PHOENIX_LXC_CONFIG_FILE=$PHOENIX_LXC_CONFIG_FILE"
    if [[ ! -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
         log_error "DEBUG validate_container: Config file does not exist or is not a regular file."
         return 1
    fi
    if [[ ! -r "$PHOENIX_LXC_CONFIG_FILE" ]]; then
         log_error "DEBUG validate_container: Config file is not readable."
         return 1
    fi

    # Debug: Print the container config being fetched
    log_info "DEBUG validate_container: Fetching config for container $container_id"
    local container_config
    container_config=$(jq -c ".lxc_configs.\"$container_id\"" "$PHOENIX_LXC_CONFIG_FILE")
    if [[ -z "$container_config" || "$container_config" == "null" ]]; then
        log_error "DEBUG validate_container: No configuration found for container $container_id in $PHOENIX_LXC_CONFIG_FILE"
        return 1
    fi
    log_info "DEBUG validate_container: Container config fetched successfully: $container_config"

    # Validate required fields
    local required_fields=(
        "name"
        "memory_mb"
        "cores"
        "template"
        "storage_pool"
        "storage_size_gb"
        "network_config"
        "features"
    )

    for field in "${required_fields[@]}"; do
        local value
        value=$(echo "$container_config" | jq -r ".$field")
        if [[ -z "$value" || "$value" == "null" ]]; then
            log_error "DEBUG validate_container: Missing or invalid field '$field' for container $container_id"
            return 1
        fi
        log_info "DEBUG validate_container: Validated field '$field': $value"
    done

    # Validate GPU assignment if present
    local gpu_assignment
    gpu_assignment=$(echo "$container_config" | jq -r '.gpu_assignment // "none"')
    log_info "DEBUG validate_container: GPU assignment: $gpu_assignment"
    if [[ "$gpu_assignment" != "none" ]]; then
        if ! echo "$gpu_assignment" | grep -qE '^[0-9]+(,[0-9]+)*$'; then
            log_error "DEBUG validate_container: Invalid GPU assignment format: $gpu_assignment (expected comma-separated numbers, e.g., '0,1')"
            return 1
        fi
    fi

    # Validate vLLM-specific fields if present
    local vllm_fields=(
        "vllm_model"
        "vllm_tensor_parallel_size"
        "vllm_max_model_len"
        "vllm_kv_cache_dtype"
        "vllm_shm_size"
        "vllm_gpu_count"
        "vllm_quantization"
        "vllm_quantization_config_type"
        "vllm_api_port"
    )

    for field in "${vllm_fields[@]}"; do
        local value
        value=$(echo "$container_config" | jq -r ".$field // empty")
        if [[ -n "$value" ]]; then
            log_info "DEBUG validate_container: vLLM field '$field' present: $value"
        fi
    done

    log_info "DEBUG validate_container: Container $container_id configuration validated successfully."
    return 0
}

# - Helper: Get Container Config Value -
# Retrieves a specific field from container configuration
get_container_config_value() {
    local container_id="$1"
    local field="$2"
    local value

    if ! command -v jq >/dev/null 2>&1; then
        log_error "get_container_config_value: 'jq' command not found."
        return 1
    fi

    value=$(jq -r ".lxc_configs.\"$container_id\".$field // empty" "$PHOENIX_LXC_CONFIG_FILE")
    if [[ -z "$value" || "$value" == "null" ]]; then
        log_error "get_container_config_value: Field '$field' not found or empty for container $container_id"
        return 1
    fi
    echo "$value"
    return 0
}

# - Helper: Execute Command in Container with Retry -
pct_exec_with_retry() {
    local container_id="$1"
    local command="$2"
    local max_attempts=3
    local attempt=1
    local delay=5

    while [[ $attempt -le $max_attempts ]]; do
        log_info "pct_exec_with_retry: Executing command in container $container_id (attempt $attempt/$max_attempts)..."
        if pct exec "$container_id" -- bash -c "$command"; then
            log_info "pct_exec_with_retry: Command executed successfully in container $container_id"
            return 0
        else
            log_warn "pct_exec_with_retry: Command failed in container $container_id. Retrying in $delay seconds..."
            sleep "$delay"
            ((attempt++))
        fi
    done
    log_error "pct_exec_with_retry: Command failed after $max_attempts attempts in container $container_id"
    return 1
}

# - Show Setup Information -
show_setup_info() {
    local container_id="$1"
    log_info "show_setup_info: Displaying setup configuration for container $container_id..."

    echo ""
    echo "==============================================="
    echo "DRDEVSTRAL SETUP CONFIGURATION"
    echo "==============================================="
    echo "Container ID: $container_id"
    local name memory_mb cores template storage_pool storage_size_gb network_config features
    name=$(get_container_config_value "$container_id" "name") || name="N/A"
    memory_mb=$(get_container_config_value "$container_id" "memory_mb") || memory_mb="N/A"
    cores=$(get_container_config_value "$container_id" "cores") || cores="N/A"
    template=$(get_container_config_value "$container_id" "template") || template="N/A"
    storage_pool=$(get_container_config_value "$container_id" "storage_pool") || storage_pool="N/A"
    storage_size_gb=$(get_container_config_value "$container_id" "storage_size_gb") || storage_size_gb="N/A"
    network_config=$(get_container_config_value "$container_id" "network_config") || network_config="N/A"
    features=$(get_container_config_value "$container_id" "features") || features="N/A"
    echo "Name: $name"
    echo "Memory: $memory_mb MB"
    echo "Cores: $cores"
    echo "Template: $template"
    echo "Storage Pool: $storage_pool"
    echo "Storage Size: $storage_size_gb GB"
    echo "Network Config: $network_config"
    echo "Features: $features"
    echo ""
    echo "vLLM Configuration:"
    local vllm_model vllm_tensor_parallel_size vllm_max_model_len vllm_kv_cache_dtype vllm_shm_size vllm_gpu_count vllm_quantization vllm_quantization_config_type vllm_api_port
    vllm_model=$(get_container_config_value "$container_id" "vllm_model") || vllm_model="N/A"
    vllm_tensor_parallel_size=$(get_container_config_value "$container_id" "vllm_tensor_parallel_size") || vllm_tensor_parallel_size="N/A"
    vllm_max_model_len=$(get_container_config_value "$container_id" "vllm_max_model_len") || vllm_max_model_len="N/A"
    vllm_kv_cache_dtype=$(get_container_config_value "$container_id" "vllm_kv_cache_dtype") || vllm_kv_cache_dtype="N/A"
    vllm_shm_size=$(get_container_config_value "$container_id" "vllm_shm_size") || vllm_shm_size="N/A"
    vllm_gpu_count=$(get_container_config_value "$container_id" "vllm_gpu_count") || vllm_gpu_count="N/A"
    vllm_quantization=$(get_container_config_value "$container_id" "vllm_quantization") || vllm_quantization="N/A"
    vllm_quantization_config_type=$(get_container_config_value "$container_id" "vllm_quantization_config_type") || vllm_quantization_config_type="N/A"
    vllm_api_port=$(get_container_config_value "$container_id" "vllm_api_port") || vllm_api_port="N/A"
    echo "Model: $vllm_model"
    echo "Tensor Parallel Size: $vllm_tensor_parallel_size"
    echo "Max Model Length: $vllm_max_model_len"
    echo "KV Cache Data Type: $vllm_kv_cache_dtype"
    echo "Shared Memory Size: $vllm_shm_size"
    echo "GPU Count: $vllm_gpu_count"
    echo "Quantization: $vllm_quantization"
    echo "Quantization Config Type: $vllm_quantization_config_type"
    echo "API Port: $vllm_api_port"
    echo ""
    echo "GPU Assignment:"
    local gpu_assignment
    gpu_assignment=$(get_container_config_value "$container_id" "gpu_assignment") || gpu_assignment="none"
    echo "GPUs: $gpu_assignment"
    echo "==============================================="
    echo ""
}

# - Setup Container Environment -
setup_container_environment() {
    local container_id="$1"
    log_info "setup_container_environment: Setting up environment for container $container_id..."

    # Start the container if not running
    local status
    status=$(pct status "$container_id" 2>/dev/null | grep 'status' | awk '{print $2}')
    if [[ "$status" != "running" ]]; then
        log_info "setup_container_environment: Starting container $container_id..."
        if ! pct start "$container_id"; then
            log_error "setup_container_environment: Failed to start container $container_id"
            return 1
        fi
        # Wait for container to be fully up (networking, etc.)
        sleep 5
    fi

    # Update package lists and install base dependencies
    local setup_cmd="
        set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y python3 python3-pip git curl wget
        # Check if python3-huggingface-hub is available
        if apt-cache show python3-huggingface-hub >/dev/null 2>&1; then
            apt-get install -y python3-huggingface-hub
        else
            # Fallback to pipx if apt package is not available
            apt-get install -y pipx
            pipx install huggingface_hub
            # Ensure huggingface_hub is available in PATH
            pipx ensurepath
        fi
    "
    if ! pct_exec_with_retry "$container_id" "bash -c '$setup_cmd'"; then
        log_error "setup_container_environment: Failed to install base dependencies in container $container_id"
        return 1
    fi

    # Install Docker and NVIDIA Container Toolkit
    log_info "setup_container_environment: Installing Docker and NVIDIA Container Toolkit in container $container_id..."
    local docker_setup_cmd="
        set -e
        apt-get update -y
        apt-get install -y ca-certificates curl gnupg
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo \$VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list
        apt-get update -y
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        # NVIDIA Container Toolkit
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' > /etc/apt/sources.list.d/nvidia-container-toolkit.list
        apt-get update -y
        apt-get install -y nvidia-container-toolkit
        nvidia-ctk runtime configure --runtime=docker
        systemctl restart docker
    "
    if ! pct_exec_with_retry "$container_id" "bash -c '$docker_setup_cmd'"; then
        log_error "setup_container_environment: Failed to install Docker and NVIDIA Container Toolkit in container $container_id"
        return 1
    fi

    log_info "setup_container_environment: Container environment setup completed for $container_id"
    return 0
}

# - Setup NVIDIA Drivers in Container -
setup_nvidia_drivers_in_container() {
    local container_id="$1"
    local nvidia_driver_version
    local nvidia_runfile_url

    log_info "setup_nvidia_drivers_in_container: Setting up NVIDIA drivers in container $container_id..."

    # Get NVIDIA driver version and runfile URL from JSON config
    nvidia_driver_version=$(jq -r '.nvidia_driver_version // empty' "$PHOENIX_LXC_CONFIG_FILE")
    nvidia_runfile_url=$(jq -r '.nvidia_repo_url // empty' "$PHOENIX_LXC_CONFIG_FILE")
    if [[ -z "$nvidia_driver_version" ]] || [[ -z "$nvidia_runfile_url" ]]; then
        log_error "setup_nvidia_drivers_in_container: NVIDIA driver version or runfile URL not specified in $PHOENIX_LXC_CONFIG_FILE"
        return 1
    fi

    # Append the driver file name to the runfile URL
    nvidia_runfile_url="${nvidia_runfile_url}NVIDIA-Linux-x86_64-${nvidia_driver_version}.run"

    # Check if GPUs are assigned
    local gpu_assignment
    gpu_assignment=$(get_container_config_value "$container_id" "gpu_assignment") || gpu_assignment="none"
    if [[ "$gpu_assignment" == "none" ]]; then
        log_info "setup_nvidia_drivers_in_container: No GPU assignment for container $container_id, skipping NVIDIA driver setup."
        return 0
    fi

    # Install/check NVIDIA drivers
    if ! install_nvidia_driver_in_container "$container_id" "$nvidia_driver_version" "$nvidia_runfile_url"; then
        log_error "setup_nvidia_drivers_in_container: Failed to install/check NVIDIA drivers in container $container_id"
        return 1
    fi

    # Verify GPU access
    if ! verify_lxc_gpu_access_in_container "$container_id" "$gpu_assignment"; then
        log_error "setup_nvidia_drivers_in_container: Failed to verify GPU access in container $container_id"
        return 1
    fi

    log_info "setup_nvidia_drivers_in_container: NVIDIA drivers setup completed for container $container_id"
    return 0
}

# - Setup Model -
setup_model() {
    local container_id="$1"
    local vllm_model
    vllm_model=$(get_container_config_value "$container_id" "vllm_model") || {
        log_error "setup_model: Failed to retrieve vllm_model for container $container_id"
        return 1
    }

    log_info "setup_model: Setting up model $vllm_model in container $container_id..."

    # Check if Hugging Face token is available
    local hf_token=""
    if [[ -f "$PHOENIX_HF_TOKEN_FILE" ]]; then
        hf_token=$(cat "$PHOENIX_HF_TOKEN_FILE" | tr -d ' \t\n\r')
        if [[ -z "$hf_token" ]]; then
            log_error "setup_model: Hugging Face token file is empty: $PHOENIX_HF_TOKEN_FILE"
            return 1
        fi
    else
        log_warn "setup_model: Hugging Face token file not found: $PHOENIX_HF_TOKEN_FILE. Attempting model download without authentication."
    fi

    # Download the model using huggingface_hub
    local model_cmd="
        set -e
        mkdir -p /models
        export HF_TOKEN='$hf_token'
        /usr/bin/python3 -m huggingface_hub download --repo-type model --local-dir /models/$vllm_model $vllm_model
    "
    if ! pct_exec_with_retry "$container_id" "bash -c '$model_cmd'"; then
        log_error "setup_model: Failed to download model $vllm_model in container $container_id"
        return 1
    fi

    log_info "setup_model: Model $vllm_model downloaded successfully in container $container_id"
    return 0
}

# - Setup vLLM Service -
setup_service() {
    local container_id="$1"
    local vllm_model=$(get_container_config_value "$container_id" "vllm_model")
    local vllm_tensor_parallel_size=$(get_container_config_value "$container_id" "vllm_tensor_parallel_size")
    local vllm_max_model_len=$(get_container_config_value "$container_id" "vllm_max_model_len")
    local vllm_kv_cache_dtype=$(get_container_config_value "$container_id" "vllm_kv_cache_dtype")
    local vllm_shm_size=$(get_container_config_value "$container_id" "vllm_shm_size")
    local vllm_gpu_count=$(get_container_config_value "$container_id" "vllm_gpu_count")
    local vllm_quantization=$(get_container_config_value "$container_id" "vllm_quantization")
    local vllm_quantization_config_type=$(get_container_config_value "$container_id" "vllm_quantization_config_type")
    local vllm_api_port=$(get_container_config_value "$container_id" "vllm_api_port")

    log_info "setup_service: Setting up Docker-based vLLM service in container $container_id..."

    local service_cmd="
        set -e
        cat <<EOF > /etc/systemd/system/vllm-docker.service
[Unit]
Description=vLLM Docker Container
After=docker.service
Requires=docker.service

[Service]
ExecStart=/usr/bin/docker run --rm --name vllm \\
    --gpus all \\
    -p $vllm_api_port:8000 \\
    -v /models:/models \\
    --shm-size=$vllm_shm_size \\
    vllm/vllm-openai:latest \\
    --model /models/$vllm_model \\
    --tensor-parallel-size $vllm_tensor_parallel_size \\
    --max-model-len $vllm_max_model_len \\
    --kv-cache-dtype $vllm_kv_cache_dtype \\
    --gpu-memory-utilization 0.9 \\
    --quantization $vllm_quantization

ExecStop=/usr/bin/docker stop vllm
Restart=always

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable vllm-docker.service
    "
    if ! pct_exec_with_retry "$container_id" "bash -c '$service_cmd'"; then
        log_error "setup_service: Failed to set up vLLM Docker service in container $container_id"
        return 1
    fi

    log_info "setup_service: vLLM Docker service configured successfully in container $container_id"
    return 0
}

# - Validate Final Setup -
validate_final_setup() {
    local container_id="$1"
    local checks_passed=0
    local checks_failed=0

    log_info "validate_final_setup: Validating final setup for container $container_id..."

    # Check if container is running
    local status
    status=$(pct status "$container_id" 2>/dev/null | grep 'status' | awk '{print $2}')
    if [[ "$status" == "running" ]]; then
        log_info "validate_final_setup: Container $container_id is running"
        ((checks_passed++))
    else
        log_error "validate_final_setup: Container $container_id is not running (status: $status)"
        ((checks_failed++))
    fi

    # Check GPU access
    local gpu_assignment
    gpu_assignment=$(get_container_config_value "$container_id" "gpu_assignment") || gpu_assignment="none"
    if [[ "$gpu_assignment" != "none" ]]; then
        if verify_lxc_gpu_access_in_container "$container_id" "$gpu_assignment"; then
            log_info "validate_final_setup: GPU access verified for container $container_id"
            ((checks_passed++))
        else
            log_error "validate_final_setup: GPU access verification failed for container $container_id"
            ((checks_failed++))
        fi
    else
        log_info "validate_final_setup: No GPU assignment for container $container_id, skipping GPU check"
        ((checks_passed++))
    fi

    # Check if model directory exists
    local vllm_model
    vllm_model=$(get_container_config_value "$container_id" "vllm_model") || vllm_model=""
    if [[ -n "$vllm_model" ]]; then
        local model_check_cmd="
            if [[ -d \"/models/$vllm_model\" ]]; then
                echo '[SUCCESS] Model directory exists: /models/$vllm_model'
                exit 0
            else
                echo '[ERROR] Model directory does not exist: /models/$vllm_model'
                exit 1
            fi
        "
        if pct_exec_with_retry "$container_id" "bash -c '$model_check_cmd'"; then
            log_info "validate_final_setup: Model directory exists for $vllm_model in container $container_id"
            ((checks_passed++))
        else
            log_error "validate_final_setup: Model directory check failed for $vllm_model in container $container_id"
            ((checks_failed++))
        fi
    else
        log_error "validate_final_setup: vLLM model not specified for container $container_id"
        ((checks_failed++))
    fi

    # Check if vLLM service is configured
    local service_check_cmd="
        if systemctl list-unit-files | grep -q 'vllm-docker.service'; then
            echo '[SUCCESS] vLLM Docker service is configured'
            exit 0
        else
            echo '[ERROR] vLLM Docker service is not configured'
            exit 1
        fi
    "
    if pct_exec_with_retry "$container_id" "bash -c '$service_check_cmd'"; then
        log_info "validate_final_setup: vLLM Docker service is configured in container $container_id"
        ((checks_passed++))
    else
        log_error "validate_final_setup: vLLM Docker service configuration check failed in container $container_id"
        ((checks_failed++))
    fi

    log_info "validate_final_setup: Validation summary: $checks_passed passed, $checks_failed failed"
    if [[ $checks_failed -gt 0 ]]; then
        log_warn "validate_final_setup: Validation completed with $checks_failed failures. Check logs for details."
        return 1
    fi
    log_info "validate_final_setup: All validation checks passed for container $container_id"
    return 0
}

# --- Main Execution ---
main() {
    local container_id="$1"

    if [[ -z "$container_id" ]]; then
        # Use log function if available, else echo
        if declare -f log_error > /dev/null 2>&1; then
            log_error "phoenix_hypervisor_setup_drdevstral.sh: Container ID must be provided as an argument"
        else
            echo "[ERROR] phoenix_hypervisor_setup_drdevstral.sh: Container ID must be provided as an argument" >&2
        fi
        echo "Usage: $0 <container_id>"
        exit 1
    fi

    # Validate container configuration
    validate_container "$container_id"

    # Show setup information and get confirmation
    show_setup_info "$container_id"

    # Setup container environment
    if ! setup_container_environment "$container_id"; then
        # Use log function if available, else echo
        if declare -f log_error > /dev/null 2>&1; then
            log_error "phoenix_hypervisor_setup_drdevstral.sh: Container environment setup failed for $container_id"
        else
             echo "[ERROR] phoenix_hypervisor_setup_drdevstral.sh: Container environment setup failed for $container_id" >&2
        fi
        exit 1
    fi

    # Setup NVIDIA drivers (continue even if this fails, as CPU mode might be acceptable)
    if ! setup_nvidia_drivers_in_container "$container_id"; then
        # Use log function if available, else echo
        if declare -f log_warn > /dev/null 2>&1; then
            log_warn "phoenix_hypervisor_setup_drdevstral.sh: NVIDIA driver setup had issues or was skipped for $container_id, continuing with CPU setup"
        else
             echo "[WARN] phoenix_hypervisor_setup_drdevstral.sh: NVIDIA driver setup had issues or was skipped for $container_id, continuing with CPU setup" >&2
        fi
    fi

    # Setup Model
    if ! setup_model "$container_id"; then
        # Use log function if available, else echo
        if declare -f log_error > /dev/null 2>&1; then
            log_error "phoenix_hypervisor_setup_drdevstral.sh: Model setup failed for $container_id"
        else
             echo "[ERROR] phoenix_hypervisor_setup_drdevstral.sh: Model setup failed for $container_id" >&2
        fi
        exit 1
    fi

    # Setup Service
    if ! setup_service "$container_id"; then
        # Use log function if available, else echo
        if declare -f log_error > /dev/null 2>&1; then
            log_error "phoenix_hypervisor_setup_drdevstral.sh: Service setup failed for $container_id"
        else
             echo "[ERROR] phoenix_hypervisor_setup_drdevstral.sh: Service setup failed for $container_id" >&2
        fi
        exit 1
    fi

    # Validate Final Setup
    if ! validate_final_setup "$container_id"; then
        # Use log function if available, else echo
        if declare -f log_warn > /dev/null 2>&1; then
            log_warn "phoenix_hypervisor_setup_drdevstral.sh: Final setup validation had warnings for $container_id"
        else
             echo "[WARN] phoenix_hypervisor_setup_drdevstral.sh: Final setup validation had warnings for $container_id" >&2
        fi
    fi

    echo ""
    echo "==============================================="
    echo "DRDEVSTRAL SETUP COMPLETED"
    echo "==============================================="
    # Use log function if available, else echo
    if declare -f log_info > /dev/null 2>&1; then
        log_info "phoenix_hypervisor_setup_drdevstral.sh: drdevstral setup completed successfully for container $container_id"
        log_info "phoenix_hypervisor_setup_drdevstral.sh: You can now start the service with: pct exec $container_id -- systemctl start vllm-docker.service"
        log_info "phoenix_hypervisor_setup_drdevstral.sh: Check status with: pct exec $container_id -- systemctl status vllm-docker.service"
    else
        echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: drdevstral setup completed successfully for container $container_id"
        echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: You can now start the service with: pct exec $container_id -- systemctl start vllm-docker.service"
        echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: Check status with: pct exec $container_id -- systemctl status vllm-docker.service"
    fi
    echo "==============================================="
}

# Call main function with the passed argument
main "$1"
```