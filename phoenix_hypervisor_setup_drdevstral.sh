#!/bin/bash
# Container-specific setup script for drdevstral (LXC ID 901)
# Installs NVIDIA drivers, vLLM, and sets up the AI model
# Version: 1.7.4
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
validate_container() {
    local container_id="$1"

    if [[ -z "$container_id" ]]; then
        # Use log function if available, else echo
        if declare -f log_error > /dev/null 2>&1; then
            log_error "phoenix_hypervisor_setup_drdevstral.sh: Container ID cannot be empty"
        else
            echo "[ERROR] phoenix_hypervisor_setup_drdevstral.sh: Container ID cannot be empty" >&2
        fi
        exit 1
    fi

    # Use the common validation function
    if ! validate_container_config "$container_id"; then
        # The function should log the error
        exit 1
    fi

    # Use log function if available, else echo
    if declare -f log_info > /dev/null 2>&1; then
        log_info "phoenix_hypervisor_setup_drdevstral.sh: Container $container_id configuration validated successfully"
    else
        echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: Container $container_id configuration validated successfully"
    fi
}

# - Display Setup Information -
show_setup_info() {
    local container_id="$1"

    echo ""
    echo "==============================================="
    echo "DRDEVSTRA LXC CONTAINER SETUP"
    echo "==============================================="
    echo ""
    # Use log function if available, else echo
    if declare -f log_info > /dev/null 2>&1; then
        log_info "phoenix_hypervisor_setup_drdevstral.sh: Preparing to set up container $container_id (drdevstral)..."
    else
         echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: Preparing to set up container $container_id (drdevstral)..."
    fi
    echo ""
    # Use log function if available, else echo
    if declare -f log_info > /dev/null 2>&1; then
        log_info "phoenix_hypervisor_setup_drdevstral.sh: Setup Configuration:"
        log_info "phoenix_hypervisor_setup_drdevstral.sh: -"
        log_info "phoenix_hypervisor_setup_drdevstral.sh: Container ID: $container_id"
    else
        echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: Setup Configuration:"
        echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: -"
        echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: Container ID: $container_id"
    fi


    # Get GPU assignment using the common function
    local gpu_assignment
    gpu_assignment=$(get_gpu_assignment "$container_id")
    # Use log function if available, else echo
    if declare -f log_info > /dev/null 2>&1; then
        log_info "phoenix_hypervisor_setup_drdevstral.sh: GPU Assignment: $gpu_assignment"
    else
        echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: GPU Assignment: $gpu_assignment"
    fi

    # Get model using jq
    local vllm_model
    vllm_model=$(jq -r ".lxc_configs.\"$container_id\".vllm_model // \"default_model\"" "$PHOENIX_LXC_CONFIG_FILE" 2>/dev/null || echo "default_model")
    # Use log function if available, else echo
    if declare -f log_info > /dev/null 2>&1; then
        log_info "phoenix_hypervisor_setup_drdevstral.sh: Model: $vllm_model"
    else
        echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: Model: $vllm_model"
    fi
    echo ""
    read -p "phoenix_hypervisor_setup_drdevstral.sh: Do you want to proceed with setup? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        # Use log function if available, else echo
        if declare -f log_info > /dev/null 2>&1; then
            log_info "phoenix_hypervisor_setup_drdevstral.sh: Setup cancelled by user."
        else
             echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: Setup cancelled by user."
        fi
        exit 0
    fi
}

# - Setup Container Environment -
setup_container_environment() {
    local container_id="$1"

    # Use log function if available, else echo
    if declare -f log_info > /dev/null 2>&1; then
        log_info "phoenix_hypervisor_setup_drdevstral.sh: Setting up container environment for $container_id..."
    else
        echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: Setting up container environment for $container_id..."
    fi

    # Commands to run inside the container
    local setup_env_cmd="
        set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y python3 python3-pip curl wget git htop nano vim systemd systemd-sysv
        # Create vllm user
        id -u vllm &>/dev/null || useradd -m -s /bin/bash vllm
        usermod -aG sudo vllm
        echo 'vllm ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
        # Create necessary directories
        mkdir -p /home/vllm/models /home/vllm/.cache/huggingface
        chown -R vllm:vllm /home/vllm
        # Set up shared memory for vLLM
        echo 'tmpfs /dev/shm tmpfs defaults,size=10G 0 0' >> /etc/fstab
        mount -a || true # Ignore if already mounted
    "

    if ! pct exec "$container_id" -- bash -c "$setup_env_cmd"; then
        # Use log function if available, else echo
        if declare -f log_error > /dev/null 2>&1; then
            log_error "phoenix_hypervisor_setup_drdevstral.sh: Failed to set up container environment for $container_id"
        else
            echo "[ERROR] phoenix_hypervisor_setup_drdevstral.sh: Failed to set up container environment for $container_id" >&2
        fi
        return 1
    fi

    # Use log function if available, else echo
    if declare -f log_info > /dev/null 2>&1; then
        log_info "phoenix_hypervisor_setup_drdevstral.sh: Container environment setup completed for $container_id"
    else
        echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: Container environment setup completed for $container_id"
    fi
    return 0
}

# - Setup NVIDIA Drivers in Container -
setup_nvidia_drivers_in_container() {
    local container_id="$1"

    # Use log function if available, else echo
    if declare -f log_info > /dev/null 2>&1; then
        log_info "phoenix_hypervisor_setup_drdevstral.sh: Installing NVIDIA drivers in container $container_id..."
    else
        echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: Installing NVIDIA drivers in container $container_id..."
    fi

    # Get NVIDIA driver version and runfile URL from config
    local nvidia_driver_version nvidia_runfile_url
    nvidia_driver_version=$(jq -r '.nvidia_driver_version // "580.65.06"' "$PHOENIX_LXC_CONFIG_FILE" 2>/dev/null || echo "580.65.06")
    nvidia_runfile_url=$(jq -r '.nvidia_runfile_url // "http://us.download.nvidia.com/XFree86/Linux-x86_64/580.65.06/NVIDIA-Linux-x86_64-580.65.06.run"' "$PHOENIX_LXC_CONFIG_FILE" 2>/dev/null || echo "http://us.download.nvidia.com/XFree86/Linux-x86_64/580.65.06/NVIDIA-Linux-x86_64-580.65.06.run")

    # --- DELEGATE TO FUNCTION FROM phoenix_hypervisor_lxc_common_nvidia.sh ---
    # This is the key integration point with the specialized NVIDIA library.
    if declare -f install_nvidia_driver_in_container > /dev/null; then
        if install_nvidia_driver_in_container "$container_id" "$nvidia_driver_version" "$nvidia_runfile_url"; then
            # Function should log success
            return 0
        else
            # Function should log error
            return 1
        fi
    else
         # Use log function if available, else echo
         if declare -f log_error > /dev/null 2>&1; then
             log_error "phoenix_hypervisor_setup_drdevstral.sh: Required function 'install_nvidia_driver_in_container' not found. Ensure phoenix_hypervisor_lxc_common_nvidia.sh is sourced correctly."
         else
             echo "[ERROR] phoenix_hypervisor_setup_drdevstral.sh: Required function 'install_nvidia_driver_in_container' not found. Ensure phoenix_hypervisor_lxc_common_nvidia.sh is sourced correctly." >&2
         fi
        return 1
    fi
}

# - Setup vLLM -
setup_vllm() {
    local container_id="$1"

    # Use log function if available, else echo
    if declare -f log_info > /dev/null 2>&1; then
        log_info "phoenix_hypervisor_setup_drdevstral.sh: Installing vLLM in container $container_id..."
    else
        echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: Installing vLLM in container $container_id..."
    fi

    # Commands to run inside the container
    local install_vllm_cmd="
        set -e
        export DEBIAN_FRONTEND=noninteractive
        # Update pip
        pip3 install --upgrade pip
        # Install vLLM
        pip3 install vllm
        # Verify installation
        python3 -c 'import vllm; print(vllm.__version__)'
    "

    if ! pct exec "$container_id" -- bash -c "$install_vllm_cmd"; then
        # Use log function if available, else echo
        if declare -f log_error > /dev/null 2>&1; then
            log_error "phoenix_hypervisor_setup_drdevstral.sh: Failed to install vLLM in container $container_id"
        else
             echo "[ERROR] phoenix_hypervisor_setup_drdevstral.sh: Failed to install vLLM in container $container_id" >&2
        fi
        return 1
    fi

    # Use log function if available, else echo
    if declare -f log_info > /dev/null 2>&1; then
        log_info "phoenix_hypervisor_setup_drdevstral.sh: vLLM installed successfully in container $container_id"
    else
         echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: vLLM installed successfully in container $container_id"
    fi
    return 0
}

# - Setup Model -
setup_model() {
    local container_id="$1"

    # Use log function if available, else echo
    if declare -f log_info > /dev/null 2>&1; then
        log_info "phoenix_hypervisor_setup_drdevstral.sh: Setting up AI model in container $container_id..."
    else
         echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: Setting up AI model in container $container_id..."
    fi

    # Get model name from config
    local vllm_model
    vllm_model=$(jq -r ".lxc_configs.\"$container_id\".vllm_model // \"default_model\"" "$PHOENIX_LXC_CONFIG_FILE" 2>/dev/null || echo "default_model")

    # Commands to run inside the container
    local setup_model_cmd="
        set -e
        # Switch to vllm user
        sudo -u vllm bash << 'EOF_SUDO'
        cd /home/vllm
        export HF_HOME=/home/vllm/.cache/huggingface
        # Create models directory
        mkdir -p models
        # Download model using huggingface-cli (part of transformers/huggingface-hub)
        # This will use the token from ~/.cache/huggingface/token if set
        echo '[INFO] Downloading model: $vllm_model'
        python3 -c \"
import os
os.environ['HF_HOME'] = '/home/vllm/.cache/huggingface'
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id='$vllm_model',
    local_dir='models/$(basename $vllm_model)',
    local_dir_use_symlinks=False,
    max_workers=1
)
print('Model downloaded to: models/$(basename $vllm_model)')
\"
EOF_SUDO
    "

    if ! pct exec "$container_id" -- bash -c "$setup_model_cmd"; then
        # Use log function if available, else echo
        if declare -f log_error > /dev/null 2>&1; then
            log_error "phoenix_hypervisor_setup_drdevstral.sh: Failed to download/set up model '$vllm_model' in container $container_id"
        else
            echo "[ERROR] phoenix_hypervisor_setup_drdevstral.sh: Failed to download/set up model '$vllm_model' in container $container_id" >&2
        fi
        return 1
    fi

    # Use log function if available, else echo
    if declare -f log_info > /dev/null 2>&1; then
        log_info "phoenix_hypervisor_setup_drdevstral.sh: Model '$vllm_model' set up successfully in container $container_id"
    else
         echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: Model '$vllm_model' set up successfully in container $container_id"
    fi
    return 0
}

# - Setup Service -
setup_service() {
    local container_id="$1"

    # Use log function if available, else echo
    if declare -f log_info > /dev/null 2>&1; then
        log_info "phoenix_hypervisor_setup_drdevstral.sh: Setting up systemd service in container $container_id..."
    else
         echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: Setting up systemd service in container $container_id..."
    fi

    # Get service configuration from the main config file
    local vllm_model vllm_tensor_parallel_size vllm_max_model_len vllm_kv_cache_dtype vllm_shm_size vllm_gpu_count vllm_quantization vllm_quantization_config_type

    vllm_model=$(jq -r ".lxc_configs.\"$container_id\".vllm_model // \"default_model\"" "$PHOENIX_LXC_CONFIG_FILE")
    vllm_tensor_parallel_size=$(jq -r ".lxc_configs.\"$container_id\".vllm_tensor_parallel_size // \"1\"" "$PHOENIX_LXC_CONFIG_FILE")
    vllm_max_model_len=$(jq -r ".lxc_configs.\"$container_id\".vllm_max_model_len // \"16384\"" "$PHOENIX_LXC_CONFIG_FILE")
    vllm_kv_cache_dtype=$(jq -r ".lxc_configs.\"$container_id\".vllm_kv_cache_dtype // \"fp8\"" "$PHOENIX_LXC_CONFIG_FILE")
    vllm_shm_size=$(jq -r ".lxc_configs.\"$container_id\".vllm_shm_size // \"10.24gb\"" "$PHOENIX_LXC_CONFIG_FILE")
    vllm_gpu_count=$(jq -r ".lxc_configs.\"$container_id\".vllm_gpu_count // \"1\"" "$PHOENIX_LXC_CONFIG_FILE")
    vllm_quantization=$(jq -r ".lxc_configs.\"$container_id\".vllm_quantization // \"\"" "$PHOENIX_LXC_CONFIG_FILE")
    vllm_quantization_config_type=$(jq -r ".lxc_configs.\"$container_id\".vllm_quantization_config_type // \"\"" "$PHOENIX_LXC_CONFIG_FILE")

    # Create the systemd service file inside the container
    local create_service_cmd="
        set -e
        cat > /etc/systemd/system/vllm.service << 'EOF_SERVICE'
[Unit]
Description=vLLM API Server
After=network.target

[Service]
Type=simple
User=vllm
WorkingDirectory=/home/vllm
Environment=HF_HOME=/home/vllm/.cache/huggingface
ExecStart=/usr/bin/python3 -m vllm.entrypoints.api_server \\
  --host 0.0.0.0 \\
  --port 8000 \\
  --model /home/vllm/models/$(basename $vllm_model) \\
  --tensor-parallel-size $vllm_tensor_parallel_size \\
  --max-model-len $vllm_max_model_len \\
  --kv-cache-dtype $vllm_kv_cache_dtype \\
  --shm-size $vllm_shm_size \\
  --gpu-memory-utilization 0.9 \\
  --quantization $vllm_quantization \\
  --quantization-config-type $vllm_quantization_config_type

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_SERVICE

        # Reload systemd and enable the service
        systemctl daemon-reload
        systemctl enable vllm.service
        echo '[INFO] vLLM systemd service created and enabled.'
    "

    if ! pct exec "$container_id" -- bash -c "$create_service_cmd"; then
        # Use log function if available, else echo
        if declare -f log_error > /dev/null 2>&1; then
            log_error "phoenix_hypervisor_setup_drdevstral.sh: Failed to create vLLM systemd service in container $container_id"
        else
             echo "[ERROR] phoenix_hypervisor_setup_drdevstral.sh: Failed to create vLLM systemd service in container $container_id" >&2
        fi
        return 1
    fi

    # Use log function if available, else echo
    if declare -f log_info > /dev/null 2>&1; then
        log_info "phoenix_hypervisor_setup_drdevstral.sh: vLLM systemd service set up successfully in container $container_id"
    else
         echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: vLLM systemd service set up successfully in container $container_id"
    fi
    return 0
}

# - Validate Final Setup -
validate_final_setup() {
    local container_id="$1"

    # Use log function if available, else echo
    if declare -f log_info > /dev/null 2>&1; then
        log_info "phoenix_hypervisor_setup_drdevstral.sh: Validating final setup in container $container_id..."
    else
         echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: Validating final setup in container $container_id..."
    fi

    # Get GPU assignment using the common function
    local gpu_assignment
    gpu_assignment=$(get_gpu_assignment "$container_id")
    # Use log function if available, else echo
    if declare -f log_info > /dev/null 2>&1; then
        log_info "phoenix_hypervisor_setup_drdevstral.sh: GPU assignment for container $container_id: $gpu_assignment"
    else
         echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: GPU assignment for container $container_id: $gpu_assignment"
    fi

    # --- DELEGATE TO FUNCTION FROM phoenix_hypervisor_lxc_common_nvidia.sh ---
    # Use detect_gpus_in_container to verify access
    if declare -f detect_gpus_in_container > /dev/null; then
        if detect_gpus_in_container "$container_id"; then
            # Function logs success
            : # Do nothing, success is logged
        else
            # Function logs warning/error
            : # Do nothing, error is logged
        fi
    else
        # Fallback check if function not available
        # Use log function if available, else echo
        if declare -f log_warn > /dev/null 2>&1; then
            log_warn "phoenix_hypervisor_setup_drdevstral.sh: Function 'detect_gpus_in_container' not found, using fallback check."
        else
            echo "[WARN] phoenix_hypervisor_setup_drdevstral.sh: Function 'detect_gpus_in_container' not found, using fallback check." >&2
        fi

        # Check NVIDIA drivers inside the container
        local nvidia_check_cmd="nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null || echo 'not_found'"
        local driver_version
        driver_version=$(pct exec "$container_id" -- bash -c "$nvidia_check_cmd")

        if [[ "$driver_version" == "not_found" ]]; then
            # Use log function if available, else echo
            if declare -f log_warn > /dev/null 2>&1; then
                log_warn "phoenix_hypervisor_setup_drdevstral.sh: NVIDIA drivers not found in container $container_id. GPU acceleration will be limited."
            else
                 echo "[WARN] phoenix_hypervisor_setup_drdevstral.sh: NVIDIA drivers not found in container $container_id. GPU acceleration will be limited." >&2
            fi
        else
            # Use log function if available, else echo
            if declare -f log_info > /dev/null 2>&1; then
                log_info "phoenix_hypervisor_setup_drdevstral.sh: NVIDIA driver version found: $driver_version"
            else
                echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: NVIDIA driver version found: $driver_version"
            fi
        fi
    fi

    # Check if vLLM service is enabled
    local service_check_cmd="systemctl is-enabled vllm.service 2>/dev/null || echo 'not_enabled'"
    local service_status
    service_status=$(pct exec "$container_id" -- bash -c "$service_check_cmd")

    if [[ "$service_status" == "enabled" ]]; then
        # Use log function if available, else echo
        if declare -f log_info > /dev/null 2>&1; then
            log_info "phoenix_hypervisor_setup_drdevstral.sh: vLLM systemd service is enabled in container $container_id"
        else
             echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: vLLM systemd service is enabled in container $container_id"
        fi
    else
        # Use log function if available, else echo
        if declare -f log_warn > /dev/null 2>&1; then
            log_warn "phoenix_hypervisor_setup_drdevstral.sh: vLLM systemd service is not enabled in container $container_id"
        else
             echo "[WARN] phoenix_hypervisor_setup_drdevstral.sh: vLLM systemd service is not enabled in container $container_id" >&2
        fi
    fi

    # Check model directory
    local model_check_cmd="[ -d \"/home/vllm/models/$(basename "$(jq -r ".lxc_configs.\"$container_id\".vllm_model" "$PHOENIX_LXC_CONFIG_FILE")")\" ] && echo 'found' || echo 'not_found'"
    local model_status
    model_status=$(pct exec "$container_id" -- bash -c "$model_check_cmd")

    if [[ "$model_status" == "found" ]]; then
        # Use log function if available, else echo
        if declare -f log_info > /dev/null 2>&1; then
            log_info "phoenix_hypervisor_setup_drdevstral.sh: Model directory found in container $container_id"
        else
             echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: Model directory found in container $container_id"
        fi
    else
        # Use log function if available, else echo
        if declare -f log_warn > /dev/null 2>&1; then
            log_warn "phoenix_hypervisor_setup_drdevstral.sh: Model directory not found in container $container_id"
        else
             echo "[WARN] phoenix_hypervisor_setup_drdevstral.sh: Model directory not found in container $container_id" >&2
        fi
    fi

    # Use log function if available, else echo
    if declare -f log_info > /dev/null 2>&1; then
        log_info "phoenix_hypervisor_setup_drdevstral.sh: Final setup validation completed for container $container_id"
    else
         echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: Final setup validation completed for container $container_id"
    fi
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

    # Setup vLLM
    if ! setup_vllm "$container_id"; then
        # Use log function if available, else echo
        if declare -f log_error > /dev/null 2>&1; then
            log_error "phoenix_hypervisor_setup_drdevstral.sh: vLLM installation failed for $container_id"
        else
             echo "[ERROR] phoenix_hypervisor_setup_drdevstral.sh: vLLM installation failed for $container_id" >&2
        fi
        exit 1
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
    echo "DRDEVSTRA SETUP COMPLETED"
    echo "==============================================="
    # Use log function if available, else echo
    if declare -f log_info > /dev/null 2>&1; then
        log_info "phoenix_hypervisor_setup_drdevstral.sh: drdevstral setup completed successfully for container $container_id"
        log_info "phoenix_hypervisor_setup_drdevstral.sh: You can now start the service with: pct exec $container_id -- systemctl start vllm.service"
        log_info "phoenix_hypervisor_setup_drdevstral.sh: Check status with: pct exec $container_id -- systemctl status vllm.service"
    else
        echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: drdevstral setup completed successfully for container $container_id"
        echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: You can now start the service with: pct exec $container_id -- systemctl start vllm.service"
        echo "[INFO] phoenix_hypervisor_setup_drdevstral.sh: Check status with: pct exec $container_id -- systemctl status vllm.service"
    fi
    echo "==============================================="
}

# Call main function with the passed argument
main "$1"
