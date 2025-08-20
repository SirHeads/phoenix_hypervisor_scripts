#!/bin/bash
# Common NVIDIA functions for LXC containers in Phoenix Hypervisor
# Provides functions for installing/checking NVIDIA drivers, toolkit, and verifying GPU access INSIDE containers
# Designed to be sourced by scripts that interact with containers (e.g., setup_drdevstral.sh, setup_drcuda.sh)
# Version: 1.9.1 (Updated for Project Requirements: Driver 580.76.05 Runfile, CUDA 12.8 Repo)
# Author: Assistant

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

# --- NEW FUNCTION: Install NVIDIA Driver in Container via Runfile ---
# Installs the NVIDIA driver inside an LXC container using the .run file method.
# This is the required method for containers as it uses --no-kernel-module.
# Args:
#   $1: LXC ID
#   $2: (Optional) Driver version. Defaults to NVIDIA_DRIVER_VERSION from config or 580.76.05.
#   $3: (Optional) Runfile URL. Defaults to NVIDIA_RUNFILE_URL from config or the project URL for 580.76.05.
install_nvidia_driver_in_container_via_runfile() {
    local lxc_id="$1"
    # Allow overriding version/URL from config/script args, fallback to project defaults
    local driver_version="${2:-${NVIDIA_DRIVER_VERSION:-580.76.05}}"
    local runfile_url="${3:-${NVIDIA_RUNFILE_URL:-https://us.download.nvidia.com/XFree86/Linux-x86_64/580.76.05/NVIDIA-Linux-x86_64-580.76.05.run}}"
    local runfile_name="NVIDIA-Linux-x86_64-${driver_version}.run"

    if [[ -z "$lxc_id" ]]; then
        log_error "install_nvidia_driver_in_container_via_runfile: Missing lxc_id"
        return 1
    fi

    log_info "install_nvidia_driver_in_container_via_runfile: Installing NVIDIA driver $driver_version in container $lxc_id using runfile..."
    echo "Installing NVIDIA driver $driver_version in container $lxc_id... This may take a few minutes."

    # --- 1. Check if already installed ---
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
exit 1 # Force install if not already correct version
"
    if pct exec "$lxc_id" -- bash -c "$check_installed_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_info "install_nvidia_driver_in_container_via_runfile: NVIDIA driver $driver_version already correctly installed in container $lxc_id."
        return 0
    fi
    # --- End Check ---

    # --- 2. Install Prerequisites inside container ---
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
    # --- End Prerequisites ---

    # --- 3. Download the runfile inside the container ---
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
    # --- End Download ---

    # --- 4. Run the installer inside the container with --no-kernel-module ---
    log_info "install_nvidia_driver_in_container_via_runfile: Running installer ($runfile_name) in container $lxc_id with --no-kernel-module..."
    local install_runfile_cmd="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
echo '[INFO] Making $runfile_name executable...'
chmod +x '$runfile_name'
echo '[INFO] Running $runfile_name installer with --no-kernel-module...'
# Use yes '' to automate prompts, pipe stderr to stdout to capture all output
./'$runfile_name' --silent --no-kernel-module --accept-license 2>&1 | grep -E '(ERROR|WARNING|Installing|complete)' || true
# Check if installer process completed (it exits 0 even if it skips kernel module part)
if [[ -f '/usr/bin/nvidia-smi' ]]; then
    echo '[INFO] Installer reported completion. Verifying...'
else
    echo '[ERROR] Installer did not place nvidia-smi in expected location.'
    exit 1
fi
"
    # Note: The NVIDIA runfile installer can be finicky with output and exit codes in containers.
    # We focus on the presence of nvidia-smi post-install as a key indicator.
    if ! pct exec "$lxc_id" -- bash -c "$install_runfile_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_error "install_nvidia_driver_in_container_via_runfile: Failed to run installer in container $lxc_id."
        # Attempt cleanup of runfile on failure
        pct exec "$lxc_id" -- bash -c "rm -f '$runfile_name'" 2>/dev/null || true
        return 1
    fi
    # --- End Run Installer ---

    # --- 5. Cleanup runfile ---
    log_info "install_nvidia_driver_in_container_via_runfile: Cleaning up runfile in container $lxc_id..."
    if ! pct exec "$lxc_id" -- bash -c "rm -f '$runfile_name'" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_warn "install_nvidia_driver_in_container_via_runfile: Failed to clean up runfile in container $lxc_id. Continuing."
    fi
    # --- End Cleanup ---

    # --- 6. Verify Installation ---
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
    # --- End Verify ---
}
# --- END NEW FUNCTION ---


# --- NEW FUNCTION: Install CUDA Toolkit 12.8 in Container ---
# Installs the CUDA Development Toolkit 12.8 inside an LXC container using the official repository method.
# Args:
#   $1: LXC ID
install_cuda_toolkit_12_8_in_container() {
    local lxc_id="$1"

    if [[ -z "$lxc_id" ]]; then
        log_error "install_cuda_toolkit_12_8_in_container: Missing lxc_id"
        return 1
    fi

    log_info "install_cuda_toolkit_12_8_in_container: Installing CUDA Toolkit 12.8 in container $lxc_id..."
    echo "Installing CUDA Toolkit 12.8 in container $lxc_id... This may take a few minutes."

    # --- 1. Check if already installed ---
    local check_installed_cmd="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
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
exit 1 # Force install if not already correct version
"
    if pct exec "$lxc_id" -- bash -c "$check_installed_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_info "install_cuda_toolkit_12_8_in_container: CUDA Toolkit 12.8 already correctly installed in container $lxc_id."
        return 0
    fi
    # --- End Check ---

    # --- 2. Install Prerequisites (if not done by driver install) ---
    # Note: Some overlap with driver install prereqs, but ensures they are present.
    log_info "install_cuda_toolkit_12_8_in_container: Ensuring build tools are present in container $lxc_id..."
    local install_prereqs_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
echo '[INFO] Updating package lists...'
apt-get update -y --fix-missing
echo '[INFO] Installing wget and gnupg for repository setup...'
apt-get install -y wget gnupg software-properties-common
echo '[SUCCESS] Prerequisites for CUDA repo ensured.'
"
    if ! pct exec "$lxc_id" -- bash -c "$install_prereqs_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_error "install_cuda_toolkit_12_8_in_container: Failed to install prerequisites in container $lxc_id."
        return 1
    fi
    # --- End Prerequisites ---

    # --- 3. Add CUDA Repository and Install Toolkit ---
    log_info "install_cuda_toolkit_12_8_in_container: Adding CUDA repository and installing toolkit in container $lxc_id..."
    local cuda_install_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8

# Determine Ubuntu codename (assuming 24.04/24.10)
CODENAME=\$(lsb_release -cs 2>/dev/null || echo 'noble') # Fallback to noble if lsb_release fails

echo '[INFO] Determined Ubuntu codename: \$CODENAME'

echo '[INFO] Installing CUDA keyring...'
wget -qO /tmp/cuda-keyring_1.0-1_all.deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i /tmp/cuda-keyring_1.0-1_all.deb
rm -f /tmp/cuda-keyring_1.0-1_all.deb

echo '[INFO] Updating package lists for CUDA...'
apt-get update -y --fix-missing

echo '[INFO] Installing CUDA Toolkit 12.8...'
apt-get install -y cuda-toolkit-12-8

echo '[INFO] Installation commands completed. Verifying...'
"
    if ! pct exec "$lxc_id" -- bash -c "$cuda_install_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_error "install_cuda_toolkit_12_8_in_container: Failed to add repository or install CUDA toolkit in container $lxc_id."
        return 1
    fi
    # --- End Repo Add/Install ---

    # --- 4. Verify Installation ---
    log_info "install_cuda_toolkit_12_8_in_container: Verifying CUDA Toolkit installation in container $lxc_id..."
    local verify_cmd="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
echo '[INFO] Checking for nvcc...'
if ! command -v nvcc >/dev/null 2>&1; then
    echo '[ERROR] nvcc command not found after installation.'
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
    if pct exec "$lxc_id" -- bash -c "$verify_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_info "install_cuda_toolkit_12_8_in_container: CUDA Toolkit 12.8 installed and verified successfully in container $lxc_id."
        echo "CUDA Toolkit 12.8 installation completed for container $lxc_id."
        return 0
    else
        log_error "install_cuda_toolkit_12_8_in_container: Failed to verify CUDA Toolkit installation in container $lxc_id."
        return 1
    fi
    # --- End Verify ---
}
# --- END NEW FUNCTION ---


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
curl -fsSL https://download.docker.com/linux/ubuntu/gpg   | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
# Use 'noble' codename for Ubuntu 24.04/24.10 compatibility
echo 'deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable' | tee /etc/apt/sources.list.d/docker.list > /dev/null
echo '[INFO] Updating package lists...'
apt-get update -y --fix-missing || { echo '[ERROR] Failed to update package lists'; exit 1; }
echo '[INFO] Installing Docker-ce...'
apt-get install -y docker-ce docker-ce-cli containerd.io || { echo '[ERROR] Failed to install Docker-ce'; exit 1; }
systemctl enable docker
systemctl start docker
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo '[SUCCESS] Docker-ce installed successfully in container $lxc_id.'
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

# - Setup NVIDIA Repository and Install CUDA Toolkit in Container -
setup_nvidia_repo_in_container() {
    local lxc_id="$1"
    local nvidia_repo_url="$2" # This argument is less relevant now, as CUDA version is fixed to 12.8
    if [[ -z "$lxc_id" ]] || [[ -z "$nvidia_repo_url" ]]; then
        log_error "setup_nvidia_repo_in_container: Missing lxc_id or nvidia_repo_url"
        return 1
    fi

    log_warn "setup_nvidia_repo_in_container: This function is deprecated for the project goal (CUDA 12.8). Consider using install_cuda_toolkit_12_8_in_container."
    log_info "setup_nvidia_repo_in_container: Setting up NVIDIA CUDA repository and installing CUDA $CUDA_VERSION in container $lxc_id..."
    echo "Setting up NVIDIA CUDA repository and installing CUDA $CUDA_VERSION in container $lxc_id... This may take a moment."

    # Use the existing logic, but note it installs $CUDA_VERSION, not necessarily 12.8
    # unless $CUDA_VERSION is set correctly elsewhere.
    local repo_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
echo '[INFO] Setting up locale...'
apt-get update -y --fix-missing
apt-get install -y locales
locale-gen en_US.UTF-8
update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
mkdir -p /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/nvidia-container-toolkit-keyring.gpg ]]; then
    echo '[INFO] Downloading NVIDIA Container Toolkit keyring...'
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey   | gpg --dearmor -o /etc/apt/keyrings/nvidia-container-toolkit-keyring.gpg || { echo '[ERROR] Failed to download NVIDIA Container Toolkit keyring'; exit 1; }
fi
if [[ ! -f /etc/apt/sources.list.d/nvidia-container-toolkit.list ]]; then
    echo '[INFO] Setting up NVIDIA Container Toolkit repository...'
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list   | \
        sed 's#deb https://#deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
fi
if [[ ! -f /etc/apt/keyrings/cuda-archive-keyring.gpg ]]; then
    echo '[INFO] Downloading CUDA keyring...'
    wget -qO /etc/apt/keyrings/cuda-archive-keyring.gpg ${nvidia_repo_url}cuda-archive-keyring.gpg || { echo '[ERROR] Failed to download CUDA keyring'; exit 1; }
fi
if [[ ! -f /etc/apt/sources.list.d/cuda.list ]]; then
    echo '[INFO] Setting up CUDA repository...'
    echo 'deb [signed-by=/etc/apt/keyrings/cuda-archive-keyring.gpg] ${nvidia_repo_url} /' | tee /etc/apt/sources.list.d/cuda.list > /dev/null
fi
echo '[INFO] Updating package lists... This may take a few minutes.'
apt-get update -y --fix-missing || { echo '[ERROR] Failed to update package lists'; exit 1; }
echo '[INFO] Installing CUDA toolkit $CUDA_VERSION and compatibility package $CUDA_COMPAT_PACKAGE...'
apt-get install -y --no-install-recommends cuda-toolkit-$CUDA_VERSION $CUDA_COMPAT_PACKAGE || { echo '[ERROR] Failed to install CUDA toolkit'; exit 1; }
if command -v nvcc >/dev/null 2>&1 && nvcc --version | grep -q \"$CUDA_VERSION\"; then
    echo '[SUCCESS] CUDA toolkit $CUDA_VERSION installed successfully in container $lxc_id.'
else
    echo '[ERROR] CUDA toolkit verification failed in container $lxc_id.'
    exit 1
fi
"
    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        log_info "setup_nvidia_repo_in_container: Attempting NVIDIA repository and CUDA toolkit setup (attempt $attempt/$max_attempts)..."
        if pct exec "$lxc_id" -- bash -c "$repo_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
            log_info "setup_nvidia_repo_in_container: NVIDIA CUDA and Container Toolkit repositories and CUDA $CUDA_VERSION setup completed for container $lxc_id"
            echo "NVIDIA repositories and CUDA toolkit setup completed for container $lxc_id."
            return 0
        else
            log_warn "setup_nvidia_repo_in_container: NVIDIA repository and CUDA toolkit setup failed on attempt $attempt. Retrying in 10 seconds..."
            sleep 10
            ((attempt++))
        fi
    done

    log_error "setup_nvidia_repo_in_container: Failed to set up NVIDIA repositories and CUDA toolkit in container $lxc_id after $max_attempts attempts"
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

# - Install NVIDIA Container Toolkit in Container -
install_nvidia_toolkit_in_container() {
    local lxc_id="$1"
    if [[ -z "$lxc_id" ]]; then
        log_error "install_nvidia_toolkit_in_container: Missing lxc_id"
        return 1
    fi

    log_info "install_nvidia_toolkit_in_container: Installing NVIDIA Container Toolkit in container $lxc_id..."
    echo "Installing NVIDIA Container Toolkit in container $lxc_id... This may take a few minutes."

    local check_cmd="
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if dpkg -l | grep -q nvidia-container-toolkit; then
    echo '[SUCCESS] NVIDIA Container Toolkit already installed in container $lxc_id.'
    exit 0
fi
exit 1
"
    if pct exec "$lxc_id" -- bash -c "$check_cmd" 2>&1 | tee -a "${HYPERVISOR_LOGFILE:-/dev/null}"; then
        log_info "install_nvidia_toolkit_in_container: NVIDIA Container Toolkit already installed in container $lxc_id."
        return 0
    fi

    local install_cmd="
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
echo '[INFO] Installing NVIDIA Container Toolkit... This may take a few minutes.'
# Ensure keyring is present for nvidia-docker2 package
if [[ ! -f /etc/apt/keyrings/nvidia-container-toolkit-keyring.gpg ]]; then
    echo '[INFO] Downloading NVIDIA Container Toolkit keyring...'
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /etc/apt/keyrings/nvidia-container-toolkit-keyring.gpg || { echo '[ERROR] Failed to download NVIDIA Container Toolkit keyring'; exit 1; }
fi
if [[ ! -f /etc/apt/sources.list.d/nvidia-container-toolkit.list ]]; then
    echo '[INFO] Setting up NVIDIA Container Toolkit repository...'
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
fi
apt-get update -y --fix-missing
apt-get install -y --no-install-recommends nvidia-container-toolkit nvidia-docker2 || { echo '[ERROR] Failed to install NVIDIA Container Toolkit'; exit 1; }
if command -v nvidia-ctk >/dev/null 2>&1; then
    echo '[INFO] Configuring NVIDIA runtime for Docker...'
    nvidia-ctk runtime configure --runtime=docker || { echo '[ERROR] Failed to configure NVIDIA runtime'; exit 1; }
    systemctl restart docker || { echo '[ERROR] Failed to restart Docker'; exit 1; }
    echo '[SUCCESS] NVIDIA Container Toolkit installed and configured successfully in container $lxc_id.'
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
            log_info "install_nvidia_toolkit_in_container: NVIDIA Container Toolkit installed successfully in container $lxc_id"
            echo "NVIDIA Container Toolkit installation completed for container $lxc_id."
            return 0
        else
            log_warn "install_nvidia_toolkit_in_container: NVIDIA Container Toolkit installation failed on attempt $attempt. Retrying in 10 seconds..."
            sleep 10
            ((attempt++))
        fi
    done

    log_error "install_nvidia_toolkit_in_container: Failed to install NVIDIA Container Toolkit in container $lxc_id after $max_attempts attempts"
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
if docker info --format '{{.Runtimes}}' | grep -q 'nvidia'; then
    echo '[INFO] NVIDIA runtime already configured.'
    exit 0
fi
echo '[INFO] Configuring NVIDIA runtime for Docker...'
nvidia-ctk runtime configure --runtime=docker || { echo '[ERROR] Failed to configure NVIDIA runtime'; exit 1; }
echo '[INFO] Restarting Docker service...'
systemctl restart docker || { echo '[ERROR] Failed to restart Docker'; exit 1; }
sleep 5
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
            log_info "configure_docker_nvidia_runtime: NVIDIA runtime configured successfully for container $lxc_id"
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
# Change to the directory containing the Dockerfile
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
        nvidia-smi --query-gpu=count,driver_version,cuda_version --format=csv,noheader | head -n 1
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
if ! command -v docker >/dev/null 2>&1; then
    echo '[ERROR] Docker not installed in container $lxc_id.'
    exit 1
fi
if ! docker info --format '{{.Runtimes}}' | grep -q 'nvidia'; then
    echo '[ERROR] NVIDIA runtime not configured in Docker.'
    exit 1
fi
# Use a standard CUDA base image for testing
if docker run --rm --gpus all --runtime=nvidia nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
    echo '[SUCCESS] Docker GPU access verified in container $lxc_id.'
    exit 0
else
    echo '[ERROR] Docker GPU access verification failed in container $lxc_id.'
    exit 1
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
    local gpu_indices="$2" # This argument is not used in the current logic but kept for signature consistency

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
        log_error "configure_lxc_gpu_passthrough: LXC config file not found: $config_file"
        return 1
    fi

    log_info "configure_lxc_gpu_passthrough: Adding GPU passthrough entries to $config_file for GPUs: $gpu_indices"

    # --- Check write permissions ---
    if ! touch "$config_file" 2>/dev/null; then
        log_warn "configure_lxc_gpu_passthrough: No write permissions for $config_file. Attempting to proceed without chmod."
    else
        chmod u+w "$config_file" 2>/dev/null || log_warn "configure_lxc_gpu_passthrough: Failed to set write permissions on $config_file."
    fi

    # --- Cleanup existing GPU-related entries ---
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
    # --- End Cleanup ---

    # --- Add essential static devices ---
    echo "dev0: /dev/dri/card0,gid=44" >> "$config_file"
    echo "dev1: /dev/dri/renderD128,gid=104" >> "$config_file"
    local dev_index=2
    # --- End Static Devices ---

    # --- Add GPU-specific devices dynamically ---
    IFS=',' read -ra INDICES <<< "$gpu_indices"
    for index in "${INDICES[@]}"; do
        if ! [[ "$index" =~ ^[0-9]+$ ]]; then
            log_error "configure_lxc_gpu_passthrough: Invalid GPU index: $index (must be numeric)"
            return 1
        fi
        echo "dev$dev_index: /dev/nvidia$index" >> "$config_file"
        ((dev_index++))
    done

    # Add common NVIDIA capability devices if they exist on the host
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
    fi

    if [[ -e "/dev/nvidia-modeset" ]]; then
        echo "dev$dev_index: /dev/nvidia-modeset" >> "$config_file"
        ((dev_index++))
        log_info "configure_lxc_gpu_passthrough: Added /dev/nvidia-modeset to container config."
    else
        log_warn "configure_lxc_gpu_passthrough: Device /dev/nvidia-modeset not found on host, skipping passthrough for this device."
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

    # --- Add final LXC configuration options ---
    echo "lxc.cgroup2.devices.allow: a" >> "$config_file"
    echo "lxc.cap.drop:" >> "$config_file" # Clearing cap.drop for full access, as done in original
    echo "lxc.aa_profile: unconfined" >> "$config_file" # Ensure unconfined AppArmor profile
    echo "swap: 512" >> "$config_file"
    echo "lxc.autodev: 1" >> "$config_file"
    echo "lxc.mount.auto: sys:rw" >> "$config_file"
    # --- End Final Options ---

    if [[ -w "$config_file" ]]; then
        chmod u-w "$config_file" 2>/dev/null || log_warn "configure_lxc_gpu_passthrough: Failed to remove write permissions on $config_file."
    fi

    log_info "configure_lxc_gpu_passthrough: GPU passthrough configuration updated for container $lxc_id (GPUs: $gpu_indices)"
    return 0
}


# Signal that this library has been loaded
export PHOENIX_HYPERVISOR_LXC_NVIDIA_LOADED=1

log_info "phoenix_hypervisor_lxc_common_nvidia.sh: Library loaded successfully."
