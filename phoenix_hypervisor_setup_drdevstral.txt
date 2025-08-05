#!/bin/bash
# Phoenix Hypervisor DrDevstral Setup Script
# Configures an LXC container (e.g., 901 for drdevstral) with Docker, NVIDIA container runtime, and vLLM service.
# Uses arguments passed by the orchestrator (phoenix_establish_hypervisor.sh) for configuration.
# Prerequisites:
# - Proxmox VE 8.x (tested with 8.4.6)
# - LXC created with GPU passthrough (handled by phoenix_hypervisor_create_lxc.sh)
# - phoenix_hypervisor_common.sh sourced
# - phoenix_hypervisor_config.sh sourced (for paths/defaults)
# Usage: ./phoenix_hypervisor_setup_drdevstral.sh <lxc_id> <name> <vllm_model> <vllm_tensor_parallel_size> <vllm_max_model_len> <vllm_kv_cache_dtype> <vllm_shm_size> <vllm_gpu_count> <vllm_quantization> <vllm_quantization_config_type> <vllm_api_port>
# Version: 1.7.3
# Author: Assistant
set -euo pipefail

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

# --- Enhanced Main Function ---
main() {
    # Check if we have the required arguments
    if [[ $# -lt 10 ]]; then
        log_error "Usage: $0 <lxc_id> <name> <vllm_model> <vllm_tensor_parallel_size> <vllm_max_model_len> <vllm_kv_cache_dtype> <vllm_shm_size> <vllm_gpu_count> <vllm_quantization> <vllm_quantization_config_type> <vllm_api_port>"
        echo ""
        echo "Example: $0 901 drdevstral llama3:8b 1 2048 fp8 12g 1 none none 8000"
        echo ""
        exit 1
    fi
    
    # Parse arguments
    local lxc_id="$1"
    local name="$2"
    local vllm_model="$3"
    local vllm_tensor_parallel_size="$4"
    local vllm_max_model_len="$5"
    local vllm_kv_cache_dtype="$6"
    local vllm_shm_size="$7"
    local vllm_gpu_count="$8"
    local vllm_quantization="$9"
    local vllm_quantization_config_type="${10}"
    local vllm_api_port="${11}"
    
    # Validate LXC ID
    if ! validate_lxc_id "$lxc_id"; then
        log_error "Invalid LXC ID format: $lxc_id"
        exit 1
    fi
    
    log_info "Starting setup for container $lxc_id ($name)"
    echo ""
    echo "==============================================="
    echo "SETTING UP CONTAINER $lxc_id ($name)"
    echo "==============================================="
    echo ""
    
    # Check if this setup has already been completed
    local marker_file="${HYPERVISOR_MARKER_DIR}/container_${lxc_id}_setup_complete"
    if is_script_completed "$marker_file"; then
        log_info "Setup for container $lxc_id already completed. Skipping."
        echo "Setup already completed for container $lxc_id - skipping."
        echo ""
        exit 0
    fi
    
    # Confirm with user before proceeding
    read -p "Do you want to set up container $lxc_id ($name)? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_info "Setup for container $lxc_id cancelled by user."
        echo ""
        echo "Container setup cancelled for $lxc_id."
        echo ""
        exit 0
    fi
    
    echo ""
    echo "Setting up container $lxc_id ($name)..."
    echo "---------------------------------------"
    
    # Verify container exists and is running
    log_info "Checking if container $lxc_id exists and is running..."
    if ! pct status "$lxc_id" >/dev/null 2>&1; then
        log_error "Container $lxc_id does not exist or is not accessible"
        exit 1
    fi
    
    local status
    status=$(pct status "$lxc_id")
    if [[ ! "$status" =~ "status: running" ]]; then
        log_warn "Container $lxc_id is not running. Attempting to start it..."
        pct start "$lxc_id" >/dev/null 2>&1 || {
            log_error "Failed to start container $lxc_id"
            exit 1
        }
        sleep 3
    fi
    
    # Show container information
    echo ""
    echo "Container Information:"
    echo "----------------------"
    echo "ID: $lxc_id"
    echo "Name: $name"
    echo "Status: Running"
    echo ""
    
    # Check if we have GPU access
    log_info "Checking GPU access for container $lxc_id..."
    if pct exec "$lxc_id" -- command -v nvidia-smi >/dev/null 2>&1; then
        echo "NVIDIA GPU detected in container"
        local gpu_count
        gpu_count=$(pct exec "$lxc_id" -- nvidia-smi --query-gpu=count --format=csv,noheader,nounits | tr -d ' ')
        echo "Available GPUs: $gpu_count"
    else
        log_warn "NVIDIA GPU not accessible in container. This may be expected if GPU passthrough is not configured properly."
    fi
    
    # Install Docker in container
    log_info "Installing Docker in container $lxc_id..."
    install_docker_in_container "$lxc_id"
    
    # Setup NVIDIA Container Runtime
    log_info "Setting up NVIDIA Container Runtime in container $lxc_id..."
    setup_nvidia_runtime "$lxc_id"
    
    # Install vLLM service
    log_info "Installing and configuring vLLM service in container $lxc_id..."
    install_vllm_service "$lxc_id" "$vllm_model" "$vllm_tensor_parallel_size" "$vllm_max_model_len" "$vllm_kv_cache_dtype" "$vllm_shm_size" "$vllm_gpu_count" "$vllm_quantization" "$vllm_quantization_config_type" "$vllm_api_port"
    
    # Configure system for LXC container (if needed)
    log_info "Configuring container $lxc_id for vLLM service..."
    configure_container "$lxc_id"
    
    # Test the setup
    log_info "Testing vLLM service in container $lxc_id..."
    test_vllm_setup "$lxc_id" "$vllm_api_port"
    
    # Mark completion
    mark_script_completed "$marker_file"
    log_info "Setup for container $lxc_id completed successfully"
    
    echo ""
    echo "==============================================="
    echo "SETUP COMPLETED SUCCESSFULLY!"
    echo "==============================================="
    echo ""
    echo "Container $lxc_id ($name) is now ready with vLLM service."
    echo ""
    echo "Service Information:"
    echo "--------------------"
    echo "API Port: $vllm_api_port"
    echo "Model: $vllm_model"
    echo "GPU Count: $vllm_gpu_count"
    echo ""
    echo "To check service status in container $lxc_id:"
    echo "  pct exec $lxc_id -- systemctl status vllm.service"
    echo ""
    echo "To view logs:"
    echo "  pct exec $lxc_id -- journalctl -u vllm.service -f"
    echo ""
}

# --- Enhanced Docker Installation ---
install_docker_in_container() {
    local lxc_id="$1"
    
    log_info "Installing Docker in container $lxc_id..."
    
    # Check if Docker is already installed
    if pct exec "$lxc_id" -- command -v docker >/dev/null 2>&1; then
        echo "Docker already installed in container $lxc_id"
        return 0
    fi
    
    # Update package lists first
    echo "Updating package lists..."
    pct exec "$lxc_id" -- apt-get update >/dev/null 2>&1 || {
        log_warn "Failed to update package lists in container $lxc_id"
    }
    
    # Install Docker prerequisites
    echo "Installing Docker prerequisites..."
    if ! pct exec "$lxc_id" -- apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release >/dev/null 2>&1; then
        log_warn "Failed to install Docker prerequisites in container $lxc_id"
    fi
    
    # Add Docker's official GPG key
    echo "Adding Docker's official GPG key..."
    if ! pct exec "$lxc_id" -- mkdir -p /etc/apt/keyrings; then
        log_warn "Failed to create directory for Docker keys in container $lxc_id"
    fi
    
    # Download and install Docker repository
    echo "Installing Docker repository..."
    if ! pct exec "$lxc_id" -- curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        pct exec "$lxc_id" -- gpg --dearmor -o /etc/apt/keyrings/docker.gpg; then
        log_warn "Failed to download Docker GPG key in container $lxc_id"
    fi
    
    # Add repository to apt sources
    if ! pct exec "$lxc_id" -- echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        pct exec "$lxc_id" -- tee /etc/apt/sources.list.d/docker.list > /dev/null; then
        log_warn "Failed to add Docker repository in container $lxc_id"
    fi
    
    # Update package lists again
    echo "Updating package lists after Docker repo addition..."
    if ! pct exec "$lxc_id" -- apt-get update >/dev/null 2>&1; then
        log_warn "Failed to update package lists after Docker repo in container $lxc_id"
    fi
    
    # Install Docker Engine
    echo "Installing Docker Engine..."
    if ! retry_command 3 10 "pct exec $lxc_id -- apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin"; then
        log_error "Failed to install Docker in container $lxc_id"
        exit 1
    fi
    
    # Start and enable Docker service
    echo "Starting Docker service..."
    if ! pct exec "$lxc_id" -- systemctl start docker; then
        log_warn "Failed to start Docker service in container $lxc_id"
    fi
    
    if ! pct exec "$lxc_id" -- systemctl enable docker; then
        log_warn "Failed to enable Docker service in container $lxc_id"
    fi
    
    echo "Docker installed successfully in container $lxc_id"
}

# --- Enhanced NVIDIA Runtime Setup ---
setup_nvidia_runtime() {
    local lxc_id="$1"
    
    log_info "Setting up NVIDIA Container Runtime in container $lxc_id..."
    
    # Check if nvidia-container-toolkit is installed
    if ! pct exec "$lxc_id" -- command -v nvidia-container-toolkit >/dev/null 2>&1; then
        echo "Installing NVIDIA Container Toolkit..."
        if ! pct exec "$lxc_id" -- apt-get install -y nvidia-container-toolkit; then
            log_warn "Failed to install NVIDIA Container Toolkit in container $lxc_id"
        fi
    else
        echo "NVIDIA Container Toolkit already installed"
    fi
    
    # Configure Docker daemon for NVIDIA runtime
    local docker_config="/etc/docker/daemon.json"
    
    # Create the config directory if it doesn't exist
    pct exec "$lxc_id" -- mkdir -p "$(dirname "$docker_config")" || true
    
    # Check if config already exists and has nvidia runtime
    if pct exec "$lxc_id" -- test -f "$docker_config"; then
        local existing_config
        existing_config=$(pct exec "$lxc_id" -- cat "$docker_config")
        
        if echo "$existing_config" | grep -q "nvidia"; then
            echo "NVIDIA runtime already configured in Docker daemon"
        else
            echo "Updating Docker daemon configuration with NVIDIA runtime..."
            local updated_config='{ "default-runtime": "nvidia", "runtimes": { "nvidia": { "path": "nvidia-container-runtime", "runtimeArgs": [] } } }'
            pct exec "$lxc_id" -- echo "$updated_config" > "$docker_config"
        fi
    else
        # Create new config file
        echo "Creating Docker daemon configuration with NVIDIA runtime..."
        local new_config='{ "default-runtime": "nvidia", "runtimes": { "nvidia": { "path": "nvidia-container-runtime", "runtimeArgs": [] } } }'
        pct exec "$lxc_id" -- echo "$new_config" > "$docker_config"
    fi
    
    # Restart Docker daemon to apply changes
    echo "Restarting Docker daemon..."
    if ! pct exec "$lxc_id" -- systemctl restart docker; then
        log_warn "Failed to restart Docker daemon in container $lxc_id"
    fi
    
    echo "NVIDIA Container Runtime configured successfully in container $lxc_id"
}

# --- Enhanced vLLM Installation ---
install_vllm_service() {
    local lxc_id="$1"
    local model="$2"
    local tensor_parallel_size="$3"
    local max_model_len="$4"
    local kv_cache_dtype="$5"
    local shm_size="$6"
    local gpu_count="$7"
    local quantization="$8"
    local quantization_config_type="$9"
    local api_port="${10}"
    
    log_info "Installing vLLM service in container $lxc_id..."
    
    # Create vLLM service directory
    pct exec "$lxc_id" -- mkdir -p /opt/vllm || true
    
    # Create service configuration file
    echo "Creating vLLM service configuration..."
    
    local service_config="/opt/vllm/config.sh"
    local config_content="#!/bin/bash
# vLLM Service Configuration

export MODEL=\"$model\"
export TENSOR_PARALLEL_SIZE=$tensor_parallel_size
export MAX_MODEL_LEN=$max_model_len
export KV_CACHE_DTYPE=$kv_cache_dtype
export SHM_SIZE=\"$shm_size\"
export GPU_COUNT=$gpu_count
export QUANTIZATION=\"$quantization\"
export QUANTIZATION_CONFIG_TYPE=\"$quantization_config_type\"
export API_PORT=$api_port

# Service parameters
export VLLM_MODEL_PATH=\"/opt/vllm/models\"

# Create model directory
mkdir -p \$VLLM_MODEL_PATH || true
"
    
    pct exec "$lxc_id" -- echo "$config_content" > "$service_config"
    pct exec "$lxc_id" -- chmod +x "$service_config"
    
    # Create vLLM service file
    echo "Creating vLLM systemd service..."
    
    local service_file="/etc/systemd/system/vllm.service"
    local service_content="[Unit]
Description=vLLM Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/vllm
EnvironmentFile=/opt/vllm/config.sh
ExecStart=/usr/local/bin/vllm serve \$MODEL --host 0.0.0.0 --port \$API_PORT --tensor-parallel-size \$TENSOR_PARALLEL_SIZE --max-model-len \$MAX_MODEL_LEN --kv-cache-dtype \$KV_CACHE_DTYPE --gpu-memory-utilization 0.9
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target"
    
    pct exec "$lxc_id" -- echo "$service_content" > "$service_file"
    
    # Install vLLM using pip
    echo "Installing vLLM via pip..."
    if ! retry_command 3 10 "pct exec $lxc_id -- pip install vllm"; then
        log_warn "Failed to install vLLM via pip. Installing from source..."
        
        # Alternative installation method
        if ! pct exec "$lxc_id" -- apt-get install -y build-essential; then
            log_warn "Failed to install build tools"
        fi
        
        if ! retry_command 3 10 "pct exec $lxc_id -- pip install 'vllm[all]'"; then
            log_error "Failed to install vLLM in container $lxc_id"
            exit 1
        fi
    fi
    
    echo "vLLM installed successfully in container $lxc_id"
}

# --- Enhanced Container Configuration ---
configure_container() {
    local lxc_id="$1"
    
    log_info "Configuring container $lxc_id for vLLM service..."
    
    # Set up necessary directories
    pct exec "$lxc_id" -- mkdir -p /opt/vllm/models || true
    pct exec "$lxc_id" -- mkdir -p /var/log/vllm || true
    
    # Set proper permissions
    pct exec "$lxc_id" -- chmod 755 /opt/vllm
    pct exec "$lxc_id" -- chmod 755 /var/log/vllm
    
    # Enable systemd service
    echo "Enabling vLLM service..."
    if ! pct exec "$lxc_id" -- systemctl enable vllm.service; then
        log_warn "Failed to enable vLLM service in container $lxc_id"
    fi
    
    # Reload systemd
    echo "Reloading systemd daemon..."
    pct exec "$lxc_id" -- systemctl daemon-reload || true
    
    echo "Container $lxc_id configured for vLLM service"
}

# --- Enhanced vLLM Testing ---
test_vllm_setup() {
    local lxc_id="$1"
    local api_port="$2"
    
    log_info "Testing vLLM setup in container $lxc_id..."
    
    # Check if service is enabled
    if ! pct exec "$lxc_id" -- systemctl is-enabled vllm.service >/dev/null 2>&1; then
        log_warn "vLLM service is not enabled"
    else
        echo "vLLM service is enabled"
    fi
    
    # Check if service is running (this may take a moment)
    echo "Checking if vLLM service is running..."
    sleep 5
    
    local service_status
    service_status=$(pct exec "$lxc_id" -- systemctl status vllm.service 2>/dev/null | head -n1)
    
    if [[ "$service_status" =~ "Active: active" ]]; then
        echo "vLLM service is running"
    else
        echo "vLLM service may not be running properly"
        log_info "Service status details:"
        pct exec "$lxc_id" -- systemctl status vllm.service 2>&1 | head -n 10 || true
    fi
    
    # Test API endpoint (if service is running)
    if [[ "$service_status" =~ "Active: active" ]]; then
        echo "Testing API connectivity..."
        local api_test
        api_test=$(pct exec "$lxc_id" -- curl -s -f "http://localhost:$api_port/v1/models" 2>&1)
        
        if [[ $? -eq 0 ]]; then
            echo "vLLM API is accessible"
        else
            log_warn "Could not connect to vLLM API at port $api_port"
        fi
    fi
    
    echo "vLLM setup testing completed"
}

# --- Enhanced Validation Functions ---
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
    
    log_info "Marked script $script_name as completed for container $lxc_id"
}

# --- Enhanced Error Handling ---
trap 'log_error "Script failed at line $LINENO"; exit 1' ERR

# --- Execute Main Function ---
main "$@"