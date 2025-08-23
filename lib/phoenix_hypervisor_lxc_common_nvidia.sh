#!/bin/bash
# Common NVIDIA functions for LXC containers in Phoenix Hypervisor
# Provides functions for installing/checking NVIDIA drivers, toolkit, and verifying GPU access INSIDE containers
# Designed to be sourced by scripts that interact with containers (e.g., setup_drdevstral.sh, setup_drcuda.sh)
# Version: 1.9.7 (Added AppArmor bypass in detect_gpus_in_container, improved Docker GPU verification)

# --- Enhanced Sourcing of Dependencies ---
if ! declare -f log_info > /dev/null 2>&1; then
    if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
        source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh
    elif [[ -f "/usr/local/bin/phoenix_hypervisor_common.sh" ]]; then
        source /usr/local/bin/phoenix_hypervisor_common.sh
        echo "[WARN] phoenix_hypervisor_lxc_common_nvidia.sh: Sourced common functions from /usr/local/bin/. Prefer /usr/local/lib/phoenix_hypervisor/." >&2
    else
        echo "[ERROR] phoenix_hypervisor_lxc_common_nvidia.sh: Required function 'log_info' not found and common functions file could not be sourced." >&2
        echo "[ERROR] phoenix_hypervisor_lxc_common_nvidia.sh: Please ensure phoenix_hypervisor_common.sh is sourced before sourcing this file." >&2
        return 1
    fi
fi

# --- NVIDIA Functions for LXC Containers ---

# --- Install NVIDIA Driver in Container via Runfile ---
install_nvidia_driver_in_container_via_runfile() {
    local lxc_id="$1"
    local driver_version="${2:-${NVIDIA_DRIVER_VERSION:-580.76.05}}"
    local runfile_url="${3:-${NVIDIA_RUNFILE_URL:-https://us.download.nvidia.com/XFree86/Linux-x86_64/580.76.05/NVIDIA-Linux-x86_64-580.76.05.run}}"
    local runfile_name="NVIDIA-Linux-x86_64-${driver_version}.run"

    if [[ -z "$lxc_id" ]]; then
        log_error "install_nvidia_driver_in_container_via_runfile: Missing lxc_id"
        return 1
    fi

    log_info "install_nvidia_driver_in_container_via_runfile: Installing NVIDIA driver $driver_version in container $lxc_id using runfile..."
    echo "Installing NVIDIA driver $driver_version in container $lxc_id... This may take a few minutes."

    local check_installed_cmd="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if command -v nvidia-smi >/dev/null 2>&1; then
    installed_version=\$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null | head -n 1)
    if [[ \"\$installed_version\" == \"$driver_version\" ]]; then
        echo '[SUCCESS] NVIDIA driver $driver_version already installed and verified in container $lxc_id.'
        exit 0
    else
        echo '[INFO] NVIDIA driver found (version \$installed_version), but $driver_version is required. Proceeding with installation.'
    fi
else
    echo '[INFO] NVIDIA driver not found. Proceeding with installation.'
fi
exit 1
"
    if pct exec "$lxc_id" -- bash -c "$check_installed_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_info "install_nvidia_driver_in_container_via_runfile: NVIDIA driver $driver_version already correctly installed in container $lxc_id."
        return 0
    fi

    log_info "install_nvidia_driver_in_container_via_runfile: Installing prerequisites in container $lxc_id..."
    local install_prereqs_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
echo '[INFO] Updating package lists...'
apt-get update -y --fix-missing
echo '[INFO] Installing build tools and dependencies...'
apt-get install -y g++ freeglut3-dev build-essential libx11-dev libxmu-dev libxi-dev libglu1-mesa-dev libfreeimage-dev libglfw3-dev wget git pciutils build-essential cmake curl libcurl4-openssl-dev
echo '[SUCCESS] Prerequisites installed.'
"
    if ! pct exec "$lxc_id" -- bash -c "$install_prereqs_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_error "install_nvidia_driver_in_container_via_runfile: Failed to install prerequisites in container $lxc_id."
        return 1
    fi

    log_info "install_nvidia_driver_in_container_via_runfile: Downloading driver runfile ($runfile_name) in container $lxc_id from $runfile_url..."
    local download_cmd="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
echo '[INFO] Downloading $runfile_name...'
if ! wget --quiet '$runfile_url' -O '$runfile_name'; then
    echo '[ERROR] Failed to download $runfile_name from $runfile_url'
    exit 1
fi
echo '[SUCCESS] Downloaded $runfile_name.'
"
    if ! pct exec "$lxc_id" -- bash -c "$download_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_error "install_nvidia_driver_in_container_via_runfile: Failed to download runfile in container $lxc_id."
        return 1
    fi

    log_info "install_nvidia_driver_in_container_via_runfile: Running installer ($runfile_name) in container $lxc_id with --no-kernel-module..."
    local install_runfile_cmd="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
echo '[INFO] Making $runfile_name executable...'
chmod +x '$runfile_name'
echo '[INFO] Running $runfile_name installer with --no-kernel-module...'
./'$runfile_name' --silent --no-kernel-module --accept-license 2>&1 | grep -E '(ERROR|WARNING|Installing|complete)' || true
if [[ -f '/usr/bin/nvidia-smi' ]]; then
    echo '[INFO] Installer reported completion. Verifying...'
else
    echo '[ERROR] Installer did not place nvidia-smi in expected location.'
    exit 1
fi
"
    if ! pct exec "$lxc_id" -- bash -c "$install_runfile_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_error "install_nvidia_driver_in_container_via_runfile: Failed to run installer in container $lxc_id."
        pct exec "$lxc_id" -- bash -c "rm -f '$runfile_name'" 2>/dev/null || true
        return 1
    fi

    log_info "install_nvidia_driver_in_container_via_runfile: Cleaning up runfile in container $lxc_id..."
    if ! pct exec "$lxc_id" -- bash -c "rm -f '$runfile_name'" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_warn "install_nvidia_driver_in_container_via_runfile: Failed to clean up runfile in container $lxc_id. Continuing."
    fi

    log_info "install_nvidia_driver_in_container_via_runfile: Verifying driver installation in container $lxc_id..."
    local verify_cmd="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
echo '[INFO] Checking for nvidia-smi...'
if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo '[ERROR] nvidia-smi command not found after installation.'
    exit 1
fi
echo '[INFO] Running nvidia-smi...'
nvidia_smi_out=\$(nvidia-smi 2>&1) || { echo \"[ERROR] nvidia-smi command failed: \$nvidia_smi_out\"; exit 1; }
echo \"[INFO] nvidia-smi output: \$nvidia_smi_out\"
driver_version_out=\$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null | head -n 1)
if [[ \"\$driver_version_out\" == \"$driver_version\" ]]; then
    echo '[SUCCESS] NVIDIA driver $driver_version installed and verified successfully in container $lxc_id.'
    exit 0
else
    echo '[ERROR] Driver version mismatch. Expected $driver_version, got \$driver_version_out.'
    exit 1
fi
"
    if pct exec "$lxc_id" -- bash -c "$verify_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_info "install_nvidia_driver_in_container_via_runfile: NVIDIA driver $driver_version installed and verified successfully in container $lxc_id."
        echo "NVIDIA driver $driver_version installation completed for container $lxc_id."
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

    log_info "install_cuda_toolkit_12_8_in_container: Installing CUDA Toolkit 12.8 in container $lxc_id..."
    echo "Installing CUDA Toolkit 12.8 in container $lxc_id... This may take a few minutes."

    # --- MODIFIED CHECK INSTALLED CMD ---
    # Source the persistent env script if it exists for accurate check
    local check_installed_cmd="
set -e
export LC_ALL=C.UTF-8 LANG=C.UTF-8
# Source the persistent CUDA environment if it exists
if [[ -f /etc/profile.d/cuda.sh ]]; then
    source /etc/profile.d/cuda.sh
    echo '[INFO] Sourced existing /etc/profile.d/cuda.sh'
fi
# Ensure PATH includes CUDA bin for this check session
export PATH=/usr/local/cuda-12.8/bin:\$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.8/lib64:\$LD_LIBRARY_PATH
if command -v nvcc >/dev/null 2>&1; then
    installed_version=\$(nvcc --version | grep 'release' | awk '{print \$5}' | sed 's/,//')
    if [[ \"\$installed_version\" == \"12.8\" ]]; then
        echo '[SUCCESS] CUDA Toolkit 12.8 already installed and verified (nvcc version \$installed_version) in container $lxc_id.'
        exit 0
    else
        echo '[INFO] nvcc found (version \$installed_version), but 12.8 is required. Proceeding with installation.'
    fi
else
    echo '[INFO] CUDA Toolkit (nvcc) not found. Proceeding with installation.'
fi
exit 1
"
    if pct exec "$lxc_id" -- bash -c "$check_installed_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_info "install_cuda_toolkit_12_8_in_container: CUDA Toolkit 12.8 already correctly installed in container $lxc_id."
        return 0
    fi
    # --- END MODIFIED CHECK ---

    log_info "install_cuda_toolkit_12_8_in_container: Ensuring build tools and locale are present in container $lxc_id..."
    local install_prereqs_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8 LANG=C.UTF-8
echo '[INFO] Ensuring locale is set...'
apt-get update -y --fix-missing
apt-get install -y locales
locale-gen en_US.UTF-8 C.UTF-8
update-locale LC_ALL=C.UTF-8 LANG=C.UTF-8
echo '[INFO] Installing wget and gnupg for repository setup...'
apt-get install -y wget gnupg software-properties-common
echo '[SUCCESS] Prerequisites for CUDA repo ensured.'
"
    if ! pct exec "$lxc_id" -- bash -c "$install_prereqs_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_error "install_cuda_toolkit_12_8_in_container: Failed to install prerequisites in container $lxc_id."
        return 1
    fi

    log_info "install_cuda_toolkit_12_8_in_container: Adding CUDA repository and installing toolkit in container $lxc_id..."
    # --- MODIFIED CUDA INSTALL CMD ---
    # Ensure /etc/profile.d/cuda.sh is created as part of the installation process
    local cuda_install_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8 LANG=C.UTF-8
echo '[INFO] Installing CUDA keyring...'
wget -qO /tmp/cuda-keyring_1.1-1_all.deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i /tmp/cuda-keyring_1.1-1_all.deb || { echo '[ERROR] Failed to install CUDA keyring'; exit 1; }
rm -f /tmp/cuda-keyring_1.1-1_all.deb
echo 'deb [signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/   /' > /etc/apt/sources.list.d/cuda-ubuntu2404-x86_64.list
echo '[INFO] Updating package lists for CUDA...'
apt-get update -y --fix-missing > /tmp/apt-update.log 2>&1 || { echo '[ERROR] Failed to update package lists'; cat /tmp/apt-update.log; exit 1; }
if ! apt-cache policy cuda-toolkit-12-8 | grep -q 'Candidate'; then
    echo '[ERROR] No cuda-toolkit-12-8 package candidates available'
    cat /tmp/apt-update.log
    exit 1
fi
echo '[INFO] Installing CUDA Toolkit 12.8 and compiler...'
apt-get install -y cuda-toolkit-12-8 cuda-compiler-12-8 > /tmp/apt-install.log 2>&1 || { echo '[ERROR] Failed to install CUDA Toolkit'; cat /tmp/apt-install.log; exit 1; }
echo '[INFO] Creating persistent CUDA environment script (/etc/profile.d/cuda.sh)...'
mkdir -p /etc/profile.d
# Create the persistent environment script
cat > /etc/profile.d/cuda.sh << 'EOF_PROF'
#!/bin/bash
# Set up CUDA environment variables
# Added by Phoenix Hypervisor setup
export CUDA_HOME=/usr/local/cuda
export PATH=\$CUDA_HOME/bin:\$PATH
export LD_LIBRARY_PATH=\$CUDA_HOME/lib64:\$LD_LIBRARY_PATH
EOF_PROF
# Make it executable
chmod +x /etc/profile.d/cuda.sh
echo '[INFO] Sourcing the new environment script for immediate use...'
source /etc/profile.d/cuda.sh
echo '[INFO] Installation commands completed. Verifying...'
"
    # --- END MODIFIED CUDA INSTALL CMD ---
    if ! pct exec "$lxc_id" -- bash -c "$cuda_install_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_error "install_cuda_toolkit_12_8_in_container: Failed to add repository or install CUDA toolkit in container $lxc_id."
        return 1
    fi

    log_info "install_cuda_toolkit_12_8_in_container: Verifying CUDA Toolkit installation in container $lxc_id..."
    # --- MODIFIED VERIFY CMD ---
    # Prioritize sourcing the persistent env script for verification
    local verify_cmd="
set -e
export LC_ALL=C.UTF-8 LANG=C.UTF-8
# Source the persistent CUDA environment as the primary method
if [[ -f /etc/profile.d/cuda.sh ]]; then
    source /etc/profile.d/cuda.sh
    echo '[INFO] Sourced /etc/profile.d/cuda.sh for verification.'
else
    echo '[WARN] /etc/profile.d/cuda.sh not found during verification, setting environment variables manually...'
    export CUDA_HOME=/usr/local/cuda
    export PATH=\$CUDA_HOME/bin:\$PATH
    export LD_LIBRARY_PATH=\$CUDA_HOME/lib64:\$LD_LIBRARY_PATH
fi
echo '[INFO] Checking environment variables...'
echo \"PATH: \$PATH\"
echo \"LD_LIBRARY_PATH: \$LD_LIBRARY_PATH\"
echo '[INFO] Checking for nvcc...'
if ! command -v nvcc >/dev/null 2>&1; then
    echo '[ERROR] nvcc command not found after installation.'
    echo '[INFO] Checking if /usr/local/cuda-12.8/bin/nvcc exists...'
    if [[ -f /usr/local/cuda-12.8/bin/nvcc ]]; then
        echo '[INFO] nvcc found at /usr/local/cuda-12.8/bin/nvcc but not in PATH.'
    else
        echo '[INFO] nvcc not found at /usr/local/cuda-12.8/bin/nvcc.'
    fi
    exit 1
fi
echo '[INFO] Running nvcc --version...'
nvcc_version_out=\$(nvcc --version | grep 'release' | awk '{print \$5}' | sed 's/,//')
echo \"[INFO] nvcc version output: \$nvcc_version_out\"
if [[ \"\$nvcc_version_out\" == \"12.8\" ]]; then
    echo '[SUCCESS] CUDA Toolkit 12.8 installed and verified successfully in container $lxc_id.'
    exit 0
else
    echo '[ERROR] CUDA version mismatch. Expected 12.8, got \$nvcc_version_out.'
    exit 1
fi
"
    # --- END MODIFIED VERIFY CMD ---
    if pct exec "$lxc_id" -- bash -c "$verify_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_info "install_cuda_toolkit_12_8_in_container: CUDA Toolkit 12.8 installed and verified successfully in container $lxc_id."
        echo "CUDA Toolkit 12.8 installation completed for container $lxc_id."
        return 0
    else
        log_error "install_cuda_toolkit_12_8_in_container: Failed to verify CUDA Toolkit installation in container $lxc_id."
        return 1
    fi
}

# - Install Docker-ce in Container -
install_docker_ce_in_container() {
    local lxc_id="$1"
    if [[ -z "$lxc_id" ]]; then
        log_error "install_docker_ce_in_container: Missing lxc_id"
        return 1
    fi

    log_info "install_docker_ce_in_container: Installing Docker-ce in container $lxc_id..."
    echo "Installing Docker-ce in container $lxc_id... This may take a few minutes."

    local check_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if command -v docker >/dev/null 2>&1 && dpkg -l | grep -q docker-ce; then
    echo '[SUCCESS] Docker-ce already installed in container $lxc_id.'
    exit 0
fi
exit 1
"
    if pct exec "$lxc_id" -- bash -c "$check_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_info "install_docker_ce_in_container: Docker-ce already installed in container $lxc_id."
        return 0
    fi

    local install_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
echo '[INFO] Removing conflicting Docker packages...'
apt-get remove -y docker docker-engine docker.io containerd runc || true
apt-get update -y --fix-missing
apt-get install -y ca-certificates curl gnupg lsb-release
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo 'deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable' | tee /etc/apt/sources.list.d/docker.list > /dev/null
echo '[INFO] Updating package lists...'
apt-get update -y --fix-missing || { echo '[ERROR] Failed to update package lists'; exit 1; }
echo '[INFO] Installing Docker-ce...'
apt-get install -y docker-ce docker-ce-cli containerd.io || { echo '[ERROR] Failed to install Docker-ce'; exit 1; }
echo '[INFO] Checking if systemd is available...'
if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
    echo '[INFO] systemd detected, enabling and starting docker.service...'
    systemctl enable docker || { echo '[ERROR] Failed to enable docker.service'; exit 1; }
    systemctl start docker || { echo '[ERROR] Failed to start docker.service'; exit 1; }
else
    echo '[INFO] systemd not detected, starting dockerd manually...'
    if pgrep -x dockerd >/dev/null 2>&1; then
        echo '[INFO] Docker daemon already running.'
    else
        /usr/bin/dockerd -H unix:///var/run/docker.sock --containerd=/run/containerd/containerd.sock >/dev/null 2>&1 &
        sleep 5
        if pgrep -x dockerd >/dev/null 2>&1; then
            echo '[INFO] Docker daemon started successfully.'
        else
            echo '[ERROR] Failed to start Docker daemon manually.'
            exit 1
        fi
    fi
fi
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo '[SUCCESS] Docker-ce installed and running successfully in container $lxc_id.'
else
    echo '[ERROR] Docker-ce verification failed in container $lxc_id.'
    exit 1
fi
"
    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        log_info "install_docker_ce_in_container: Attempting Docker-ce installation (attempt $attempt/$max_attempts)..."
        if pct exec "$lxc_id" -- bash -c "$install_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
            log_info "install_docker_ce_in_container: Docker-ce installed successfully in container $lxc_id"
            echo "Docker-ce installation completed for container $lxc_id."
            return 0
        else
            log_warn "install_docker_ce_in_container: Docker-ce installation failed on attempt $attempt. Retrying in 10 seconds..."
            sleep 10
            ((attempt++))
        fi
    done

    log_error "install_docker_ce_in_container: Failed to install Docker-ce in container $lxc_id after $max_attempts attempts"
    return 1
}

# - Install NVIDIA Container Toolkit in Container -
install_nvidia_toolkit_in_container() {
    local lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        log_error "install_nvidia_toolkit_in_container: Missing lxc_id"
        return 1
    fi

    log_info "install_nvidia_toolkit_in_container: Installing NVIDIA Container Toolkit in container $lxc_id using CUDA Ubuntu 24.04 repository..."
    echo "Installing NVIDIA Container Toolkit in container $lxc_id... This may take a few minutes."

    local check_installed_cmd="
set -e
export LC_ALL=C.UTF-8 LANG=C.UTF-8
if command -v nvidia-ctk >/dev/null 2>&1 && dpkg -l | grep -q nvidia-container-toolkit; then
    echo '[SUCCESS] NVIDIA Container Toolkit already installed in container $lxc_id.'
    exit 0
fi
exit 1
"
    if pct exec "$lxc_id" -- bash -c "$check_installed_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_info "install_nvidia_toolkit_in_container: NVIDIA Container Toolkit already installed in container $lxc_id."
        return 0
    fi

    log_info "install_nvidia_toolkit_in_container: Ensuring prerequisites in container $lxc_id..."
    local install_prereqs_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8 LANG=C.UTF-8
echo '[INFO] Updating package lists...'
apt-get update -y --fix-missing
echo '[INFO] Installing prerequisites for NVIDIA Container Toolkit...'
apt-get install -y curl gnupg ca-certificates
echo '[SUCCESS] Prerequisites installed.'
"
    if ! pct exec "$lxc_id" -- bash -c "$install_prereqs_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_error "install_nvidia_toolkit_in_container: Failed to install prerequisites in container $lxc_id."
        return 1
    fi

    log_info "install_nvidia_toolkit_in_container: Using existing NVIDIA CUDA repository for Ubuntu 24.04 in container $lxc_id..."
    local install_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8 LANG=C.UTF-8
echo '[INFO] Ensuring NVIDIA CUDA repository is configured...'
if [ ! -f /etc/apt/sources.list.d/cuda-ubuntu2404-x86_64.list ]; then
    mkdir -p /etc/apt/keyrings
    wget -qO /tmp/cuda-keyring_1.1-1_all.deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
    dpkg -i /tmp/cuda-keyring_1.1-1_all.deb || { echo '[ERROR] Failed to install CUDA keyring'; exit 1; }
    rm -f /tmp/cuda-keyring_1.1-1_all.deb
    echo 'deb [signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/ /' > /etc/apt/sources.list.d/cuda-ubuntu2404-x86_64.list
fi
echo '[INFO] Updating package lists...'
apt-get update -y --fix-missing > /tmp/apt-update.log 2>&1 || { echo '[ERROR] Failed to update package lists'; cat /tmp/apt-update.log; exit 1; }
echo '[INFO] Installing NVIDIA Container Toolkit...'
apt-get install -y nvidia-container-toolkit > /tmp/apt-install.log 2>&1 || { echo '[ERROR] Failed to install NVIDIA Container Toolkit'; cat /tmp/apt-install.log; exit 1; }
echo '[INFO] Verifying NVIDIA Container Toolkit installation...'
if command -v nvidia-ctk >/dev/null 2>&1; then
    echo '[SUCCESS] NVIDIA Container Toolkit installed successfully in container $lxc_id.'
else
    echo '[ERROR] NVIDIA Container Toolkit verification failed in container $lxc_id.'
    exit 1
fi
"
    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        log_info "install_nvidia_toolkit_in_container: Attempting NVIDIA Container Toolkit installation (attempt $attempt/$max_attempts)..."
        if pct exec "$lxc_id" -- bash -c "$install_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
            log_info "install_nvidia_toolkit_in_container: NVIDIA Container Toolkit installed successfully in container $lxc_id."
            echo "NVIDIA Container Toolkit installation completed for container $lxc_id."
            return 0
        else
            log_warn "install_nvidia_toolkit_in_container: NVIDIA Container Toolkit installation failed on attempt $attempt. Retrying in 10 seconds..."
            sleep 10
            ((attempt++))
        fi
    done

    log_error "install_nvidia_toolkit_in_container: Failed to install NVIDIA Container Toolkit in container $lxc_id after $max_attempts attempts."
    return 1
}

# - Install NVIDIA Userland Driver in Container -
install_nvidia_userland_in_container() {
    local lxc_id="$1"
    local driver_version="$2"

    if [[ -z "$lxc_id" ]] || [[ -z "$driver_version" ]]; then
        log_error "install_nvidia_userland_in_container: Missing lxc_id or driver_version"
        return 1
    fi

    log_warn "install_nvidia_userland_in_container: This function installs driver via package manager. For project goal (runfile), consider using install_nvidia_driver_in_container_via_runfile."
    log_info "install_nvidia_userland_in_container: Installing NVIDIA userland driver (version $driver_version) in container $lxc_id..."
    echo "Installing NVIDIA driver in container $lxc_id... This may take a few minutes."

    local check_cmd="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if dpkg -l | grep -q nvidia-driver-${driver_version%%.*}; then
    echo '[SUCCESS] NVIDIA driver $driver_version already installed in container $lxc_id.'
    exit 0
fi
exit 1
"
    if pct exec "$lxc_id" -- bash -c "$check_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_info "install_nvidia_userland_in_container: NVIDIA driver $driver_version already installed in container $lxc_id."
        return 0
    fi

    local install_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
echo '[INFO] Installing NVIDIA driver ($driver_version)... This may take a few minutes.'
apt-get install -y --no-install-recommends nvidia-driver-${driver_version%%.*} || { echo '[ERROR] Failed to install NVIDIA driver'; exit 1; }
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=driver_version --format=csv,noheader | grep -q \"$driver_version\"; then
    echo '[SUCCESS] NVIDIA driver installed successfully in container $lxc_id.'
else
    echo '[ERROR] NVIDIA driver verification failed in container $lxc_id.'
    exit 1
fi
"
    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        log_info "install_nvidia_userland_in_container: Attempting NVIDIA driver installation (attempt $attempt/$max_attempts)..."
        if pct exec "$lxc_id" -- bash -c "$install_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
            log_info "install_nvidia_userland_in_container: NVIDIA userland driver installed successfully in container $lxc_id"
            echo "NVIDIA driver installation completed for container $lxc_id."
            return 0
        else
            log_warn "install_nvidia_userland_in_container: NVIDIA driver installation failed on attempt $attempt. Retrying in 10 seconds..."
            sleep 10
            ((attempt++))
        fi
    done

    log_error "install_nvidia_userland_in_container: Failed to install NVIDIA driver in container $lxc_id after $max_attempts attempts"
    return 1
}

# - Configure NVIDIA Runtime for Docker -
configure_docker_nvidia_runtime() {
    local lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        log_error "configure_docker_nvidia_runtime: Missing lxc_id"
        return 1
    fi

    log_info "configure_docker_nvidia_runtime: Configuring NVIDIA runtime for Docker in container $lxc_id..."
    echo "Configuring NVIDIA runtime for Docker in container $lxc_id... This may take a moment."

    local config_cmd="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if ! command -v nvidia-ctk >/dev/null 2>&1; then
    echo '[ERROR] NVIDIA Container Toolkit not installed'
    exit 1
fi
if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
    echo '[ERROR] NVIDIA driver not available or not functioning'
    exit 1
fi
if docker info --format '{{.Runtimes}}' | grep -q 'nvidia'; then
    echo '[INFO] NVIDIA runtime already configured.'
    exit 0
fi
echo '[INFO] Configuring NVIDIA runtime for Docker...'
nvidia-ctk runtime configure --runtime=docker > /tmp/docker-nvidia-config.log 2>&1 || { echo '[ERROR] Failed to configure NVIDIA runtime'; cat /tmp/docker-nvidia-config.log; exit 1; }
echo '[INFO] Ensuring no-cgroups = true in NVIDIA Container Toolkit config...'
if [ ! -f /etc/nvidia-container-runtime/config.toml ]; then
    echo '[ERROR] NVIDIA Container Toolkit config file not found at /etc/nvidia-container-runtime/config.toml'
    exit 1
fi
if grep -q 'no-cgroups = true' /etc/nvidia-container-runtime/config.toml; then
    echo '[INFO] NVIDIA Container Toolkit already configured with no-cgroups = true.'
else
    echo '[nvidia-container-runtime]' > /tmp/config.toml
    echo 'no-cgroups = true' >> /tmp/config.toml
    cat /etc/nvidia-container-runtime/config.toml >> /tmp/config.toml
    mv /tmp/config.toml /etc/nvidia-container-runtime/config.toml || { echo '[ERROR] Failed to update NVIDIA Container Toolkit config'; exit 1; }
fi
echo '[INFO] Verifying no-cgroups setting...'
if grep -q 'no-cgroups = true' /etc/nvidia-container-runtime/config.toml; then
    echo '[SUCCESS] no-cgroups = true verified in NVIDIA Container Toolkit config.'
else
    echo '[ERROR] Failed to verify no-cgroups = true in NVIDIA Container Toolkit config.'
    cat /etc/nvidia-container-runtime/config.toml
    exit 1
fi
echo '[INFO] Updating Docker daemon configuration...'
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
echo '[INFO] Validating Docker daemon configuration syntax...'
if command -v jq >/dev/null 2>&1 || apt-get install -y jq; then
    if ! jq . /etc/docker/daemon.json >/tmp/daemon-json-validate.log 2>&1; then
        echo '[ERROR] Invalid Docker daemon.json syntax.'
        cat /tmp/daemon-json-validate.log
        exit 1
    else
        echo '[INFO] Docker daemon.json syntax is valid.'
    fi
else
    echo '[WARN] jq not found and could not be installed, skipping daemon.json syntax validation.'
fi
echo '[INFO] Checking for systemd availability...'
if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
    echo '[INFO] Systemd available, using systemctl to restart Docker...'
    systemctl daemon-reload > /tmp/systemd-daemon-reload.log 2>&1 || { echo '[ERROR] Failed to reload systemd daemon'; cat /tmp/systemd-daemon-reload.log; exit 1; }
    systemctl restart docker > /tmp/docker-restart.log 2>&1 || { echo '[ERROR] Failed to restart Docker service'; cat /tmp/docker-restart.log; exit 1; }
    if systemctl is-active --quiet docker; then
        echo '[SUCCESS] Docker service restarted successfully via systemd.'
    else
        echo '[ERROR] Docker service is not active after restart.'
        exit 1
    fi
else
    echo '[WARN] Systemd not available, attempting manual Docker restart...'
    if command -v dockerd >/dev/null 2>&1; then
        echo '[INFO] Stopping dockerd manually if running...'
        pkill -x dockerd || { echo '[INFO] No running dockerd process found.'; }
        sleep 2
        if pgrep -x dockerd >/dev/null 2>&1; then
            echo '[ERROR] Failed to stop dockerd manually.'
            exit 1
        fi
        echo '[INFO] Starting dockerd manually...'
        /usr/bin/dockerd -H unix:///var/run/docker.sock --containerd=/run/containerd/containerd.sock > /tmp/docker-manual-restart.log 2>&1 &
        sleep 5
        if pgrep -x dockerd >/dev/null 2>&1; then
            echo '[SUCCESS] Docker daemon restarted manually.'
        else
            echo '[ERROR] Failed to restart dockerd manually.'
            cat /tmp/docker-manual-restart.log
            exit 1
        fi
    else
        echo '[ERROR] dockerd not found and systemd not available.'
        exit 1
    fi
fi
if docker info --format '{{.Runtimes}}' | grep -q 'nvidia'; then
    echo '[SUCCESS] NVIDIA runtime configured successfully.'
else
    echo '[ERROR] NVIDIA runtime verification failed.'
    exit 1
fi
"
    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        log_info "configure_docker_nvidia_runtime: Attempting NVIDIA runtime configuration (attempt $attempt/$max_attempts)..."
        if pct exec "$lxc_id" -- bash -c "$config_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
            log_info "configure_docker_nvidia_runtime: NVIDIA runtime configured successfully in container $lxc_id"
            echo "NVIDIA runtime configuration completed for container $lxc_id."
            return 0
        else
            log_warn "configure_docker_nvidia_runtime: NVIDIA runtime configuration failed on attempt $attempt. Retrying in 10 seconds..."
            sleep 10
            ((attempt++))
        fi
    done

    log_error "configure_docker_nvidia_runtime: Failed to configure NVIDIA runtime in container $lxc_id after $max_attempts attempts"
    return 1
}

# - Build Docker Image in Container -
build_docker_image_in_container() {
    local lxc_id="$1"
    local dockerfile_path="$2"
    local image_tag="$3"
    if [[ -z "$lxc_id" ]] || [[ -z "$dockerfile_path" ]] || [[ -z "$image_tag" ]]; then
        log_error "build_docker_image_in_container: Missing lxc_id, dockerfile_path, or image_tag"
        return 1
    fi

    log_info "build_docker_image_in_container: Building Docker image $image_tag in container $lxc_id from $dockerfile_path..."
    echo "Building Docker image $image_tag in container $lxc_id... This may take a few minutes."

    local check_cmd="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if docker images -q $image_tag | grep -q .; then
    echo '[SUCCESS] Docker image $image_tag already exists in container $lxc_id.'
    exit 0
fi
exit 1
"
    if pct exec "$lxc_id" -- bash -c "$check_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_info "build_docker_image_in_container: Docker image $image_tag already exists in container $lxc_id."
        return 0
    fi

    local build_cmd="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if ! command -v docker >/dev/null 2>&1; then
    echo '[ERROR] Docker not installed in container $lxc_id.'
    exit 1
fi
echo '[INFO] Building Docker image $image_tag...'
cd \"\$(dirname $dockerfile_path)\" || { echo '[ERROR] Failed to change directory'; exit 1; }
docker build -t $image_tag -f $dockerfile_path . || { echo '[ERROR] Failed to build Docker image $image_tag'; exit 1; }
if docker images -q $image_tag | grep -q .; then
    echo '[SUCCESS] Docker image $image_tag built successfully in container $lxc_id.'
else
    echo '[ERROR] Docker image $image_tag verification failed in container $lxc_id.'
    exit 1
fi
"
    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        log_info "build_docker_image_in_container: Attempting Docker image build (attempt $attempt/$max_attempts)..."
        if pct exec "$lxc_id" -- bash -c "$build_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
            log_info "build_docker_image_in_container: Docker image $image_tag built successfully in container $lxc_id"
            echo "Docker image build completed for $image_tag in container $lxc_id."
            return 0
        else
            log_warn "build_docker_image_in_container: Docker image build failed on attempt $attempt. Retrying in 10 seconds..."
            sleep 10
            ((attempt++))
        fi
    done

    log_error "build_docker_image_in_container: Failed to build Docker image $image_tag in container $lxc_id after $max_attempts attempts"
    return 1
}

# - Detect GPUs Inside Container -
detect_gpus_in_container() {
    local lxc_id="$1"
    if [[ -z "$lxc_id" ]]; then
        log_error "detect_gpus_in_container: Container ID cannot be empty"
        return 1
    fi

    log_info "detect_gpus_in_container: Detecting GPUs in container $lxc_id..."
    echo "Checking GPU access in container $lxc_id..."

    local check_cmd="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if command -v nvidia-smi >/dev/null 2>&1; then
    if nvidia-smi >/dev/null 2>&1; then
        echo '[SUCCESS] GPUs detected in container $lxc_id.'
        nvidia-smi --query-gpu=count,driver_version --format=csv,noheader | head -n 1
    else
        echo '[ERROR] nvidia-smi command failed inside container $lxc_id.'
        exit 1
    fi
else
    echo '[ERROR] nvidia-smi not found inside container $lxc_id.'
    exit 1
fi
"
    local result
    result=$(pct exec "$lxc_id" -- bash -c "$check_cmd" 2>&1)
    local exit_code=$?

    log_info "detect_gpus_in_container: output: $result"
    log_info "detect_gpus_in_container: exit code: $exit_code"

    if [[ $exit_code -eq 0 ]]; then
        log_info "detect_gpus_in_container: GPUs detected successfully in container $lxc_id"
        local docker_check="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
echo '[INFO] Checking cgroup version...'
if [ -d /sys/fs/cgroup/cgroup.controllers ]; then
    echo '[INFO] Cgroups v2 detected.'
else
    echo '[INFO] Cgroups v1 detected.'
fi
echo '[INFO] Checking NVIDIA device permissions...'
ls -l /dev/nvidia* /dev/dri/* 2>/dev/null || echo '[WARN] No NVIDIA or DRI devices found.'
if ! command -v docker >/dev/null 2>&1; then
    echo '[ERROR] Docker not installed in container $lxc_id.'
    exit 1
fi
if ! docker info --format '{{.Runtimes}}' | grep -q 'nvidia'; then
    echo '[ERROR] NVIDIA runtime not configured in Docker.'
    exit 1
fi
echo '[INFO] Verifying NVIDIA Container Toolkit configuration...'
if grep -q 'no-cgroups = true' /etc/nvidia-container-runtime/config.toml; then
    echo '[INFO] NVIDIA Container Toolkit configured with no-cgroups = true.'
else
    echo '[WARN] NVIDIA Container Toolkit not configured with no-cgroups = true.'
fi
echo '[INFO] Checking AppArmor status inside container...'
if command -v aa-status >/dev/null 2>&1; then
    if aa-status --quiet; then
        echo '[INFO] AppArmor is active.'
    else
        echo '[WARN] AppArmor is not active.'
    fi
else
    echo '[WARN] aa-status command not found.'
fi
echo '[INFO] Testing Docker GPU access with nvidia-smi...'
if ! docker pull nvidia/cuda:12.8.0-base-ubuntu24.04 >/tmp/docker-pull.log 2>&1; then
    echo '[WARN] Failed to pull nvidia/cuda:12.8.0-base-ubuntu24.04, attempting fallback image nvidia/cuda:12.8.0-base-ubuntu22.04...'
    if ! docker pull nvidia/cuda:12.8.0-base-ubuntu22.04 >/tmp/docker-pull-fallback.log 2>&1; then
        echo '[ERROR] Failed to pull fallback image nvidia/cuda:12.8.0-base-ubuntu22.04'
        cat /tmp/docker-pull-fallback.log
        exit 1
    fi
fi
echo '[INFO] Attempting Docker GPU test with AppArmor bypass...'
if docker run --rm --gpus all --runtime=nvidia --security-opt apparmor=unconfined nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi >/tmp/docker-gpu-test.log 2>&1; then
    echo '[SUCCESS] Docker GPU access verified in container $lxc_id.'
    exit 0
else
    echo '[ERROR] Docker GPU access verification failed in container $lxc_id.'
    cat /tmp/docker-gpu-test.log
    echo '[INFO] Retrying without AppArmor bypass...'
    if docker run --rm --gpus all --runtime=nvidia nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi >/tmp/docker-gpu-test-no-apparmor.log 2>&1; then
        echo '[SUCCESS] Docker GPU access verified without AppArmor bypass in container $lxc_id.'
        exit 0
    else
        echo '[ERROR] Docker GPU access verification failed without AppArmor bypass in container $lxc_id.'
        cat /tmp/docker-gpu-test-no-apparmor.log
        echo '[INFO] Retrying with privileged mode...'
        if docker run --rm --gpus all --runtime=nvidia --privileged nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi >/tmp/docker-gpu-test-privileged.log 2>&1; then
            echo '[SUCCESS] Docker GPU access verified in privileged mode in container $lxc_id.'
            exit 0
        else
            echo '[ERROR] Docker GPU access verification failed in privileged mode in container $lxc_id.'
            cat /tmp/docker-gpu-test-privileged.log
            echo '[INFO] Retrying with fallback image nvidia/cuda:12.8.0-base-ubuntu22.04...'
            if docker run --rm --gpus all --runtime=nvidia --privileged nvidia/cuda:12.8.0-base-ubuntu22.04 nvidia-smi >/tmp/docker-gpu-test-fallback.log 2>&1; then
                echo '[SUCCESS] Docker GPU access verified with fallback image in container $lxc_id.'
                exit 0
            else
                echo '[ERROR] Docker GPU access verification failed with fallback image in container $lxc_id.'
                cat /tmp/docker-gpu-test-fallback.log
                exit 1
            fi
        fi
    fi
fi
"
        if pct exec "$lxc_id" -- bash -c "$docker_check" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
            log_info "detect_gpus_in_container: Docker GPU access verified successfully in container $lxc_id"
            return 0
        else
            log_warn "detect_gpus_in_container: Docker GPU access verification failed in container $lxc_id"
            return 1
        fi
    else
        log_warn "detect_gpus_in_container: GPU detection failed in container $lxc_id. Output: $result"
        return 1
    fi
}

# - Verify LXC GPU Access Inside Container -
verify_lxc_gpu_access_in_container() {
    local lxc_id="$1"
    local gpu_indices="${2:-}" # Optional, currently unused in this function

    if [[ -z "$lxc_id" ]]; then
        log_error "verify_lxc_gpu_access_in_container: Container ID cannot be empty"
        return 1
    fi

    log_info "verify_lxc_gpu_access_in_container: Verifying GPU access/passthrough for container $lxc_id..."

    if detect_gpus_in_container "$lxc_id"; then
        log_info "verify_lxc_gpu_access_in_container: GPU access verified successfully for container $lxc_id."
        return 0
    else
        log_error "verify_lxc_gpu_access_in_container: Failed to verify GPU access for container $lxc_id."
        return 1
    fi
}

# - Configures GPU passthrough by modifying the LXC config file directly -
configure_lxc_gpu_passthrough() {
    local lxc_id="$1"
    local gpu_indices="$2"

    if [[ -z "$lxc_id" ]] || [[ -z "$gpu_indices" ]]; then
        log_error "configure_lxc_gpu_passthrough: Missing lxc_id or gpu_indices"
        return 1
    fi

    local config_file="/etc/pve/lxc/$lxc_id.conf"
    if [[ ! -f "$config_file" ]]; then
        log_error "configure_lxc_gpu_passthrough: LXC config file not found: $config_file. Container $lxc_id may have been deleted."
        return 1
    fi

    log_info "DEBUG: Entering configure_lxc_gpu_passthrough for container $lxc_id (GPUs: $gpu_indices)"

    if ! touch "$config_file" 2>/dev/null; then
        log_warn "configure_lxc_gpu_passthrough: No write permissions for $config_file. Continuing as root may not require explicit permissions."
    fi

    sed -i '/^lxc\.cgroup2\.devices\.allow: c 195/d' "$config_file"
    sed -i '/^lxc\.cgroup2\.devices\.allow: c 235/d' "$config_file"
    sed -i '/^lxc\.cgroup2\.devices\.allow: c 236/d' "$config_file"
    sed -i '/^lxc\.cgroup2\.devices\.allow: c 237/d' "$config_file"
    sed -i '/^lxc\.cap\.drop:/d' "$config_file"
    sed -i '/^lxc\.mount\.entry: \/dev\/nvidia/d' "$config_file"
    sed -i '/^dev[0-9]*:/d' "$config_file"
    sed -i '/^swap: /d' "$config_file"
    sed -i '/^lxc\.autodev:/d' "$config_file"
    sed -i '/^lxc\.mount\.auto:/d' "$config_file"
    sed -i '/^lxc\.aa_profile:/d' "$config_file"
    sed -i '/^lxc\.apparmor\.profile:/d' "$config_file"

    echo "dev0: /dev/dri/card0,gid=44" >> "$config_file"
    echo "dev1: /dev/dri/renderD128,gid=104" >> "$config_file"
    local dev_index=2
    IFS=',' read -ra INDICES <<< "$gpu_indices"
    for index in "${INDICES[@]}"; do
        if ! [[ "$index" =~ ^[0-9]+$ ]]; then
            log_error "configure_lxc_gpu_passthrough: Invalid GPU index: $index (must be numeric)"
            return 1
        fi
        echo "dev$dev_index: /dev/nvidia$index" >> "$config_file"
        ((dev_index++))
    done

    if [[ -e "/dev/nvidia-caps/nvidia-cap1" ]]; then
        echo "dev$dev_index: /dev/nvidia-caps/nvidia-cap1" >> "$config_file"
        ((dev_index++))
    else
        log_warn "configure_lxc_gpu_passthrough: Device /dev/nvidia-caps/nvidia-cap1 not found on host, skipping."
    fi

    if [[ -e "/dev/nvidia-caps/nvidia-cap2" ]]; then
        echo "dev$dev_index: /dev/nvidia-caps/nvidia-cap2" >> "$config_file"
        ((dev_index++))
    else
        log_warn "configure_lxc_gpu_passthrough: Device /dev/nvidia-caps/nvidia-cap2 not found on host, skipping."
    fi

    if [[ -e "/dev/nvidiactl" ]]; then
        echo "dev$dev_index: /dev/nvidiactl" >> "$config_file"
        ((dev_index++))
    else
        log_error "configure_lxc_gpu_passthrough: Critical device /dev/nvidiactl not found on host!"
        return 1
    fi

    if [[ -e "/dev/nvidia-uvm-tools" ]]; then
        echo "dev$dev_index: /dev/nvidia-uvm-tools" >> "$config_file"
        ((dev_index++))
    else
        log_warn "configure_lxc_gpu_passthrough: Device /dev/nvidia-uvm-tools not found on host, skipping."
    fi

    if [[ -e "/dev/nvidia-uvm" ]]; then
        echo "dev$dev_index: /dev/nvidia-uvm" >> "$config_file"
        ((dev_index++))
    else
        log_warn "configure_lxc_gpu_passthrough: Device /dev/nvidia-uvm not found on host, skipping."
    fi

    echo "lxc.cgroup2.devices.allow: a" >> "$config_file"
    echo "lxc.cap.drop:" >> "$config_file"
    echo "lxc.apparmor.profile: unconfined" >> "$config_file"
    echo "swap: 512" >> "$config_file"
    echo "lxc.autodev: 1" >> "$config_file"
    echo "lxc.mount.auto: sys:rw" >> "$config_file"

    if grep -q "lxc.apparmor.profile: unconfined" "$config_file"; then
        log_info "configure_lxc_gpu_passthrough: Successfully set lxc.apparmor.profile to unconfined for container $lxc_id."
    else
        log_error "configure_lxc_gpu_passthrough: Failed to set lxc.apparmor.profile in $config_file."
        return 1
    fi

    if command -v aa-status >/dev/null 2>&1; then
        log_info "configure_lxc_gpu_passthrough: Checking AppArmor status..."
        if aa-status --quiet; then
            log_info "configure_lxc_gpu_passthrough: AppArmor service is active."
        else
            log_warn "configure_lxc_gpu_passthrough: AppArmor service is not active. This may cause container startup issues."
        fi
    else
        log_warn "configure_lxc_gpu_passthrough: aa-status command not found. Cannot verify AppArmor status."
    fi

    log_info "configure_lxc_gpu_passthrough: Checking container $lxc_id initialization status..."
    local container_status
    container_status=$(pct status "$lxc_id" 2>/dev/null | grep -oP 'status: \K\w+' || echo "unknown")
    log_info "configure_lxc_gpu_passthrough: Container $lxc_id status: $container_status"
    if [[ "$container_status" != "stopped" && "$container_status" != "running" ]]; then
        log_warn "configure_lxc_gpu_passthrough: Container $lxc_id is not in a valid state (status: $container_status). Monitor socket issues may persist."
    fi

    if command -v lxc-info >/dev/null 2>&1; then
        log_info "configure_lxc_gpu_passthrough: Fetching LXC monitor info for container $lxc_id..."
        lxc_info=$(lxc-info -n "$lxc_id" 2>&1)
        log_info "configure_lxc_gpu_passthrough: lxc-info output: $lxc_info"
    else
        log_warn "configure_lxc_gpu_passthrough: lxc-info command not found. Cannot verify LXC monitor status."
    fi

    log_info "configure_lxc_gpu_passthrough: GPU passthrough configuration updated for container $lxc_id (GPUs: $gpu_indices)"
    return 0
}

# Signal that this library has been loaded
export PHOENIX_HYPERVISOR_LXC_NVIDIA_LOADED=1

log_info "phoenix_hypervisor_lxc_common_nvidia.sh: Library loaded successfully."