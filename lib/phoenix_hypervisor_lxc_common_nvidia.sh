#!/bin/bash
# Common NVIDIA functions for LXC containers in Phoenix Hypervisor
# Provides functions for installing/checking NVIDIA drivers, CUDA toolkit, and verifying GPU access INSIDE containers
# Designed to be sourced by scripts that interact with containers (e.g., setup_drdevstral.sh, setup_drcuda.sh)
# Version: 2.0.1 (Added QUIET_MODE, config backup, retry logic, .sh extension, aligned logging)
# Author: Assistant
# Integration: Supports GPU-enabled containers (900-902) for AI workloads (vLLM, LLaMA CPP, Ollama)

# --- Signal Successful Loading ---
export PHOENIX_HYPERVISOR_LXC_NVIDIA_LOADED=1

# --- Logging Setup ---
PHOENIX_NVIDIA_LOG_DIR="/var/log/phoenix_hypervisor"
PHOENIX_NVIDIA_LOG_FILE="$PHOENIX_NVIDIA_LOG_DIR/phoenix_hypervisor_lxc_common_nvidia.log"

mkdir -p "$PHOENIX_NVIDIA_LOG_DIR" 2>>"$PHOENIX_NVIDIA_LOG_DIR/phoenix_hypervisor_lxc_common_nvidia.log" || {
    log_warn "Failed to create $PHOENIX_NVIDIA_LOG_DIR, falling back to /tmp"
    PHOENIX_NVIDIA_LOG_DIR="/tmp"
    PHOENIX_NVIDIA_LOG_FILE="$PHOENIX_NVIDIA_LOG_DIR/phoenix_hypervisor_lxc_common_nvidia.log"
}
touch "$PHOENIX_NVIDIA_LOG_FILE" 2>>"$PHOENIX_NVIDIA_LOG_FILE" || log_warn "Failed to create $PHOENIX_NVIDIA_LOG_FILE"
chmod 644 "$PHOENIX_NVIDIA_LOG_FILE" 2>>"$PHOENIX_NVIDIA_LOG_FILE" || log_warn "Could not set permissions to 644 on $PHOENIX_NVIDIA_LOG_FILE"

# --- Enhanced Sourcing of Dependencies ---
if ! declare -f log_info >/dev/null 2>&1; then
    if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
        source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh
    elif [[ -f "/usr/local/bin/phoenix_hypervisor_common.sh" ]]; then
        source /usr/local/bin/phoenix_hypervisor_common.sh
        log_warn "phoenix_hypervisor_lxc_common_nvidia.sh: Sourced common functions from /usr/local/bin/. Prefer /usr/local/lib/phoenix_hypervisor/."
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] phoenix_hypervisor_lxc_common_nvidia.sh: Cannot find phoenix_hypervisor_common.sh" >&2
        exit 1
    fi
fi
if [[ -z "$PHOENIX_HYPERVISOR_COMMON_LOADED" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] phoenix_hypervisor_lxc_common_nvidia.sh: Failed to load phoenix_hypervisor_common.sh" >&2
    exit 1
fi

# --- Source Phoenix Hypervisor Configuration ---
if [[ -z "$PHOENIX_HYPERVISOR_CONFIG_LOADED" ]]; then
    if [[ -f "/usr/local/etc/phoenix_hypervisor_config.sh" ]]; then
        source /usr/local/etc/phoenix_hypervisor_config.sh
        log_info "phoenix_hypervisor_lxc_common_nvidia.sh: Sourced configuration from /usr/local/etc/phoenix_hypervisor_config.sh"
    else
        log_error "phoenix_hypervisor_lxc_common_nvidia.sh: Configuration file /usr/local/etc/phoenix_hypervisor_config.sh not found."
        exit 1
    fi
fi

# --- Helper Function: Check GPU Assignment ---
check_gpu_assignment() {
    local lxc_id="$1"
    if [[ -z "$lxc_id" ]]; then
        log_error "check_gpu_assignment: Missing lxc_id"
        return 1
    fi

    local config_file="${PHOENIX_LXC_CONFIG_FILE:-/usr/local/etc/phoenix_lxc_configs.json}"
    if [[ ! -f "$config_file" ]]; then
        log_error "check_gpu_assignment: Configuration file $config_file not found"
        return 1
    fi

    local gpu_assignment
    if ! gpu_assignment=$(retry_command 3 5 jq -r ".lxc_configs.\"$lxc_id\".gpu_assignment // \"none\"" "$config_file" 2>>"$PHOENIX_NVIDIA_LOG_FILE"); then
        log_error "check_gpu_assignment: Failed to parse gpu_assignment for container $lxc_id"
        return 1
    fi
    if [[ "$gpu_assignment" == "none" || -z "$gpu_assignment" ]]; then
        log_info "check_gpu_assignment: No GPU assignment for container $lxc_id (gpu_assignment: $gpu_assignment)"
        return 1
    else
        log_info "check_gpu_assignment: GPU assignment found for container $lxc_id: $gpu_assignment"
        echo "$gpu_assignment"
        return 0
    fi
}

# --- Install NVIDIA Driver in Container via Runfile ---
install_nvidia_driver_in_container_via_runfile() {
    local lxc_id="$1"
    local config_file="${PHOENIX_LXC_CONFIG_FILE:-/usr/local/etc/phoenix_lxc_configs.json}"
    local driver_version=$(jq -r ".lxc_configs.\"$lxc_id\".nvidia_driver_version // \"580.76.05\"" "$config_file" 2>>"$PHOENIX_NVIDIA_LOG_FILE")
    local runfile_url="https://us.download.nvidia.com/XFree86/Linux-x86_64/$driver_version/NVIDIA-Linux-x86_64-$driver_version.run"
    local runfile_name="NVIDIA-Linux-x86_64-$driver_version.run"

    if [[ -z "$lxc_id" ]]; then
        log_error "install_nvidia_driver_in_container_via_runfile: Missing lxc_id"
        return 1
    fi

    # Check if container has GPU assignment
    if ! check_gpu_assignment "$lxc_id"; then
        log_info "install_nvidia_driver_in_container_via_runfile: Skipping NVIDIA driver installation for container $lxc_id (no GPU assignment)"
        return 0
    fi

    log_info "install_nvidia_driver_in_container_via_runfile: Installing NVIDIA driver $driver_version in container $lxc_id using runfile..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Installing NVIDIA driver $driver_version in container $lxc_id... This may take a few minutes." >&2
    fi

    local check_installed_cmd="
set -e
export LC_ALL=C.UTF-8 LANG=C.UTF-8
if command -v nvidia-smi >/dev/null 2>&1; then
    installed_version=\$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null | head -n 1)
    if [[ \"\$installed_version\" == \"$driver_version\" ]]; then
        echo '[SUCCESS] NVIDIA driver $driver_version already installed in container $lxc_id.'
        exit 0
    else
        echo '[INFO] NVIDIA driver found (version \$installed_version), but $driver_version is required.'
    fi
else
    echo '[INFO] NVIDIA driver not found. Proceeding with installation.'
fi
exit 1
"
    if pct_exec_with_retry "$lxc_id" bash -c "$check_installed_cmd" 2>>"$PHOENIX_NVIDIA_LOG_FILE"; then
        log_info "install_nvidia_driver_in_container_via_runfile: NVIDIA driver $driver_version already installed in container $lxc_id."
        return 0
    fi

    log_info "install_nvidia_driver_in_container_via_runfile: Installing prerequisites in container $lxc_id..."
    local install_prereqs_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8 LANG=C.UTF-8
apt-get update -y --fix-missing
apt-get install -y g++ freeglut3-dev build-essential libx11-dev libxmu-dev libxi-dev libglu1-mesa-dev libfreeimage-dev libglfw3-dev wget git pciutils cmake curl libcurl4-openssl-dev
"
    if ! pct_exec_with_retry "$lxc_id" bash -c "$install_prereqs_cmd" 2>>"$PHOENIX_NVIDIA_LOG_FILE"; then
        log_error "install_nvidia_driver_in_container_via_runfile: Failed to install prerequisites in container $lxc_id."
        return 1
    fi

    log_info "install_nvidia_driver_in_container_via_runfile: Downloading driver runfile ($runfile_name) in container $lxc_id..."
    local download_cmd="
set -e
export LC_ALL=C.UTF-8 LANG=C.UTF-8
wget --quiet '$runfile_url' -O '$runfile_name' || { echo '[ERROR] Failed to download $runfile_name'; exit 1; }
"
    if ! pct_exec_with_retry "$lxc_id" bash -c "$download_cmd" 2>>"$PHOENIX_NVIDIA_LOG_FILE"; then
        log_error "install_nvidia_driver_in_container_via_runfile: Failed to download runfile in container $lxc_id."
        return 1
    fi

    log_info "install_nvidia_driver_in_container_via_runfile: Running installer ($runfile_name) in container $lxc_id..."
    local install_runfile_cmd="
set -e
export LC_ALL=C.UTF-8 LANG=C.UTF-8
chmod +x '$runfile_name'
./'$runfile_name' --silent --no-kernel-module --accept-license || { echo '[ERROR] Installer failed'; exit 1; }
if [[ -f '/usr/bin/nvidia-smi' ]]; then
    echo '[INFO] Installer completed.'
else
    echo '[ERROR] nvidia-smi not found after installation.'
    exit 1
fi
"
    if ! pct_exec_with_retry "$lxc_id" bash -c "$install_runfile_cmd" 2>>"$PHOENIX_NVIDIA_LOG_FILE"; then
        log_error "install_nvidia_driver_in_container_via_runfile: Failed to run installer in container $lxc_id."
        pct_exec_with_retry "$lxc_id" bash -c "rm -f '$runfile_name'" 2>>"$PHOENIX_NVIDIA_LOG_FILE" || log_warn "Failed to clean up runfile."
        return 1
    fi

    log_info "install_nvidia_driver_in_container_via_runfile: Cleaning up runfile in container $lxc_id..."
    pct_exec_with_retry "$lxc_id" bash -c "rm -f '$runfile_name'" 2>>"$PHOENIX_NVIDIA_LOG_FILE" || log_warn "Failed to clean up runfile."

    log_info "install_nvidia_driver_in_container_via_runfile: Verifying driver installation in container $lxc_id..."
    local verify_cmd="
set -e
export LC_ALL=C.UTF-8 LANG=C.UTF-8
if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo '[ERROR] nvidia-smi not found.'
    exit 1
fi
driver_version_out=\$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null | head -n 1)
if [[ \"\$driver_version_out\" == \"$driver_version\" ]]; then
    echo '[SUCCESS] NVIDIA driver $driver_version verified in container $lxc_id.'
    exit 0
else
    echo '[ERROR] Driver version mismatch. Expected $driver_version, got \$driver_version_out.'
    exit 1
fi
"
    if pct_exec_with_retry "$lxc_id" bash -c "$verify_cmd" 2>>"$PHOENIX_NVIDIA_LOG_FILE"; then
        log_info "install_nvidia_driver_in_container_via_runfile: NVIDIA driver $driver_version installed and verified in container $lxc_id."
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "NVIDIA driver $driver_version installation completed for container $lxc_id." >&2
        fi
        return 0
    else
        log_error "install_nvidia_driver_in_container_via_runfile: Failed to verify driver installation in container $lxc_id."
        return 1
    fi
}

# --- Install CUDA Toolkit 12.8 in Container ---
install_cuda_toolkit_12_8_in_container() {
    local lxc_id="$1"
    if [[ -z "$lxc_id" ]]; then
        log_error "install_cuda_toolkit_12_8_in_container: Missing lxc_id"
        return 1
    fi

    if ! check_gpu_assignment "$lxc_id"; then
        log_info "install_cuda_toolkit_12_8_in_container: Skipping CUDA Toolkit installation for container $lxc_id (no GPU assignment)"
        return 0
    fi

    log_info "install_cuda_toolkit_12_8_in_container: Installing CUDA Toolkit 12.8 in container $lxc_id..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Installing CUDA Toolkit 12.8 in container $lxc_id... This may take a few minutes." >&2
    fi

    local check_installed_cmd="
set -e
export LC_ALL=C.UTF-8 LANG=C.UTF-8
if [[ -f /etc/profile.d/cuda.sh ]]; then
    source /etc/profile.d/cuda.sh
fi
export PATH=/usr/local/cuda-12.8/bin:\$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.8/lib64:\$LD_LIBRARY_PATH
if command -v nvcc >/dev/null 2>&1; then
    installed_version=\$(nvcc --version | grep 'release' | awk '{print \$5}' | sed 's/,//')
    if [[ \"\$installed_version\" == \"12.8\" ]]; then
        echo '[SUCCESS] CUDA Toolkit 12.8 verified in container $lxc_id.'
        exit 0
    else
        echo '[INFO] CUDA Toolkit found (version \$installed_version), but 12.8 is required.'
    fi
else
    echo '[INFO] CUDA Toolkit not found. Proceeding with installation.'
fi
exit 1
"
    if pct_exec_with_retry "$lxc_id" bash -c "$check_installed_cmd" 2>>"$PHOENIX_NVIDIA_LOG_FILE"; then
        log_info "install_cuda_toolkit_12_8_in_container: CUDA Toolkit 12.8 already installed in container $lxc_id."
        return 0
    fi

    log_info "install_cuda_toolkit_12_8_in_container: Installing prerequisites in container $lxc_id..."
    local install_prereqs_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8 LANG=C.UTF-8
apt-get update -y --fix-missing
apt-get install -y locales wget gnupg software-properties-common
locale-gen en_US.UTF-8 C.UTF-8
update-locale LC_ALL=C.UTF-8 LANG=C.UTF-8
"
    if ! pct_exec_with_retry "$lxc_id" bash -c "$install_prereqs_cmd" 2>>"$PHOENIX_NVIDIA_LOG_FILE"; then
        log_error "install_cuda_toolkit_12_8_in_container: Failed to install prerequisites in container $lxc_id."
        return 1
    fi

    log_info "install_cuda_toolkit_12_8_in_container: Installing CUDA Toolkit 12.8 in container $lxc_id..."
    local cuda_install_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8 LANG=C.UTF-8
wget -qO /tmp/cuda-keyring_1.1-1_all.deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i /tmp/cuda-keyring_1.1-1_all.deb || { echo '[ERROR] Failed to install CUDA keyring'; exit 1; }
rm -f /tmp/cuda-keyring_1.1-1_all.deb
echo 'deb [signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/ /' > /etc/apt/sources.list.d/cuda-ubuntu2404-x86_64.list
apt-get update -y --fix-missing || { echo '[ERROR] Failed to update package lists'; exit 1; }
apt-get install -y cuda-toolkit-12-8 cuda-compiler-12-8 || { echo '[ERROR] Failed to install CUDA Toolkit'; exit 1; }
mkdir -p /etc/profile.d
cat > /etc/profile.d/cuda.sh << 'EOF'
#!/bin/bash
export CUDA_HOME=/usr/local/cuda
export PATH=\$CUDA_HOME/bin:\$PATH
export LD_LIBRARY_PATH=\$CUDA_HOME/lib64:\$LD_LIBRARY_PATH
EOF
chmod +x /etc/profile.d/cuda.sh
source /etc/profile.d/cuda.sh
"
    if ! pct_exec_with_retry "$lxc_id" bash -c "$cuda_install_cmd" 2>>"$PHOENIX_NVIDIA_LOG_FILE"; then
        log_error "install_cuda_toolkit_12_8_in_container: Failed to install CUDA Toolkit in container $lxc_id."
        return 1
    fi

    log_info "install_cuda_toolkit_12_8_in_container: Verifying CUDA Toolkit installation in container $lxc_id..."
    local verify_cmd="
set -e
export LC_ALL=C.UTF-8 LANG=C.UTF-8
if [[ -f /etc/profile.d/cuda.sh ]]; then
    source /etc/profile.d/cuda.sh
else
    export CUDA_HOME=/usr/local/cuda
    export PATH=\$CUDA_HOME/bin:\$PATH
    export LD_LIBRARY_PATH=\$CUDA_HOME/lib64:\$LD_LIBRARY_PATH
fi
if ! command -v nvcc >/dev/null 2>&1; then
    echo '[ERROR] nvcc not found.'
    exit 1
fi
nvcc_version_out=\$(nvcc --version | grep 'release' | awk '{print \$5}' | sed 's/,//')
if [[ \"\$nvcc_version_out\" == \"12.8\" ]]; then
    echo '[SUCCESS] CUDA Toolkit 12.8 verified in container $lxc_id.'
    exit 0
else
    echo '[ERROR] CUDA version mismatch. Expected 12.8, got \$nvcc_version_out.'
    exit 1
fi
"
    if pct_exec_with_retry "$lxc_id" bash -c "$verify_cmd" 2>>"$PHOENIX_NVIDIA_LOG_FILE"; then
        log_info "install_cuda_toolkit_12_8_in_container: CUDA Toolkit 12.8 installed and verified in container $lxc_id."
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "CUDA Toolkit 12.8 installation completed for container $lxc_id." >&2
        fi
        return 0
    else
        log_error "install_cuda_toolkit_12_8_in_container: Failed to verify CUDA Toolkit installation in container $lxc_id."
        return 1
    fi
}

# --- Install Docker-ce in Container ---
install_docker_ce_in_container() {
    local lxc_id="$1"
    if [[ -z "$lxc_id" ]]; then
        log_error "install_docker_ce_in_container: Missing lxc_id"
        return 1
    fi

    log_info "install_docker_ce_in_container: Installing Docker-ce in container $lxc_id..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Installing Docker-ce in container $lxc_id... This may take a few minutes." >&2
    fi

    local check_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8 LANG=C.UTF-8
if command -v docker >/dev/null 2>&1 && dpkg -l | grep -q docker-ce; then
    echo '[SUCCESS] Docker-ce already installed in container $lxc_id.'
    exit 0
fi
exit 1
"
    if pct_exec_with_retry "$lxc_id" bash -c "$check_cmd" 2>>"$PHOENIX_NVIDIA_LOG_FILE"; then
        log_info "install_docker_ce_in_container: Docker-ce already installed in container $lxc_id."
        return 0
    fi

    local install_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8 LANG=C.UTF-8
apt-get remove -y docker docker-engine docker.io containerd runc || true
apt-get update -y --fix-missing
apt-get install -y ca-certificates curl gnupg lsb-release
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo 'deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable' > /etc/apt/sources.list.d/docker.list
apt-get update -y --fix-missing || { echo '[ERROR] Failed to update package lists'; exit 1; }
apt-get install -y docker-ce docker-ce-cli containerd.io || { echo '[ERROR] Failed to install Docker-ce'; exit 1; }
if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
    systemctl enable docker || { echo '[ERROR] Failed to enable docker.service'; exit 1; }
    systemctl start docker || { echo '[ERROR] Failed to start docker.service'; exit 1; }
else
    if ! pgrep -x dockerd >/dev/null 2>&1; then
        /usr/bin/dockerd -H unix:///var/run/docker.sock --containerd=/run/containerd/containerd.sock >/dev/null 2>&1 &
        sleep 5
        if ! pgrep -x dockerd >/dev/null 2>&1; then
            echo '[ERROR] Failed to start Docker daemon.'
            exit 1
        fi
    fi
fi
if docker info >/dev/null 2>&1; then
    echo '[SUCCESS] Docker-ce installed and running in container $lxc_id.'
else
    echo '[ERROR] Docker-ce verification failed.'
    exit 1
fi
"
    if ! pct_exec_with_retry "$lxc_id" bash -c "$install_cmd" 2>>"$PHOENIX_NVIDIA_LOG_FILE"; then
        log_error "install_docker_ce_in_container: Failed to install Docker-ce in container $lxc_id after 3 attempts."
        return 1
    fi

    log_info "install_docker_ce_in_container: Docker-ce installed successfully in container $lxc_id."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Docker-ce installation completed for container $lxc_id." >&2
    fi
    return 0
}

# --- Install NVIDIA Container Toolkit in Container ---
install_nvidia_toolkit_in_container() {
    local lxc_id="$1"
    if [[ -z "$lxc_id" ]]; then
        log_error "install_nvidia_toolkit_in_container: Missing lxc_id"
        return 1
    fi

    if ! check_gpu_assignment "$lxc_id"; then
        log_info "install_nvidia_toolkit_in_container: Skipping NVIDIA Container Toolkit installation for container $lxc_id (no GPU assignment)"
        return 0
    fi

    log_info "install_nvidia_toolkit_in_container: Installing NVIDIA Container Toolkit in container $lxc_id..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Installing NVIDIA Container Toolkit in container $lxc_id... This may take a few minutes." >&2
    fi

    local check_installed_cmd="
set -e
export LC_ALL=C.UTF-8 LANG=C.UTF-8
if command -v nvidia-ctk >/dev/null 2>&1 && dpkg -l | grep -q nvidia-container-toolkit; then
    echo '[SUCCESS] NVIDIA Container Toolkit already installed in container $lxc_id.'
    exit 0
fi
exit 1
"
    if pct_exec_with_retry "$lxc_id" bash -c "$check_installed_cmd" 2>>"$PHOENIX_NVIDIA_LOG_FILE"; then
        log_info "install_nvidia_toolkit_in_container: NVIDIA Container Toolkit already installed in container $lxc_id."
        return 0
    fi

    local install_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8 LANG=C.UTF-8
apt-get update -y --fix-missing
apt-get install -y curl gnupg ca-certificates
if [ ! -f /etc/apt/sources.list.d/cuda-ubuntu2404-x86_64.list ]; then
    mkdir -p /etc/apt/keyrings
    wget -qO /tmp/cuda-keyring_1.1-1_all.deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
    dpkg -i /tmp/cuda-keyring_1.1-1_all.deb || { echo '[ERROR] Failed to install CUDA keyring'; exit 1; }
    rm -f /tmp/cuda-keyring_1.1-1_all.deb
    echo 'deb [signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/ /' > /etc/apt/sources.list.d/cuda-ubuntu2404-x86_64.list
fi
apt-get update -y --fix-missing || { echo '[ERROR] Failed to update package lists'; exit 1; }
apt-get install -y nvidia-container-toolkit || { echo '[ERROR] Failed to install NVIDIA Container Toolkit'; exit 1; }
if command -v nvidia-ctk >/dev/null 2>&1; then
    echo '[SUCCESS] NVIDIA Container Toolkit installed in container $lxc_id.'
else
    echo '[ERROR] NVIDIA Container Toolkit verification failed.'
    exit 1
fi
"
    if ! pct_exec_with_retry "$lxc_id" bash -c "$install_cmd" 2>>"$PHOENIX_NVIDIA_LOG_FILE"; then
        log_error "install_nvidia_toolkit_in_container: Failed to install NVIDIA Container Toolkit in container $lxc_id after 3 attempts."
        return 1
    fi

    log_info "install_nvidia_toolkit_in_container: NVIDIA Container Toolkit installed successfully in container $lxc_id."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "NVIDIA Container Toolkit installation completed for container $lxc_id." >&2
    fi
    return 0
}

# --- Configure NVIDIA Runtime for Docker ---
configure_docker_nvidia_runtime() {
    local lxc_id="$1"
    if [[ -z "$lxc_id" ]]; then
        log_error "configure_docker_nvidia_runtime: Missing lxc_id"
        return 1
    fi

    if ! check_gpu_assignment "$lxc_id"; then
        log_info "configure_docker_nvidia_runtime: Skipping NVIDIA runtime configuration for container $lxc_id (no GPU assignment)"
        return 0
    fi

    log_info "configure_docker_nvidia_runtime: Configuring NVIDIA runtime for Docker in container $lxc_id..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Configuring NVIDIA runtime for Docker in container $lxc_id..." >&2
    fi

    local config_cmd="
set -e
export LC_ALL=C.UTF-8 LANG=C.UTF-8
if ! command -v nvidia-ctk >/dev/null 2>&1; then
    echo '[ERROR] NVIDIA Container Toolkit not installed.'
    exit 1
fi
if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
    echo '[ERROR] NVIDIA driver not available.'
    exit 1
fi
if docker info --format '{{.Runtimes}}' | grep -q 'nvidia'; then
    echo '[INFO] NVIDIA runtime already configured.'
    exit 0
fi
nvidia-ctk runtime configure --runtime=docker || { echo '[ERROR] Failed to configure NVIDIA runtime'; exit 1; }
if [ ! -f /etc/nvidia-container-runtime/config.toml ]; then
    echo '[ERROR] NVIDIA Container Toolkit config file not found.'
    exit 1
fi
if ! grep -q 'no-cgroups = true' /etc/nvidia-container-runtime/config.toml; then
    sed -i '/\[nvidia-container-runtime\]/a no-cgroups = true' /etc/nvidia-container-runtime/config.toml || { echo '[ERROR] Failed to update NVIDIA Container Toolkit config'; exit 1; }
fi
cat > /etc/docker/daemon.json << 'EOF'
{
    "runtimes": {
        "nvidia": {
            "path": "/usr/bin/nvidia-container-runtime",
            "runtimeArgs": []
        }
    },
    "default-runtime": "nvidia",
    "exec-opts": ["native.cgroupdriver=cgroupfs"]
}
EOF
if command -v jq >/dev/null 2>&1 || apt-get install -y jq; then
    if ! jq . /etc/docker/daemon.json >/dev/null 2>&1; then
        echo '[ERROR] Invalid Docker daemon.json syntax.'
        exit 1
    fi
fi
if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
    systemctl daemon-reload || { echo '[ERROR] Failed to reload systemd daemon'; exit 1; }
    systemctl restart docker || { echo '[ERROR] Failed to restart Docker service'; exit 1; }
    if systemctl is-active --quiet docker; then
        echo '[SUCCESS] Docker service restarted.'
    else
        echo '[ERROR] Docker service not active.'
        exit 1
    fi
else
    pkill -x dockerd || true
    sleep 2
    if ! pgrep -x dockerd >/dev/null 2>&1; then
        /usr/bin/dockerd -H unix:///var/run/docker.sock --containerd=/run/containerd/containerd.sock >/dev/null 2>&1 &
        sleep 5
        if pgrep -x dockerd >/dev/null 2>&1; then
            echo '[SUCCESS] Docker daemon restarted.'
        else
            echo '[ERROR] Failed to restart Docker daemon.'
            exit 1
        fi
    fi
fi
if docker info --format '{{.Runtimes}}' | grep -q 'nvidia'; then
    echo '[SUCCESS] NVIDIA runtime configured.'
else
    echo '[ERROR] NVIDIA runtime verification failed.'
    exit 1
fi
"
    if ! pct_exec_with_retry "$lxc_id" bash -c "$config_cmd" 2>>"$PHOENIX_NVIDIA_LOG_FILE"; then
        log_error "configure_docker_nvidia_runtime: Failed to configure NVIDIA runtime in container $lxc_id after 3 attempts."
        return 1
    fi

    log_info "configure_docker_nvidia_runtime: NVIDIA runtime configured successfully in container $lxc_id."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "NVIDIA runtime configuration completed for container $lxc_id." >&2
    fi
    return 0
}

# --- Build Docker Image in Container ---
build_docker_image_in_container() {
    local lxc_id="$1"
    local dockerfile_path="$2"
    local image_tag="$3"
    if [[ -z "$lxc_id" ]] || [[ -z "$dockerfile_path" ]] || [[ -z "$image_tag" ]]; then
        log_error "build_docker_image_in_container: Missing lxc_id, dockerfile_path, or image_tag"
        return 1
    fi

    log_info "build_docker_image_in_container: Building Docker image $image_tag in container $lxc_id from $dockerfile_path..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Building Docker image $image_tag in container $lxc_id... This may take a few minutes." >&2
    fi

    local check_cmd="
set -e
export LC_ALL=C.UTF-8 LANG=C.UTF-8
if docker images -q $image_tag | grep -q .; then
    echo '[SUCCESS] Docker image $image_tag already exists in container $lxc_id.'
    exit 0
fi
exit 1
"
    if pct_exec_with_retry "$lxc_id" bash -c "$check_cmd" 2>>"$PHOENIX_NVIDIA_LOG_FILE"; then
        log_info "build_docker_image_in_container: Docker image $image_tag already exists in container $lxc_id."
        return 0
    fi

    local build_cmd="
set -e
export LC_ALL=C.UTF-8 LANG=C.UTF-8
if ! command -v docker >/dev/null 2>&1; then
    echo '[ERROR] Docker not installed.'
    exit 1
fi
cd \"\$(dirname $dockerfile_path)\" || { echo '[ERROR] Failed to change directory'; exit 1; }
docker build -t $image_tag -f $dockerfile_path . || { echo '[ERROR] Failed to build Docker image $image_tag'; exit 1; }
if docker images -q $image_tag | grep -q .; then
    echo '[SUCCESS] Docker image $image_tag built in container $lxc_id.'
else
    echo '[ERROR] Docker image $image_tag verification failed.'
    exit 1
fi
"
    if ! pct_exec_with_retry "$lxc_id" bash -c "$build_cmd" 2>>"$PHOENIX_NVIDIA_LOG_FILE"; then
        log_error "build_docker_image_in_container: Failed to build Docker image $image_tag in container $lxc_id after 3 attempts."
        return 1
    fi

    log_info "build_docker_image_in_container: Docker image $image_tag built successfully in container $lxc_id."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Docker image build completed for $image_tag in container $lxc_id." >&2
    fi
    return 0
}

# --- Detect GPUs Inside Container ---
detect_gpus_in_container() {
    local lxc_id="$1"
    if [[ -z "$lxc_id" ]]; then
        log_error "detect_gpus_in_container: Missing lxc_id"
        return 1
    fi

    if ! check_gpu_assignment "$lxc_id"; then
        log_info "detect_gpus_in_container: Skipping GPU detection for container $lxc_id (no GPU assignment)"
        return 0
    fi

    log_info "detect_gpus_in_container: Detecting GPUs in container $lxc_id..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Checking GPU access in container $lxc_id..." >&2
    fi

    local check_cmd="
set -e
export LC_ALL=C.UTF-8 LANG=C.UTF-8
if command -v nvidia-smi >/dev/null 2>&1; then
    if nvidia-smi >/dev/null 2>&1; then
        echo '[SUCCESS] GPUs detected in container $lxc_id.'
        nvidia-smi --query-gpu=count,driver_version --format=csv,noheader
    else
        echo '[ERROR] nvidia-smi command failed.'
        exit 1
    fi
else
    echo '[ERROR] nvidia-smi not found.'
    exit 1
fi
"
    local result
    if ! result=$(pct_exec_with_retry "$lxc_id" bash -c "$check_cmd" 2>>"$PHOENIX_NVIDIA_LOG_FILE"); then
        log_error "detect_gpus_in_container: GPU detection failed in container $lxc_id: $result"
        return 1
    fi

    log_info "detect_gpus_in_container: GPUs detected in container $lxc_id: $result"
    local docker_check="
set -e
export LC_ALL=C.UTF-8 LANG=C.UTF-8
if ! command -v docker >/dev/null 2>&1; then
    echo '[ERROR] Docker not installed.'
    exit 1
fi
if ! docker info --format '{{.Runtimes}}' | grep -q 'nvidia'; then
    echo '[ERROR] NVIDIA runtime not configured.'
    exit 1
fi
if ! grep -q 'no-cgroups = true' /etc/nvidia-container-runtime/config.toml; then
    echo '[WARN] NVIDIA Container Toolkit not configured with no-cgroups = true.'
fi
if ! docker pull nvidia/cuda:12.8.0-base-ubuntu24.04 >/tmp/docker-pull.log 2>&1; then
    echo '[WARN] Failed to pull nvidia/cuda:12.8.0-base-ubuntu24.04.'
    exit 1
fi
if docker run --rm --gpus all --runtime=nvidia nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi >/tmp/docker-gpu-test.log 2>&1; then
    echo '[SUCCESS] Docker GPU access verified in container $lxc_id.'
    exit 0
else
    echo '[ERROR] Docker GPU access verification failed.'
    cat /tmp/docker-gpu-test.log
    exit 1
fi
"
    if pct_exec_with_retry "$lxc_id" bash -c "$docker_check" 2>>"$PHOENIX_NVIDIA_LOG_FILE"; then
        log_info "detect_gpus_in_container: Docker GPU access verified in container $lxc_id."
        return 0
    else
        log_error "detect_gpus_in_container: Docker GPU access verification failed in container $lxc_id."
        return 1
    fi
}

# --- Verify LXC GPU Access Inside Container ---
verify_lxc_gpu_access_in_container() {
    local lxc_id="$1"
    if [[ -z "$lxc_id" ]]; then
        log_error "verify_lxc_gpu_access_in_container: Missing lxc_id"
        return 1
    fi

    log_info "verify_lxc_gpu_access_in_container: Verifying GPU access for container $lxc_id..."
    if detect_gpus_in_container "$lxc_id"; then
        log_info "verify_lxc_gpu_access_in_container: GPU access verified for container $lxc_id."
        return 0
    else
        log_error "verify_lxc_gpu_access_in_container: Failed to verify GPU access for container $lxc_id."
        return 1
    fi
}

# --- Configure GPU Passthrough for LXC ---
configure_lxc_gpu_passthrough() {
    local lxc_id="$1"
    local gpu_indices

    if [[ -z "$lxc_id" ]]; then
        log_error "configure_lxc_gpu_passthrough: Missing lxc_id"
        return 1
    fi

    gpu_indices=$(check_gpu_assignment "$lxc_id")
    if [[ $? -ne 0 ]]; then
        log_info "configure_lxc_gpu_passthrough: Skipping GPU passthrough configuration for container $lxc_id (no GPU assignment)"
        return 0
    fi

    local config_file="/etc/pve/lxc/$lxc_id.conf"
    if [[ ! -f "$config_file" ]]; then
        log_error "configure_lxc_gpu_passthrough: LXC config file not found: $config_file"
        return 1
    fi

    log_info "configure_lxc_gpu_passthrough: Backing up LXC config file $config_file..."
    cp "$config_file" "$config_file.bak" 2>>"$PHOENIX_NVIDIA_LOG_FILE" || log_warn "Failed to backup $config_file"

    log_info "configure_lxc_gpu_passthrough: Configuring GPU passthrough for container $lxc_id (GPUs: $gpu_indices)"
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Configuring GPU passthrough for container $lxc_id..." >&2
    fi

    # Clear existing GPU-related configurations
    sed -i '/^lxc\.cgroup2\.devices\.allow:/d' "$config_file"
    sed -i '/^lxc\.cap\.drop:/d' "$config_file"
    sed -i '/^lxc\.mount\.entry: \/dev\/nvidia/d' "$config_file"
    sed -i '/^dev[0-9]*:/d' "$config_file"
    sed -i '/^swap:/d' "$config_file"
    sed -i '/^lxc\.autodev:/d' "$config_file"
    sed -i '/^lxc\.mount\.auto:/d' "$config_file"
    sed -i '/^lxc\.apparmor\.profile:/d' "$config_file"

    # Add GPU device mappings
    echo "dev0: /dev/dri/card0,gid=44" >> "$config_file"
    echo "dev1: /dev/dri/renderD128,gid=104" >> "$config_file"
    local dev_index=2
    IFS=',' read -ra INDICES <<< "$gpu_indices"
    for index in "${INDICES[@]}"; do
        if ! [[ "$index" =~ ^[0-9]+$ ]]; then
            log_error "configure_lxc_gpu_passthrough: Invalid GPU index: $index"
            return 1
        fi
        echo "dev$dev_index: /dev/nvidia$index" >> "$config_file"
        ((dev_index++))
    done

    # Add NVIDIA control devices
    for dev in "/dev/nvidia-caps/nvidia-cap1" "/dev/nvidia-caps/nvidia-cap2" "/dev/nvidiactl" "/dev/nvidia-uvm-tools" "/dev/nvidia-uvm"; do
        if [[ -e "$dev" ]]; then
            echo "dev$dev_index: $dev" >> "$config_file"
            ((dev_index++))
        else
            log_warn "configure_lxc_gpu_passthrough: Device $dev not found on host, skipping."
        fi
    done

    # Add LXC configuration settings
    echo "lxc.cgroup2.devices.allow: a" >> "$config_file"
    echo "lxc.cap.drop:" >> "$config_file"
    echo "lxc.apparmor.profile: unconfined" >> "$config_file"
    echo "swap: 512" >> "$config_file"
    echo "lxc.autodev: 1" >> "$config_file"
    echo "lxc.mount.auto: sys:rw" >> "$config_file"

    if grep -q "lxc.apparmor.profile: unconfined" "$config_file"; then
        log_info "configure_lxc_gpu_passthrough: Set lxc.apparmor.profile to unconfined for container $lxc_id."
    else
        log_error "configure_lxc_gpu_passthrough: Failed to set lxc.apparmor.profile in $config_file."
        return 1
    fi

    log_info "configure_lxc_gpu_passthrough: GPU passthrough configuration updated for container $lxc_id (GPUs: $gpu_indices)"
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "GPU passthrough configuration completed for container $lxc_id." >&2
    fi
    return 0
}

# --- Initialize Logging ---
log_info "phoenix_hypervisor_lxc_common_nvidia.sh: Library loaded successfully."