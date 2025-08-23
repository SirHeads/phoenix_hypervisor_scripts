#!/usr/bin/env bash

# phoenix_hypervisor_lxc_common_docker.sh
#
# Common functions for Docker operations inside LXC containers.
# This script is intended to be sourced by other Phoenix Hypervisor scripts.
# Requires: pct, bash, standard Unix tools
# Assumes: phoenix_hypervisor_common.sh is sourced for logging (fallbacks included)
# Assumes: phoenix_hypervisor_lxc_common_systemd.sh is sourced for systemd operations
# Version: 1.1.4 (Modified to resolve ZFS setup issues in LXC containers by defaulting to overlay2)
#          - Detect LXC environment and skip complex ZFS setup.
#          - Default to 'overlay2' storage driver inside LXC for better compatibility.
#          - Made ZFS modprobe command more robust.
#          - Added explicit 'no-cgroups = true' configuration for NVIDIA Container Runtime.
#          - Updated GPU verification to use '--security-opt apparmor=unconfined' by default.

# --- Docker Installation ---

# Install Docker Community Edition inside an LXC container
# Usage: install_docker_ce_in_container <container_id>
install_docker_ce_in_container() {
    local lxc_id="$1"

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    fi

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    # Use log_warn if available, otherwise fallback
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" >&2; }
    fi

    if [[ -z "$lxc_id" ]]; then
        "$error_func" "install_docker_ce_in_container: Missing lxc_id"
        return 1
    fi

    "$log_func" "install_docker_ce_in_container: Installing Docker-ce in container $lxc_id..."
    echo "Installing Docker-ce in container $lxc_id... This may take a few minutes."

    local check_cmd="set -e
    export DEBIAN_FRONTEND=noninteractive
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    if command -v docker >/dev/null 2>&1 && dpkg -l | grep -q docker-ce; then
        echo '[SUCCESS] Docker-ce already installed in container $lxc_id.'
        exit 0
    fi
    exit 1"

    # Check if Docker is already installed
    local log_file="${HYPERVISOR_LOGFILE:-/dev/null}"
    if pct exec "$lxc_id" -- bash -c "$check_cmd" 2>/dev/null; then
        "$log_func" "install_docker_ce_in_container: Docker-ce already installed in container $lxc_id."
        return 0
    fi

    # Get container's Ubuntu codename
    local codename
    codename=$(pct exec "$lxc_id" -- bash -c "lsb_release -cs" 2>/dev/null)
    if [[ $? -ne 0 || -z "$codename" ]]; then
        "$error_func" "install_docker_ce_in_container: Failed to retrieve codename for container $lxc_id."
        return 1
    fi
    "$log_func" "install_docker_ce_in_container: Detected container codename: $codename"
    if [[ "$codename" == "plucky" ]]; then
        "$warn_func" "install_docker_ce_in_container: Ubuntu 25.04 (plucky) detected. Checking Docker compatibility..."
    fi

    local install_cmd="set -e
    export DEBIAN_FRONTEND=noninteractive
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    echo '[INFO] Removing conflicting Docker packages...'
    apt-get remove -y docker docker-engine docker.io containerd runc || true
    apt-get update -y --fix-missing > /tmp/docker-apt-update.log 2>&1 || { echo '[ERROR] Failed to update package lists'; cat /tmp/docker-apt-update.log; exit 1; }
    apt-get install -y ca-certificates curl gnupg lsb-release > /tmp/docker-apt-prereqs.log 2>&1 || { echo '[ERROR] Failed to install prerequisites'; cat /tmp/docker-apt-prereqs.log; exit 1; }
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg   | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo 'deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu   $codename stable' | tee /etc/apt/sources.list.d/docker.list > /dev/null
    if ! test -f /etc/apt/sources.list.d/docker.list; then
        echo '[ERROR] Failed to create Docker repository file'
        exit 1
    fi
    if ! grep -q '$codename stable' /etc/apt/sources.list.d/docker.list; then
        echo '[ERROR] Docker repository file does not contain expected codename $codename'
        exit 1
    fi
    echo '[INFO] Updating package lists...'
    apt-get update -y --fix-missing > /tmp/docker-apt-update.log 2>&1 || { echo '[ERROR] Failed to update package lists'; cat /tmp/docker-apt-update.log; exit 1; }
    if ! apt-cache policy docker-ce | grep -q 'Candidate'; then
        echo '[ERROR] No docker-ce package candidates available'
        cat /tmp/docker-apt-update.log
        exit 1
    fi
    echo '[INFO] Installing Docker-ce...'
    apt-get install -y docker-ce docker-ce-cli containerd.io > /tmp/docker-apt-install.log 2>&1 || { echo '[ERROR] Failed to install Docker-ce'; cat /tmp/docker-apt-install.log; exit 1; }
    if ! dpkg -l | grep -q docker-ce; then
        echo '[ERROR] docker-ce package not installed'
        exit 1
    fi
    if ! test -f /usr/bin/docker; then
        echo '[ERROR] Docker binary not found at /usr/bin/docker'
        exit 1
    fi
    echo '[INFO] Verifying Docker installation...'
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        echo '[SUCCESS] Docker-ce installed successfully in container $lxc_id.'
    else
        echo '[ERROR] Docker-ce verification failed in container $lxc_id.'
        exit 1
    fi"

    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "install_docker_ce_in_container: Attempting Docker-ce installation (attempt $attempt/$max_attempts)..."
        if pct exec "$lxc_id" -- bash -c "$install_cmd" 2>&1 | tee -a "$log_file"; then
            # Use systemd script functions for service management - Ensure they are available
            if ! declare -F enable_systemd_service_in_container >/dev/null 2>&1 || ! declare -F start_systemd_service_in_container >/dev/null 2>&1; then
                "$error_func" "install_docker_ce_in_container: Systemd functions not available. Ensure phoenix_hypervisor_lxc_common_systemd.sh is sourced."
                return 1
            fi

            # --- CORRECTED/IMPROVED SERVICE MANAGEMENT ---
            "$log_func" "install_docker_ce_in_container: Docker packages installed. Checking/ensuring Docker service state..."

            # Use pct_exec_with_retry if available, otherwise direct exec
            local exec_func="pct exec"
            if declare -F pct_exec_with_retry >/dev/null 2>&1; then
                exec_func="pct_exec_with_retry"
            fi

            # Check if Docker service is enabled
            local is_enabled_check="
            if systemctl is-enabled --quiet docker 2>/dev/null; then
                echo '[INFO] Docker service is already enabled.'
                exit 0
            else
                echo '[INFO] Docker service is not enabled.'
                exit 1
            fi
            "
            if $exec_func "$lxc_id" -- bash -c "$is_enabled_check"; then
                # Already enabled, do nothing
                : # No-op
            else
                # Not enabled, enable it
                "$log_func" "install_docker_ce_in_container: Enabling Docker service..."
                if enable_systemd_service_in_container "$lxc_id" "docker"; then
                     "$log_func" "install_docker_ce_in_container: Docker service enabled successfully."
                else
                     "$warn_func" "install_docker_ce_in_container: Failed to enable Docker service. It might already be enabled or there was an error."
                     # Don't fail hard here, just warn
                fi
            fi

            # Check if Docker service is active (running)
            local is_active_check="
            if systemctl is-active --quiet docker 2>/dev/null; then
                echo '[INFO] Docker service is already active (running).'
                exit 0
            else
                echo '[INFO] Docker service is not active.'
                exit 1
            fi
            "
            if $exec_func "$lxc_id" -- bash -c "$is_active_check"; then
                # Already active, do nothing
                : # No-op
            else
                # Not active, start it
                "$log_func" "install_docker_ce_in_container: Starting Docker service..."
                # Use retry_command if available for starting the service
                local start_cmd_func="start_systemd_service_in_container"
                if declare -F retry_command >/dev/null 2>&1; then
                    # Wrap start command in retry_command if available
                    # Define a simple wrapper function for retry_command
                    local start_wrapper="
                    start_systemd_service_in_container \"$lxc_id\" \"docker\"
                    "
                    # Use retry_command with the wrapper
                    if retry_command 3 5 bash -c "$start_wrapper"; then
                        "$log_func" "install_docker_ce_in_container: Docker service started successfully."
                    else
                        "$error_func" "install_docker_ce_in_container: Failed to start Docker service after retries."
                        return 1
                    fi
                else
                    # Fallback to direct call if retry_command not available
                    if start_systemd_service_in_container "$lxc_id" "docker"; then
                        "$log_func" "install_docker_ce_in_container: Docker service started successfully."
                    else
                        "$error_func" "install_docker_ce_in_container: Failed to start Docker service."
                        return 1
                    fi
                fi
            fi
            # --- END CORRECTED SERVICE MANAGEMENT ---

            "$log_func" "install_docker_ce_in_container: Docker-ce installed and service managed successfully in container $lxc_id."
            echo "Docker-ce installation completed for container $lxc_id."
            return 0
        else
            "$warn_func" "install_docker_ce_in_container: Docker-ce installation failed on attempt $attempt. Retrying in 10 seconds..."
            sleep 10
            ((attempt++))
        fi
    done

    "$error_func" "install_docker_ce_in_container: Failed to install Docker-ce in container $lxc_id after $max_attempts attempts."
    return 1
}

# --- Docker Image Management ---

# Build a Docker image inside an LXC container from a Dockerfile path
# Usage: build_docker_image_in_container <container_id> <dockerfile_path> <image_tag>
build_docker_image_in_container() {
    local lxc_id="$1"
    local dockerfile_path="$2"
    local image_tag="$3"

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    fi

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    # Use log_warn if available, otherwise fallback
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" >&2; }
    fi

    if [[ -z "$lxc_id" ]] || [[ -z "$dockerfile_path" ]] || [[ -z "$image_tag" ]]; then
        "$error_func" "build_docker_image_in_container: Missing lxc_id, dockerfile_path, or image_tag"
        return 1
    fi

    "$log_func" "build_docker_image_in_container: Building Docker image $image_tag in container $lxc_id from $dockerfile_path..."
    echo "Building Docker image $image_tag in container $lxc_id... This may take a few minutes."

    local check_cmd="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    if ! command -v docker >/dev/null 2>&1; then
        echo '[ERROR] Docker not installed in container $lxc_id.'
        exit 1
    fi
    if ! test -f '$dockerfile_path'; then
        echo '[ERROR] Dockerfile not found at $dockerfile_path.'
        exit 1
    fi
    if ! test -r '$dockerfile_path'; then
        echo '[ERROR] Dockerfile at $dockerfile_path is not readable.'
        exit 1
    fi
    if docker images -q $image_tag | grep -q .; then
        echo '[SUCCESS] Docker image $image_tag already exists in container $lxc_id.'
        exit 0
    fi
    exit 1"

    local log_file="${HYPERVISOR_LOGFILE:-/dev/null}"
    if pct exec "$lxc_id" -- bash -c "$check_cmd" 2>&1 | tee -a "$log_file"; then
        "$log_func" "build_docker_image_in_container: Docker image $image_tag already exists in container $lxc_id."
        return 0
    fi

    local build_cmd="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    if ! command -v docker >/dev/null 2>&1; then
        echo '[ERROR] Docker not installed in container $lxc_id.'
        exit 1
    fi
    echo '[INFO] Building Docker image $image_tag...'
    cd \"\$(dirname $dockerfile_path)\" || { echo '[ERROR] Failed to change directory'; exit 1; }
    docker build -t $image_tag -f $dockerfile_path . > /tmp/docker-build-$image_tag.log 2>&1 || { echo '[ERROR] Failed to build Docker image $image_tag'; cat /tmp/docker-build-$image_tag.log; exit 1; }
    if docker images -q $image_tag | grep -q .; then
        echo '[SUCCESS] Docker image $image_tag built successfully in container $lxc_id.'
    else
        echo '[ERROR] Docker image $image_tag verification failed in container $lxc_id.'
        exit 1
    fi"

    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "build_docker_image_in_container: Attempting Docker image build (attempt $attempt/$max_attempts)..."
        if pct exec "$lxc_id" -- bash -c "$build_cmd" 2>&1 | tee -a "$log_file"; then
            "$log_func" "build_docker_image_in_container: Docker image $image_tag built successfully in container $lxc_id"
            echo "Docker image build completed for $image_tag in container $lxc_id."
            return 0
        else
            "$warn_func" "build_docker_image_in_container: Docker image build failed on attempt $attempt. Retrying in 10 seconds..."
            sleep 10
            ((attempt++))
        fi
    done

    "$error_func" "build_docker_image_in_container: Failed to build Docker image $image_tag in container $lxc_id after $max_attempts attempts"
    return 1
}

# --- Docker Runtime Configuration ---

# Configure the NVIDIA runtime for Docker inside an LXC container
# Usage: configure_docker_nvidia_runtime <container_id>
configure_docker_nvidia_runtime() {
    local lxc_id="$1"

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    fi

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    # Use log_warn if available, otherwise fallback
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" >&2; }
    fi

    if [[ -z "$lxc_id" ]]; then
        "$error_func" "configure_docker_nvidia_runtime: Missing lxc_id"
        return 1
    fi

    "$log_func" "configure_docker_nvidia_runtime: Configuring NVIDIA runtime for Docker in container $lxc_id..."
    echo "Configuring NVIDIA runtime for Docker in container $lxc_id... This may take a moment."

    # Use pct_exec_with_retry if available, otherwise direct exec
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    # Check container stability
    "$log_func" "configure_docker_nvidia_runtime: Checking container $lxc_id stability..."
    if ! pct status "$lxc_id" | grep -q "status: running"; then
        "$error_func" "configure_docker_nvidia_runtime: Container $lxc_id is not running. Check Proxmox LXC status."
        return 1
    fi

    # Check LXC cgroup configuration
    local config_file="/etc/pve/lxc/$lxc_id.conf"
    "$log_func" "configure_docker_nvidia_runtime: Checking cgroup settings in $config_file..."
    if ! grep -q "lxc.cgroup2.devices.allow: a" "$config_file"; then
        "$error_func" "configure_docker_nvidia_runtime: Missing lxc.cgroup2.devices.allow: a in $config_file."
        return 1
    fi
    if grep -q "no-cgroups = true" "$config_file"; then
        "$error_func" "configure_docker_nvidia_runtime: Invalid no-cgroups = true found in $config_file. Remove it."
        return 1
    fi
    if ! grep -q "features:.*nesting=1" "$config_file"; then
        "$warn_func" "configure_docker_nvidia_runtime: Missing 'features: nesting=1' in $config_file. Systemd and Docker may fail in unprivileged containers."
    fi
    if ! grep -q "lxc.init_cmd: /sbin/init" "$config_file"; then
        "$warn_func" "configure_docker_nvidia_runtime: Missing 'lxc.init_cmd: /sbin/init' in $config_file. Add it to ensure systemd works."
    fi
    if grep -q "unprivileged: 1" "$config_file"; then
        "$warn_func" "configure_docker_nvidia_runtime: Container $lxc_id is unprivileged. NVIDIA runtime may require privileged container for BPF operations."
    fi

    # Check /tmp writability
    "$log_func" "configure_docker_nvidia_runtime: Checking /tmp writability in container $lxc_id..."
    local tmp_check_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
echo '[INFO] Checking /tmp writability...' >/tmp/tmp-check.log
touch /tmp/tmp-check.log || { echo '[ERROR] Cannot write to /tmp'; exit 1; }
echo '[SUCCESS] /tmp is writable.' >>/tmp/tmp-check.log
"
    if ! "$exec_func" "$lxc_id" -- bash -c "$tmp_check_cmd"; then
        "$error_func" "configure_docker_nvidia_runtime: /tmp is not writable in container $lxc_id. Check /tmp permissions or mount settings."
        return 1
    fi

    # Install jq and dependencies
    "$log_func" "configure_docker_nvidia_runtime: Checking and installing jq in container $lxc_id..."
    local jq_install_cmd="set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
touch /tmp/jq-install.log || { echo '[ERROR] Cannot create /tmp/jq-install.log'; exit 1; }
echo '[INFO] Checking jq installation...' >/tmp/jq-install.log
if ! command -v jq >/dev/null 2>&1; then
    echo '[INFO] Installing jq...' >>/tmp/jq-install.log
    apt-get update >>/tmp/jq-install.log 2>&1 || { echo '[ERROR] Failed to update apt'; cat /tmp/jq-install.log; exit 1; }
    apt-get install -y jq >>/tmp/jq-install.log 2>&1 || { echo '[ERROR] Failed to install jq'; cat /tmp/jq-install.log; exit 1; }
    echo '[SUCCESS] jq installed.' >>/tmp/jq-install.log
else
    echo '[INFO] jq already installed.' >>/tmp/jq-install.log
fi
jq --version >>/tmp/jq-install.log 2>&1 || { echo '[ERROR] jq installed but not functional'; cat /tmp/jq-install.log; exit 1; }
echo '[SUCCESS] jq verified.' >>/tmp/jq-install.log
"
    if ! "$exec_func" "$lxc_id" -- bash -c "$jq_install_cmd"; then
        "$error_func" "configure_docker_nvidia_runtime: Failed to install or verify jq in container $lxc_id. Check /tmp/jq-install.log."
        return 1
    fi

    # --- MODIFIED ZFS LOGIC START ---
    # Detect if we are running inside an LXC container
    local in_lxc=false
    # Check if the container environment indicates LXC
    if "$exec_func" "$lxc_id" -- bash -c "[[ -f /run/systemd/container && \"\$(cat /run/systemd/container 2>/dev/null)\" == \"lxc\" ]]"; then
        in_lxc=true
    fi

    local storage_driver="overlay2" # Default fallback

    if [[ "$in_lxc" == true ]]; then
        "$log_func" "configure_docker_nvidia_runtime: Detected LXC environment for container $lxc_id. Skipping complex ZFS setup, defaulting to overlay2 storage driver."
        # Set the default storage driver for LXC
        storage_driver="overlay2"
         # Write the chosen driver to the temp file expected by subsequent steps
        if ! "$exec_func" "$lxc_id" -- bash -c "echo '$storage_driver' > /tmp/docker-storage-driver"; then
             "$error_func" "configure_docker_nvidia_runtime: Failed to write storage driver to /tmp/docker-storage-driver in LXC container $lxc_id."
             return 1
        fi
        # Skip the zfs_install_cmd execution block entirely for LXC
    else
        # --- EXISTING zfs_install_cmd logic for non-LXC environments ---
        "$log_func" "configure_docker_nvidia_runtime: Non-LXC environment detected for container $lxc_id. Proceeding with ZFS checks."
        # Install zfsutils-linux and configure ZFS
        "$log_func" "configure_docker_nvidia_runtime: Checking and installing zfsutils-linux in container $lxc_id..."
        local zfs_install_cmd="set -e
        export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        touch /tmp/zfs-install.log || { echo '[ERROR] Cannot create /tmp/zfs-install.log'; exit 1; }
        echo '[INFO] Checking zfsutils-linux installation...' >/tmp/zfs-install.log
        if ! command -v zfs >/dev/null 2>&1; then
            echo '[INFO] Checking for ZFS kernel module...' >>/tmp/zfs-install.log
            # Make modprobe more robust to prevent hanging in restricted environments like LXC
            modprobe zfs >>/tmp/zfs-install.log 2>&1 || echo '[WARN] Failed to load ZFS kernel module, may be restricted in container' >>/tmp/zfs-install.log
            echo '[INFO] Ensuring /dev/zfs and /proc/self/mounts...' >>/tmp/zfs-install.log
            udevadm trigger >>/tmp/zfs-install.log 2>&1 || echo '[WARN] udevadm trigger failed, may be restricted' >>/tmp/zfs-install.log
            mount -t proc proc /proc >>/tmp/zfs-install.log 2>&1 || echo '[WARN] Failed to mount /proc, may already be mounted' >>/tmp/zfs-install.log
            echo '[INFO] Updating package lists...' >>/tmp/zfs-install.log
            apt-get update >>/tmp/zfs-install.log 2>&1 || { echo '[ERROR] Failed to update apt'; cat /tmp/zfs-install.log; exit 1; }
            echo '[INFO] Installing zfsutils-linux...' >>/tmp/zfs-install.log
            apt-get install -y zfsutils-linux >>/tmp/zfs-install.log 2>&1 || { echo '[ERROR] Failed to install zfsutils-linux'; cat /tmp/zfs-install.log; exit 1; }
            echo '[SUCCESS] zfsutils-linux installed.' >>/tmp/zfs-install.log
        else
            echo '[INFO] zfsutils-linux already installed.' >>/tmp/zfs-install.log
        fi
        echo '[INFO] Checking ZFS functionality...' >>/tmp/zfs-install.log
        if ! zfs list >/dev/null 2>&1; then
            echo '[WARN] ZFS list failed, check dataset visibility and permissions' >>/tmp/zfs-install.log
            zfs list -o name,mountpoint >>/tmp/zfs-install.log 2>&1
            echo '[WARN] Falling back to vfs storage driver' >>/tmp/zfs-install.log
            echo 'vfs' > /tmp/docker-storage-driver
        else
            echo '[INFO] ZFS available, using zfs storage driver' >>/tmp/zfs-install.log
            echo 'zfs' > /tmp/docker-storage-driver
        fi
        "
        if ! "$exec_func" "$lxc_id" -- bash -c "$zfs_install_cmd"; then
            "$warn_func" "configure_docker_nvidia_runtime: Failed to install or configure zfsutils-linux in container $lxc_id. Falling back to vfs storage driver."
            local storage_driver="vfs"
            if ! "$exec_func" "$lxc_id" -- bash -c "echo 'vfs' > /tmp/docker-storage-driver"; then
                "$error_func" "configure_docker_nvidia_runtime: Failed to write fallback storage driver to /tmp/docker-storage-driver in container $lxc_id."
                return 1
            fi
        else
            storage_driver=$(pct exec "$lxc_id" -- bash -c "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin cat /tmp/docker-storage-driver" 2>/dev/null || echo "overlay2") # Fallback if read fails
        fi
    fi
    # --- MODIFIED ZFS LOGIC END ---

    # --- NEW: Ensure NVIDIA Container Runtime 'no-cgroups = true' is set ---
    "$log_func" "configure_docker_nvidia_runtime: Ensuring 'no-cgroups = true' in NVIDIA Container Runtime config for LXC container $lxc_id..."
    local nvidia_config_check_cmd="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    NVIDIA_CONFIG_FILE='/etc/nvidia-container-runtime/config.toml'

    # Check if nvidia-ctk is installed
    if ! command -v nvidia-ctk >/dev/null 2>&1; then
        echo '[ERROR] nvidia-ctk not found. NVIDIA Container Toolkit might not be installed correctly.'
        exit 1
    fi

    # Ensure the config directory exists
    mkdir -p \"\$(dirname \"\$NVIDIA_CONFIG_FILE\")\"

    # Create or update the config file with 'no-cgroups = true'
    # This is the key fix for running in LXC
    cat > \"\$NVIDIA_CONFIG_FILE\" << 'EOF'
# Configuration generated/modified by Phoenix Hypervisor for LXC compatibility
disable-require = false
supported-driver-capabilities = \"compat32,compute,display,graphics,ngx,utility,video\"

[nvidia-container-cli]
#debug = \"/var/log/nvidia-container-toolkit.log\"
environment = []
ldconfig = \"@/sbin/ldconfig.real\"
load-kmods = true
no-cgroups = true # Essential for LXC
#path = \"/usr/bin/nvidia-container-cli\"
#root = \"/run/nvidia/driver\"
#user = \"root:video\"

[nvidia-container-runtime]
#debug = \"/var/log/nvidia-container-runtime.log\"
log-level = \"info\"
mode = \"auto\"
runtimes = [\"docker-runc\", \"runc\", \"crun\"]

[nvidia-container-runtime.modes]

[nvidia-container-runtime.modes.cdi]
annotation-prefixes = [\"cdi.k8s.io/\"]
default-kind = \"nvidia.com/gpu\"
spec-dirs = [\"/etc/cdi\", \"/var/run/cdi\"]

[nvidia-container-runtime.modes.csv]
mount-spec-path = \"/etc/nvidia-container-runtime/host-files-for-container.d\"

[nvidia-container-runtime.modes.legacy]
cuda-compat-mode = \"ldconfig\"

[nvidia-container-runtime-hook]
path = \"nvidia-container-runtime-hook\"
skip-mode-detection = false

[nvidia-ctk]
path = \"nvidia-ctk\"
EOF

    echo '[SUCCESS] NVIDIA Container Runtime config updated with no-cgroups = true.'
    "
    if ! "$exec_func" "$lxc_id" -- bash -c "$nvidia_config_check_cmd"; then
        "$error_func" "configure_docker_nvidia_runtime: Failed to configure NVIDIA Container Runtime 'no-cgroups = true' in container $lxc_id."
        return 1
    fi
    # --- END NEW CONFIGURATION ---

    # Check prerequisites (nvidia-smi, nvidia-ctk, docker, cgroups, GPU permissions)
    local prereq_cmd="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    touch /tmp/prereq-check.log || { echo '[ERROR] Cannot create /tmp/prereq-check.log'; exit 1; }
    echo '[INFO] Checking prerequisites...' >/tmp/prereq-check.log
    if ! command -v nvidia-smi >/dev/null 2>&1 || ! command -v nvidia-ctk >/dev/null 2>&1 || ! command -v docker >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        echo '[ERROR] Missing required tools (nvidia-smi, nvidia-ctk, docker, or jq)' >>/tmp/prereq-check.log
        exit 1
    fi
    if ! ls /sys/fs/cgroup/cgroup.controllers >/dev/null 2>&1; then
        echo '[ERROR] Cgroup v2 not accessible (/sys/fs/cgroup/cgroup.controllers missing)' >>/tmp/prereq-check.log
        exit 1
    fi
    if ! ls /dev/dri/card0 /dev/dri/renderD128 >/dev/null 2>&1 || ! ls /dev/nvidia* >/dev/null 2>&1; then
        echo '[ERROR] GPU devices not accessible' >>/tmp/prereq-check.log
        exit 1
    fi
    if ! nvidia-smi >/dev/null 2>&1; then
        echo '[ERROR] nvidia-smi failed to detect GPUs' >>/tmp/prereq-check.log
        exit 1
    fi
    if ! modprobe overlay >>/tmp/prereq-check.log 2>&1; then
        echo '[WARN] Failed to load overlay module, may be restricted in unprivileged container' >>/tmp/prereq-check.log
    fi
    echo '[INFO] Using $storage_driver storage driver' >>/tmp/prereq-check.log
    echo '$storage_driver' > /tmp/docker-storage-driver
    echo '[SUCCESS] Prerequisites for NVIDIA Docker runtime configuration checked.' >>/tmp/prereq-check.log
    "
    if ! "$exec_func" "$lxc_id" -- bash -c "storage_driver=$storage_driver; $prereq_cmd"; then
        "$error_func" "configure_docker_nvidia_runtime: Prerequisites check failed in container $lxc_id. Check /tmp/prereq-check.log."
        return 1
    fi

    # Read chosen storage driver (redundant read, but ensures consistency)
    storage_driver=$(pct exec "$lxc_id" -- bash -c "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin cat /tmp/docker-storage-driver" 2>/dev/null || echo "$storage_driver")

    # Configure NVIDIA runtime with chosen storage driver
    local config_cmd="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    touch /tmp/nvidia-ctk.log || { echo '[ERROR] Cannot create /tmp/nvidia-ctk.log'; exit 1; }
    echo '[INFO] Running nvidia-ctk to configure Docker runtime with $storage_driver storage driver...' >>/tmp/nvidia-ctk.log
    # Note: nvidia-ctk might not be needed if we directly manage daemon.json, but we run it for completeness.
    # The 'no-cgroups' setting is now in the config file, not passed here.
    if ! nvidia-ctk runtime configure --runtime=docker --set-as-default --storage-driver=$storage_driver >>/tmp/nvidia-ctk.log 2>&1; then
        echo '[WARN] nvidia-ctk failed to configure Docker runtime. Creating fallback daemon.json...' >>/tmp/nvidia-ctk.log
        mkdir -p /etc/docker
        cat << 'EOF' > /etc/docker/daemon.json
{
  \"storage-driver\": \"$storage_driver\",
  \"default-runtime\": \"nvidia\",
  \"runtimes\": {
    \"nvidia\": {
      \"path\": \"/usr/bin/nvidia-container-runtime\",
      \"runtimeArgs\": []
    }
  }
}
EOF
        echo '[INFO] Fallback /etc/docker/daemon.json created.' >>/tmp/nvidia-ctk.log
    fi
    echo '[INFO] Current /etc/docker/daemon.json contents:' >>/tmp/nvidia-ctk.log
    cat /etc/docker/daemon.json >>/tmp/nvidia-ctk.log 2>/dev/null || echo '[WARN] /etc/docker/daemon.json not found' >>/tmp/nvidia-ctk.log
    echo '[INFO] nvidia-ctk configuration or fallback written to /etc/docker/daemon.json.' >>/tmp/nvidia-ctk.log
    "
    if ! "$exec_func" "$lxc_id" -- bash -c "storage_driver=$storage_driver; $config_cmd" 2>&1 | tee -a /tmp/docker-config.log; then
        "$error_func" "configure_docker_nvidia_runtime: Failed to configure NVIDIA runtime with $storage_driver in container $lxc_id. Check /tmp/docker-config.log and /tmp/nvidia-ctk.log."
        return 1
    fi

    # Configure systemd for Docker
    "$log_func" "configure_docker_nvidia_runtime: Configuring systemd for Docker in container $lxc_id..."
    local apparmor_cmd="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    touch /tmp/docker-override.log || { echo '[ERROR] Cannot create /tmp/docker-override.log'; exit 1; }
    if [ -f /etc/systemd/system/docker.service.d/override.conf ]; then
        echo '[INFO] Systemd override for Docker already exists.' >>/tmp/docker-override.log
    else
        mkdir -p /etc/systemd/system/docker.service.d
        echo '[DEBUG] Writing systemd override to /etc/systemd/system/docker.service.d/override.conf...' >>/tmp/docker-override.log
        cat << 'EOF' > /etc/systemd/system/docker.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock
EOF
        echo '[INFO] Systemd override configured for Docker.' >>/tmp/docker-override.log
        cat /etc/systemd/system/docker.service.d/override.conf >>/tmp/docker-override.log
        echo '[DEBUG] Systemd override file contents logged to /tmp/docker-override.log' >>/tmp/docker-override.log
        systemctl daemon-reload >>/tmp/docker-daemon-reload.log 2>&1 || { echo '[ERROR] Failed to reload systemd daemon'; cat /tmp/docker-daemon-reload.log; exit 1; }
    fi
    "
    if ! "$exec_func" "$lxc_id" -- bash -c "$apparmor_cmd" 2>&1 | tee -a /tmp/docker-apparmor.log; then
        "$warn_func" "configure_docker_nvidia_runtime: Failed to configure systemd override for Docker. Check /tmp/docker-apparmor.log in container $lxc_id. Proceeding, but this may cause issues."
    fi

    # Validate daemon.json syntax
    "$log_func" "configure_docker_nvidia_runtime: Validating syntax of /etc/docker/daemon.json..."
    local json_validation_cmd="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    touch /tmp/docker-json-validation.log || { echo '[ERROR] Cannot create /tmp/docker-json-validation.log'; exit 1; }
    if [ ! -f /etc/docker/daemon.json ] || [ ! -s /etc/docker/daemon.json ]; then
        echo '[ERROR] /etc/docker/daemon.json does not exist or is empty' >>/tmp/docker-json-validation.log
        exit 1
    fi
    echo '[DEBUG] /etc/docker/daemon.json contents before validation:' >>/tmp/docker-json-validation.log
    cat /etc/docker/daemon.json >>/tmp/docker-json-validation.log
    if ! command -v jq >/dev/null 2>&1; then
        echo '[ERROR] jq not found after installation attempt, cannot validate /etc/docker/daemon.json' >>/tmp/docker-json-validation.log
        exit 1
    fi
    if jq . /etc/docker/daemon.json >>/tmp/docker-json-validation.log 2>&1; then
        echo '[SUCCESS] /etc/docker/daemon.json syntax is valid.' >>/tmp/docker-json-validation.log
    else
        echo '[ERROR] Invalid JSON syntax in /etc/docker/daemon.json. Check /tmp/docker-json-validation.log.' >>/tmp/docker-json-validation.log
        cat /etc/docker/daemon.json >>/tmp/docker-json-validation.log
        exit 1
    fi
    "
    if ! "$exec_func" "$lxc_id" -- bash -c "$json_validation_cmd" 2>&1 | tee -a /tmp/docker-json-validation.log; then
        "$error_func" "configure_docker_nvidia_runtime: JSON validation failed in container $lxc_id. Check /tmp/docker-json-validation.log."
        return 1
    fi

    # Check systemd and containerd status
    "$log_func" "configure_docker_nvidia_runtime: Checking systemd and containerd status in container $lxc_id..."
    local systemd_check_cmd="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    touch /tmp/systemd-check.log || { echo '[ERROR] Cannot create /tmp/systemd-check.log'; exit 1; }
    echo '[DEBUG] Checking systemd status...' >>/tmp/systemd-check.log
    if ! [ -f /sbin/init ]; then
        echo '[ERROR] /sbin/init not found, systemd not properly initialized' >>/tmp/systemd-check.log
        exit 1
    fi
    if ! systemctl is-system-running >/dev/null 2>&1; then
        echo '[WARN] Systemd not running, attempting to initialize...' >>/tmp/systemd-check.log
        /sbin/init >>/tmp/systemd-check.log 2>&1 || { echo '[ERROR] Failed to initialize systemd'; cat /tmp/systemd-check.log; exit 1; }
    fi
    if ! systemctl is-system-running >/dev/null 2>&1; then
        echo '[ERROR] Systemd still not running properly after initialization attempt' >>/tmp/systemd-check.log
        systemctl status --no-pager >>/tmp/systemd-check.log 2>&1
        journalctl --since '5 minutes ago' --no-pager >>/tmp/systemd-check.log 2>&1
        cat /tmp/systemd-check.log
        exit 1
    fi
    if ! systemctl is-active containerd >/dev/null 2>&1; then
        echo '[WARN] containerd service is not active, attempting start' >>/tmp/systemd-check.log
        systemctl start containerd >>/tmp/systemd-check.log 2>&1 || { echo '[ERROR] Failed to start containerd'; cat /tmp/systemd-check.log; exit 1; }
    fi
    echo '[SUCCESS] Systemd and containerd services are ready.' >>/tmp/systemd-check.log
    "
    if ! "$exec_func" "$lxc_id" -- bash -c "$systemd_check_cmd" 2>&1 | tee -a /tmp/systemd-check.log; then
        "$error_func" "configure_docker_nvidia_runtime: Systemd or containerd service check failed in container $lxc_id. Check /tmp/systemd-check.log."
        return 1
    fi

    # Reset Docker failed state and attempt restart
    "$log_func" "configure_docker_nvidia_runtime: Resetting Docker service state in container $lxc_id..."
    "$exec_func" "$lxc_id" -- bash -c "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin systemctl reset-failed docker.service"

    # Attempt to restart Docker with increased timeout
    "$log_func" "configure_docker_nvidia_runtime: Restarting Docker service in container $lxc_id..."
    local attempt=1
    local max_attempts=3
    local retry_delay=15
    local timeout_seconds=120
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "configure_docker_nvidia_runtime: Attempting to restart Docker (attempt $attempt/$max_attempts)..."
        local restart_cmd="set -e
        export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        touch /tmp/docker-restart.log || { echo '[ERROR] Cannot create /tmp/docker-restart.log'; exit 1; }
        timeout $timeout_seconds systemctl restart docker >/tmp/docker-restart.log 2>&1 || {
            echo '[ERROR] Failed to restart Docker service' >>/tmp/docker-restart.log
            cat /tmp/docker-restart.log
            journalctl -u docker.service --since '5 minutes ago' --no-pager >/tmp/docker-journalctl.log 2>&1 || echo '[WARN] Failed to get journalctl logs' >>/tmp/docker-restart.log
            echo '[DEBUG] Recent Docker service logs:' >>/tmp/docker-restart.log
            cat /tmp/docker-journalctl.log >>/tmp/docker-restart.log
            systemctl status docker.service > /tmp/docker-status.log 2>&1
            echo '[DEBUG] Docker service status:' >>/tmp/docker-restart.log
            cat /tmp/docker-status.log >>/tmp/docker-restart.log
            exit 1
        }
        echo '[SUCCESS] Docker service restarted successfully.' >>/tmp/docker-restart.log
        "
        if "$exec_func" "$lxc_id" -- bash -c "$restart_cmd"; then
            # Verify storage driver
            "$log_func" "configure_docker_nvidia_runtime: Verifying storage driver in container $lxc_id..."
            local storage_check_cmd="set -e
            export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
            PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            touch /tmp/docker-storage-check.log || { echo '[ERROR] Cannot create /tmp/docker-storage-check.log'; exit 1; }
            echo '[DEBUG] PATH in storage_check_cmd: \$PATH' >>/tmp/docker-storage-check.log
            if ! command -v docker >/dev/null 2>&1; then
                echo '[ERROR] docker command not found in PATH' >>/tmp/docker-storage-check.log
                exit 1
            fi
            docker info --format '{{.Driver}}' >/tmp/docker-info.log 2>&1 || {
                echo '[ERROR] Failed to run docker info' >>/tmp/docker-info.log
                cat /tmp/docker-info.log >>/tmp/docker-storage-check.log
                exit 1
            }
            if docker info --format '{{.Driver}}' | grep -q '$storage_driver'; then
                echo '[SUCCESS] Storage driver is $(docker info --format '{{.Driver}}').' >>/tmp/docker-storage-check.log
            else
                echo '[ERROR] Invalid storage driver: $(docker info --format '{{.Driver}}')' >>/tmp/docker-storage-check.log
                cat /tmp/docker-info.log >>/tmp/docker-storage-check.log
                exit 1
            fi
            echo '[INFO] NVIDIA runtime path: $(docker info --format '{{.Runtimes.nvidia.path}}')' >>/tmp/docker-storage-check.log
            "
            if "$exec_func" "$lxc_id" -- bash -c "storage_driver=$storage_driver; $storage_check_cmd" 2>&1 | tee -a /tmp/docker-storage-check.log; then
                "$log_func" "configure_docker_nvidia_runtime: Docker service restarted successfully with $storage_driver storage driver in container $lxc_id."
                return 0
            else
                "$warn_func" "configure_docker_nvidia_runtime: Invalid storage driver after restart. Check /tmp/docker-storage-check.log and /tmp/docker-info.log in container $lxc_id. Retrying..."
            fi
        fi
        "$warn_func" "configure_docker_nvidia_runtime: Failed on attempt $attempt. Check /tmp/docker-restart.log, /tmp/docker-journalctl.log, and /tmp/docker-status.log in container $lxc_id. Retrying in $retry_delay seconds..."
        sleep "$retry_delay"
        ((attempt++))
    done

    # Fallback: Try manual stop/start
    "$log_func" "configure_docker_nvidia_runtime: Systemctl restart failed. Attempting manual Docker stop/start in container $lxc_id..."
    local manual_restart_cmd="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    touch /tmp/docker-start.log || { echo '[ERROR] Cannot create /tmp/docker-start.log'; exit 1; }
    if systemctl is-active docker >/dev/null 2>&1; then
        systemctl stop docker >/tmp/docker-stop.log 2>&1 || { echo '[ERROR] Failed to stop Docker'; cat /tmp/docker-stop.log; exit 1; }
    fi
    systemctl start docker >/tmp/docker-start.log 2>&1 || { echo '[ERROR] Failed to start Docker'; cat /tmp/docker-start.log; exit 1; }
    echo '[SUCCESS] Docker service manually restarted.' >>/tmp/docker-start.log
    "
    if "$exec_func" "$lxc_id" -- bash -c "$manual_restart_cmd"; then
        "$log_func" "configure_docker_nvidia_runtime: Manual Docker stop/start succeeded in container $lxc_id."
        return 0
    else
        "$error_func" "configure_docker_nvidia_runtime: Failed to restart Docker in container $lxc_id after $max_attempts attempts and manual fallback. Check /tmp/docker-{stop,start,restart,journalctl,status}.log in container."
        return 1
    fi
}

# --- Docker Validation ---

# Verify basic Docker GPU access inside an LXC container by running a simple CUDA container
# Usage: verify_docker_gpu_access_in_container <container_id> [cuda_image_tag]
# NOTE: The default mode now uses --security-opt apparmor=unconfined for LXC compatibility
verify_docker_gpu_access_in_container() {
    local lxc_id="$1"
    local test_image="${2:-nvidia/cuda:12.8.0-base-ubuntu24.04}" # Allow custom image
    local max_attempts=3
    local attempt=1

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    fi

    # Use log_warn if available, otherwise fallback
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" >&2; }
    fi

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    if [[ -z "$lxc_id" ]]; then
        "$error_func" "verify_docker_gpu_access_in_container: Container ID is required."
        return 2 # Invalid argument
    fi

    "$log_func" "verify_docker_gpu_access_in_container: Checking Docker GPU access in container $lxc_id..."

    # Use pct_exec_with_retry if available, otherwise direct exec
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    # --- Modified Test Logic with Workarounds ---
    # Start with the mode that worked for you in LXC
    local docker_run_base_cmd="docker run --rm --gpus all --security-opt apparmor=unconfined"
    local success=false

    # 1. Try standard command with AppArmor bypass first (ideal for LXC)
    "$log_func" "verify_docker_gpu_access_in_container: Attempting Docker GPU test with AppArmor bypass (--security-opt apparmor=unconfined)..."
    if "$exec_func" "$lxc_id" -- $docker_run_base_cmd "$test_image" nvidia-smi >/dev/null 2>&1; then
        "$log_func" "verify_docker_gpu_access_in_container: Docker GPU test with AppArmor bypass succeeded."
        success=true
    else
        "$warn_func" "verify_docker_gpu_access_in_container: Docker GPU test with AppArmor bypass failed."
    fi

    # 2. If AppArmor bypass fails, try standard command (might work in some configs)
    if [[ "$success" != true ]]; then
        "$log_func" "verify_docker_gpu_access_in_container: Attempting standard Docker GPU test..."
        if "$exec_func" "$lxc_id" -- docker run --rm --gpus all "$test_image" nvidia-smi >/dev/null 2>&1; then
            "$log_func" "verify_docker_gpu_access_in_container: Standard Docker GPU test succeeded."
            success=true
        else
            "$warn_func" "verify_docker_gpu_access_in_container: Standard Docker GPU test also failed."
        fi
    fi

    # 3. If standard fails, try privileged mode (less secure, last resort diagnostic)
    if [[ "$success" != true ]]; then
        "$log_func" "verify_docker_gpu_access_in_container: Attempting Docker GPU test with privileged mode (--privileged)..."
        if "$exec_func" "$lxc_id" -- docker run --rm --gpus all --privileged "$test_image" nvidia-smi >/dev/null 2>&1; then
            "$log_func" "verify_docker_gpu_access_in_container: Docker GPU test with privileged mode succeeded."
            success=true
        else
            "$warn_func" "verify_docker_gpu_access_in_container: Docker GPU test with privileged mode also failed."
        fi
    fi

    # --- End Modified Test Logic ---

    if [[ "$success" == true ]]; then
        "$log_func" "verify_docker_gpu_access_in_container: Docker GPU access verified successfully in container $lxc_id."
        return 0
    else
        "$error_func" "verify_docker_gpu_access_in_container: Failed to verify Docker GPU access in container $lxc_id after all attempts."
        return 1
    fi
}

echo "[INFO] phoenix_hypervisor_lxc_common_docker.sh: Library loaded successfully."
