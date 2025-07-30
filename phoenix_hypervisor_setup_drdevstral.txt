#!/bin/bash

# Phoenix Hypervisor Setup DrDevstral Script
# Configures the DrDevstral LXC container (ID specified as argument) with NVIDIA drivers, NVIDIA container toolkit, Docker, and vLLM for the DevStral model.
# Prerequisites:
# - Proxmox LXC container created with NVIDIA GPU passthrough (e.g., ID 901)
# - Internet access for package and Docker image downloads
# - NVIDIA GPUs available on the host with compatible drivers (version specified in DRTOOLBOX_NVIDIA_DRIVER_VERSION)
# - Root privileges
# - /usr/local/bin/phoenix_hypervisor_common.sh and /usr/local/bin/phoenix_hypervisor_config.sh available
# - jq installed for JSON parsing
# - /etc/phoenix_lxc_configs.json available (downloaded from Git repository)
# Usage: ./phoenix_lxc_setup_drdevstral.sh <lxc_id>
# Example: ./phoenix_lxc_setup_drdevstral.sh 901
# Setup Steps:
# 1. Install NVIDIA drivers in the LXC to match the host version
# 2. Install NVIDIA container toolkit and Docker
# 3. Configure Docker with NVIDIA runtime
# 4. Pull vLLM Docker image and set up vLLM service with configurable parameters
# 5. Perform health check on vLLM API
# 6. Mark setup completion with a marker file

# Source common functions and configuration
source /usr/local/bin/phoenix_hypervisor_common.sh || { echo "Error: Failed to source phoenix_hypervisor_common.sh" >&2; exit 1; }
source /usr/local/bin/phoenix_hypervisor_config.sh || { echo "Error: Failed to source phoenix_hypervisor_config.sh" >&2; exit 1; }

# Check if running as root
check_root

# Set up logging
load_hypervisor_config
export LOGFILE="$HYPERVISOR_LOGFILE"
setup_logging

# Get LXC ID from command-line argument
VLLM_LXC_ID="$1"
if [[ -z "$VLLM_LXC_ID" ]]; then
    log "ERROR" "LXC ID not provided. Usage: $0 <lxc_id>"
    exit 1
fi
log "INFO" "Starting phoenix_lxc_setup_drdevstral.sh for LXC $VLLM_LXC_ID"

# Define the marker file path for this script's completion status
marker_file="${HYPERVISOR_MARKER_DIR}/lxc_${VLLM_LXC_ID}_setup.marker"

# Skip if the setup has already been completed (marker file exists)
if is_script_completed "$marker_file"; then
    log "INFO" "DrDevstral LXC $VLLM_LXC_ID already set up (marker found). Skipping setup."
    exit 0
fi

# Function: ensure_lxc_running
# Description: Ensures the LXC container exists and is running, starting it if necessary.
# Parameters: lxc_id - The ID of the LXC container
# Returns: 0 if the container is running, 1 if it fails to start
ensure_lxc_running() {
    local lxc_id="$1"
    log "INFO" "Checking if LXC container $lxc_id is running..."

    # Check if the container exists
    if ! pct list | grep -q "^\s*$lxc_id\s"; then
        log "ERROR" "LXC container $lxc_id (DrDevstral) does not exist. Please create it first."
        return 1
    fi

    # Check if the container is running; start it if stopped
    if ! pct status "$lxc_id" | grep -q "status: running"; then
        log "INFO" "LXC container $lxc_id is stopped. Starting it now..."
        if ! pct start "$lxc_id"; then
            log "ERROR" "Failed to start LXC container $lxc_id."
            return 1
        fi
        # Wait for the container to be fully running (up to 60 seconds)
        local max_wait=60
        local wait_count=0
        while [[ $wait_count -lt $max_wait ]]; do
            if pct status "$lxc_id" | grep -q "status: running"; then
                log "INFO" "LXC container $lxc_id is now running."
                return 0
            fi
            sleep 1
            ((wait_count++))
        done
        log "ERROR" "LXC container $lxc_id failed to start within $max_wait seconds."
        return 1
    else
        log "INFO" "LXC container $lxc_id is already running."
        return 0
    fi
}

# Ensure the LXC container is running
if ! ensure_lxc_running "$VLLM_LXC_ID"; then
    exit 1
fi

# Function: ensure_lxc_base_packages
# Description: Ensures essential packages (iputils-ping, apt) are installed in the LXC container.
# Parameters: lxc_id - The ID of the LXC container
# Returns: 0 if packages are installed, 1 if installation fails
ensure_lxc_base_packages() {
    local lxc_id="$1"
    log "INFO" "Ensuring base packages (iputils-ping, apt) are installed in LXC $lxc_id..."

    # Check if dpkg is available (minimal way to check package installation)
    execute_in_lxc "$lxc_id" "dpkg -l iputils-ping >/dev/null 2>&1"
    if [[ $? -ne 0 ]]; then
        log "INFO" "Installing iputils-ping in LXC $lxc_id..."
        # Use a minimal package installation method
        execute_in_lxc "$lxc_id" "apt-get update && apt-get install -y iputils-ping"
        if [[ $? -ne 0 ]]; then
            log "ERROR" "Failed to install iputils-ping in LXC $lxc_id. Assuming apt is missing."
            # If apt is missing, use a fallback to install apt and iputils-ping
            execute_in_lxc "$lxc_id" "command -v dpkg >/dev/null 2>&1 || { echo 'dpkg not found'; exit 1; }"
            if [[ $? -ne 0 ]]; then
                log "ERROR" "dpkg not found in LXC $lxc_id. Cannot proceed with package installation."
                return 1
            fi
            # Download and install apt and iputils-ping manually
            execute_in_lxc "$lxc_id" "mkdir -p /tmp/packages && cd /tmp/packages && \
                wget http://deb.debian.org/debian/pool/main/a/apt/apt_2.6.1_amd64.deb && \
                wget http://deb.debian.org/debian/pool/main/i/iputils/iputils-ping_20211215-1_amd64.deb && \
                dpkg -i apt_2.6.1_amd64.deb iputils-ping_20211215-1_amd64.deb"
            if [[ $? -ne 0 ]]; then
                log "ERROR" "Failed to manually install apt and iputils-ping in LXC $lxc_id."
                return 1
            fi
            execute_in_lxc "$lxc_id" "apt-get update && apt-get install -y iputils-ping"
            if [[ $? -ne 0 ]]; then
                log "ERROR" "Failed to install iputils-ping after installing apt in LXC $lxc_id."
                return 1
            fi
        fi
    else
        log "INFO" "iputils-ping already installed in LXC $lxc_id."
    fi
    return 0
}

# Function: ensure_lxc_networking
# Description: Ensures the LXC container has active networking, installing systemd-networkd if necessary.
# Parameters: lxc_id - The ID of the LXC container
# Returns: 0 if networking is active, 1 if it fails
ensure_lxc_networking() {
    local lxc_id="$1"
    log "INFO" "Checking network connectivity in LXC $lxc_id..."

    # Try to ping a reliable external host to verify connectivity
    execute_in_lxc "$lxc_id" "ping -c 1 8.8.8.8 >/dev/null 2>&1"
    if [[ $? -eq 0 ]]; then
        log "INFO" "Network connectivity confirmed in LXC $lxc_id."
        return 0
    fi

    log "INFO" "No network connectivity in LXC $lxc_id. Attempting to configure systemd-networkd..."

    # Install systemd-networkd
    execute_in_lxc "$lxc_id" "apt-get update && apt-get install -y systemd-networkd"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to install systemd-networkd in LXC $lxc_id."
        return 1
    fi

    # Configure a basic DHCP network setup
    execute_in_lxc "$lxc_id" "cat > /etc/systemd/network/20-dhcp.network <<EOF
[Match]
Name=eth0

[Network]
DHCP=yes
EOF"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to configure systemd-networkd in LXC $lxc_id."
        return 1
    fi

    # Enable and start systemd-networkd
    execute_in_lxc "$lxc_id" "systemctl enable systemd-networkd && systemctl restart systemd-networkd"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to enable or start systemd-networkd in LXC $lxc_id."
        return 1
    fi

    # Wait for network to come up (up to 30 seconds)
    local max_wait=30
    local wait_count=0
    while [[ $wait_count -lt $max_wait ]]; do
        execute_in_lxc "$lxc_id" "ping -c 1 8.8.8.8 >/dev/null 2>&1"
        if [[ $? -eq 0 ]]; then
            log "INFO" "Network connectivity established in LXC $lxc_id after configuring systemd-networkd."
            return 0
        fi
        sleep 1
        ((wait_count++))
    done

    log "ERROR" "Failed to establish network connectivity in LXC $lxc_id within $max_wait seconds."
    return 1
}

# Ensure base packages are installed
if ! ensure_lxc_base_packages "$VLLM_LXC_ID"; then
    exit 1
fi

# Ensure networking is active in the LXC container
if ! ensure_lxc_networking "$VLLM_LXC_ID"; then
    exit 1
fi

# Function: detect_nvidia_gpus_and_devices
# Description: Detects NVIDIA GPUs and lists associated device files.
# Parameters: None
# Outputs: Populates global arrays NVIDIA_GPU_PCI_IDS and NVIDIA_DEVICE_FILES
# Returns: 0 on success, 1 on failure
detect_nvidia_gpus_and_devices() {
    log "INFO" "Detecting NVIDIA GPUs and associated device files..."

    # Check if nvidia-smi is available
    if ! command -v nvidia-smi &> /dev/null; then
        log "ERROR" "nvidia-smi not found. Ensure NVIDIA drivers are installed on the host."
        return 1
    fi

    # Reset arrays
    NVIDIA_GPU_PCI_IDS=()
    NVIDIA_DEVICE_FILES=()

    # Use nvidia-smi to get PCI Bus Ids
    mapfile -t gpu_pci_buses < <(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader,nounits 2>/dev/null | sed 's/00000000:/0000:/')

    if [[ ${#gpu_pci_buses[@]} -eq 0 ]]; then
        log "WARN" "No NVIDIA GPUs found via nvidia-smi."
        mapfile -t gpu_pci_buses < <(lspci -d 10de: | grep -E 'VGA|3D' | awk '{print $1}')
        if [[ ${#gpu_pci_buses[@]} -eq 0 ]]; then
             log "ERROR" "No NVIDIA GPUs found via lspci either."
             return 1
        else
             log "INFO" "Found NVIDIA GPUs via lspci: ${gpu_pci_buses[*]}"
        fi
    else
        log "INFO" "Found NVIDIA GPUs via nvidia-smi: ${gpu_pci_buses[*]}"
    fi

    # Populate NVIDIA_GPU_PCI_IDS array
    for pci_bus in "${gpu_pci_buses[@]}"; do
         if [[ ! "$pci_bus" =~ ^0000: ]]; then
              formatted_pci="0000:$pci_bus"
         else
              formatted_pci="$pci_bus"
         fi
         NVIDIA_GPU_PCI_IDS+=("$formatted_pci")
    done

    # Core devices
    NVIDIA_DEVICE_FILES+=("/dev/nvidiactl" "/dev/nvidia-uvm" "/dev/nvidia-uvm-tools" "/dev/nvidia-modeset")

    # Per-GPU devices
    for i in "${!NVIDIA_GPU_PCI_IDS[@]}"; do
        NVIDIA_DEVICE_FILES+=("/dev/nvidia$i")
        if [[ -e "/dev/nvidia-caps/nvidia-cap$i" ]]; then
             NVIDIA_DEVICE_FILES+=("/dev/nvidia-caps/nvidia-cap$i")
        fi
        if [[ -e "/dev/dri/card$i" ]]; then
             NVIDIA_DEVICE_FILES+=("/dev/dri/card$i")
        fi
        if [[ -e "/dev/dri/renderD12$(($i + 8))" ]]; then
             NVIDIA_DEVICE_FILES+=("/dev/dri/renderD12$(($i + 8))")
        fi
    done

    # Add other NVIDIA-related devices
    while IFS= read -r -d '' devfile; do
        if [[ ! " ${NVIDIA_DEVICE_FILES[*]} " =~ " ${devfile} " ]]; then
            NVIDIA_DEVICE_FILES+=("$devfile")
        fi
    done < <(find /dev -type c \( -name "nvidia*" -o -path "/dev/nvidia-caps/*" -o -path "/dev/dri/card*" -o -path "/dev/dri/renderD*" \) 2>/dev/null -print0)

    log "INFO" "Detected NVIDIA GPU PCI IDs: ${NVIDIA_GPU_PCI_IDS[*]}"
    log "INFO" "Detected NVIDIA Device Files: ${NVIDIA_DEVICE_FILES[*]}"

    # Validate core devices
    for core_dev in /dev/nvidiactl /dev/nvidia-uvm; do
        if [[ ! -e "$core_dev" ]]; then
            log "ERROR" "Core NVIDIA device $core_dev not found on host."
            return 1
        fi
    done

    gpu_found=false
    for i in "${!NVIDIA_GPU_PCI_IDS[@]}"; do
        if [[ -e "/dev/nvidia$i" ]]; then
            gpu_found=true
            break
        fi
    done
    if [[ "$gpu_found" == false ]]; then
        log "ERROR" "No /dev/nvidia<i> device files found for detected GPUs."
        return 1
    fi

    log "INFO" "NVIDIA GPU and device detection completed successfully."
    return 0
}

# Function: configure_lxc_gpu_passthrough
# Description: Adds device cgroup rules and mount entries to the LXC config for GPU passthrough.
# Parameters: None (uses global NVIDIA_DEVICE_FILES array)
# Outputs: Modifies the LXC config file
# Returns: 0 on success, 1 on failure
configure_lxc_gpu_passthrough() {
    local lxc_config_file="/etc/pve/lxc/${VLLM_LXC_ID}.conf"
    local temp_config_file="${lxc_config_file}.tmp"

    log "INFO" "Configuring LXC $VLLM_LXC_ID for GPU passthrough using device files."

    if [[ ${#NVIDIA_DEVICE_FILES[@]} -eq 0 ]]; then
        log "ERROR" "No NVIDIA device files detected. Cannot configure passthrough."
        return 1
    fi

    if [[ ! -f "$lxc_config_file" ]]; then
        log "ERROR" "LXC config file $lxc_config_file not found."
        return 1
    fi

    cp "$lxc_config_file" "$temp_config_file" || { log "ERROR" "Failed to copy LXC config to temporary file."; return 1; }

    # Add Cgroup Rules
    local nvidia_major_numbers=(195 235 236 239 240 241 242 243 244)
    for major in "${nvidia_major_numbers[@]}"; do
        echo "lxc.cgroup2.devices.allow: c $major:* rwm" >> "$temp_config_file"
    done

    # Add Mount Entries
    for dev_file in "${NVIDIA_DEVICE_FILES[@]}"; do
        if [[ -e "$dev_file" ]]; then
            local container_path="${dev_file#/}"
            echo "lxc.mount.entry: $dev_file $container_path none bind,optional,create=file" >> "$temp_config_file"
        else
            log "WARN" "Device file $dev_file not found on host, skipping mount entry."
        fi
    done

    mv "$temp_config_file" "$lxc_config_file" || { log "ERROR" "Failed to move temporary config file to original location."; return 1; }

    log "INFO" "LXC $VLLM_LXC_ID GPU passthrough configuration added to $lxc_config_file."
    return 0
}

# Perform robust GPU detection and configuration
log "INFO" "Starting robust GPU passthrough configuration for LXC $VLLM_LXC_ID..."
if ! detect_nvidia_gpus_and_devices; then
    log "ERROR" "Failed to detect NVIDIA GPUs and devices for LXC $VLLM_LXC_ID."
    exit 1
fi

if ! configure_lxc_gpu_passthrough; then
    log "ERROR" "Failed to configure LXC $VLLM_LXC_ID for GPU passthrough."
    exit 1
fi

# Restart LXC to apply changes
log "INFO" "Restarting LXC $VLLM_LXC_ID to apply GPU configuration..."
if ! pct reboot "$VLLM_LXC_ID"; then
    log "WARN" "Failed to reboot LXC $VLLM_LXC_ID. Trying stop/start..."
    if pct stop "$VLLM_LXC_ID" && pct start "$VLLM_LXC_ID"; then
        log "INFO" "LXC $VLLM_LXC_ID restarted successfully using stop/start."
    else
        log "ERROR" "Failed to restart LXC $VLLM_LXC_ID using stop/start. Please restart it manually."
        exit 1
    fi
else
    log "INFO" "LXC $VLLM_LXC_ID rebooted successfully."
fi

# Function to install NVIDIA drivers, container toolkit, Docker, and vLLM in an LXC container
install_vllm_devstral_in_lxc() {
    local lxc_id="$1"
    log "INFO" "Setting up vLLM DevStral in LXC $lxc_id with NVIDIA GPU support..."

    # Update package lists
    execute_in_lxc "$lxc_id" "apt-get update"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to update package lists in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    # Install prerequisites
    execute_in_lxc "$lxc_id" "apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to install prerequisites in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    # Install NVIDIA driver to match host version
    log "INFO" "Installing NVIDIA driver version $DRTOOLBOX_NVIDIA_DRIVER_VERSION in LXC $lxc_id..."
    execute_in_lxc "$lxc_id" "apt-get install -y $DRTOOLBOX_NVIDIA_DRIVER_PKG"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to install NVIDIA driver $DRTOOLBOX_NVIDIA_DRIVER_PKG in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    # Install NVIDIA container toolkit
    execute_in_lxc "$lxc_id" "curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to add NVIDIA container toolkit GPG key in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    execute_in_lxc "$lxc_id" "curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to add NVIDIA container toolkit repository in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    # Update package lists after adding NVIDIA repo
    execute_in_lxc "$lxc_id" "apt-get update"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to update package lists after adding NVIDIA repository in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    # Install NVIDIA container toolkit
    execute_in_lxc "$lxc_id" "apt-get install -y nvidia-container-toolkit"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to install NVIDIA container toolkit in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    # Install Docker Engine
    execute_in_lxc "$lxc_id" "apt-get install -y docker.io"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to install Docker in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    # Configure NVIDIA container runtime as default
    execute_in_lxc "$lxc_id" "cat > /etc/docker/daemon.json <<EOF
{
    \"default-runtime\": \"nvidia\",
    \"runtimes\": {
        \"nvidia\": {
            \"args\": [],
            \"path\": \"nvidia-container-runtime\"
        }
    }
}
EOF"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to configure NVIDIA container runtime in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    # Enable and start the Docker service within the container
    execute_in_lxc "$lxc_id" "systemctl enable --now docker"
    if [[ $? -ne 0 ]]; then
        log "WARN" "Failed to enable Docker service in LXC $lxc_id (might not be critical)."
    fi

    # Restart Docker to apply NVIDIA configuration
    execute_in_lxc "$lxc_id" "systemctl restart docker"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to restart Docker service in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    # Test NVIDIA access in Docker
    log "INFO" "Testing NVIDIA access in Docker in LXC $lxc_id..."
    execute_in_lxc "$lxc_id" "docker run --rm nvidia/cuda:11.0.3-base-ubuntu20.04 nvidia-smi"
    exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "NVIDIA Docker test failed in LXC $lxc_id. GPU setup might be incomplete."
        exit 1
    else
        log "INFO" "NVIDIA Docker test successful in LXC $lxc_id."
    fi

    # Pull vLLM Docker image (fixed version)
    VLLM_IMAGE="nvcr.io/nvidia/vllm:0.8.3"
    log "INFO" "Pulling vLLM Docker image $VLLM_IMAGE in LXC $lxc_id..."
    execute_in_lxc "$lxc_id" "docker pull $VLLM_IMAGE"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to pull vLLM Docker image $VLLM_IMAGE in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    # Load vLLM parameters from LXC_CONFIGS or environment variables
    VLLM_MODEL="${VLLM_MODEL:-stabilityai/devstral-small-8bit}"
    VLLM_TENSOR_PARALLEL_SIZE="${VLLM_TENSOR_PARALLEL_SIZE:-2}"
    VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-16384}"
    VLLM_QUANTIZATION="${VLLM_QUANTIZATION:-awq}"
    VLLM_KV_CACHE_DTYPE="${VLLM_KV_CACHE_DTYPE:-fp8}"
    VLLM_SHM_SIZE="${VLLM_SHM_SIZE:-10.24gb}"
    VLLM_GPU_COUNT="${VLLM_GPU_COUNT:-all}"

    # Override with JSON values if available
    if [[ -n "${LXC_CONFIGS[$lxc_id]}" ]]; then
        config_json=$(jq -c ".lxc_configs.\"$lxc_id\"" /etc/phoenix_lxc_configs.json)
        VLLM_MODEL=$(echo "$config_json" | jq -r ".vllm_model // \"$VLLM_MODEL\"")
        VLLM_TENSOR_PARALLEL_SIZE=$(echo "$config_json" | jq -r ".vllm_tensor_parallel_size // \"$VLLM_TENSOR_PARALLEL_SIZE\"")
        VLLM_MAX_MODEL_LEN=$(echo "$config_json" | jq -r ".vllm_max_model_len // \"$VLLM_MAX_MODEL_LEN\"")
        VLLM_QUANTIZATION=$(echo "$config_json" | jq -r ".vllm_quantization // \"$VLLM_QUANTIZATION\"")
        VLLM_KV_CACHE_DTYPE=$(echo "$config_json" | jq -r ".vllm_kv_cache_dtype // \"$VLLM_KV_CACHE_DTYPE\"")
        VLLM_SHM_SIZE=$(echo "$config_json" | jq -r ".vllm_shm_size // \"$VLLM_SHM_SIZE\"")
        VLLM_GPU_COUNT=$(echo "$config_json" | jq -r ".vllm_gpu_count // \"$VLLM_GPU_COUNT\"")
    fi

    # Create vLLM startup script
    execute_in_lxc "$lxc_id" "cat > /usr/local/bin/start-vllm-devstral.sh <<EOF
#!/bin/bash
# vLLM DevStral startup script
docker run --gpus $VLLM_GPU_COUNT \\
  --shm-size=$VLLM_SHM_SIZE \\
  -p 8000:8000 \\
  -v ~/.cache/huggingface:/root/.cache/huggingface \\
  --name vllm-devstral \\
  --restart unless-stopped \\
  $VLLM_IMAGE \\
  --host 0.0.0.0 \\
  --port 8000 \\
  --model $VLLM_MODEL \\
  --tensor-parallel-size $VLLM_TENSOR_PARALLEL_SIZE \\
  --max-model-len $VLLM_MAX_MODEL_LEN \\
  --quantization $VLLM_QUANTIZATION \\
  --kv-cache-dtype $VLLM_KV_CACHE_DTYPE
EOF"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to create vLLM startup script in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    # Make the script executable
    execute_in_lxc "$lxc_id" "chmod +x /usr/local/bin/start-vllm-devstral.sh"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to make vLLM startup script executable in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    # Create systemd service for vLLM
    execute_in_lxc "$lxc_id" "cat > /etc/systemd/system/vllm-devstral.service <<EOF
[Unit]
Description=vLLM DevStral Service
After=docker.service
Requires=docker.service

[Service]
Type=forking
ExecStart=/usr/local/bin/start-vllm-devstral.sh
ExecStop=/usr/bin/docker stop vllm-devstral
ExecStopPost=/usr/bin/docker rm vllm-devstral
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to create vLLM systemd service in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    # Enable and start the vLLM service
    execute_in_lxc "$lxc_id" "systemctl daemon-reload"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to reload systemd in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    execute_in_lxc "$lxc_id" "systemctl enable vllm-devstral"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to enable vLLM service in LXC $lxc_id. Aborting setup."
        exit 1
    fi

    # Test vLLM installation by starting the service
    log "INFO" "Starting vLLM DevStral service in LXC $lxc_id..."
    execute_in_lxc "$lxc_id" "systemctl start vllm-devstral"
    exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Failed to start vLLM DevStral service in LXC $lxc_id."
        exit 1
    else
        log "INFO" "vLLM DevStral service started successfully in LXC $lxc_id."
    fi

    # Wait a moment for the service to initialize
    sleep 10

    # Check if the service is running
    execute_in_lxc "$lxc_id" "systemctl is-active --quiet vllm-devstral"
    if [[ $? -ne 0 ]]; then
        log "ERROR" "vLLM DevStral service is not running in LXC $lxc_id."
        exit 1
    else
        log "INFO" "vLLM DevStral service is active in LXC $lxc_id."
    fi

    # Perform vLLM health check
    log "INFO" "Performing vLLM health check in LXC $lxc_id..."
    execute_in_lxc "$lxc_id" "curl -s http://localhost:8000/health"
    exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "vLLM health check failed in LXC $lxc_id. API might not be accessible."
        exit 1
    else
        log "INFO" "vLLM health check successful in LXC $lxc_id."
    fi

    # Mark the completion of vLLM DevStral setup for this container
    mark_script_completed "$marker_file"
}

# Install vLLM DevStral in the specified LXC container
install_vllm_devstral_in_lxc "$VLLM_LXC_ID"

log "INFO" "Completed phoenix_lxc_setup_drdevstral.sh successfully for LXC $VLLM_LXC_ID."
exit 0