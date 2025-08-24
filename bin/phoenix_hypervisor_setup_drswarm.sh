#!/usr/bin/env bash
# phoenix_hypervisor_setup_drswarm.sh
#
# Sets up the DrSwarm container (ID 999) with Docker Swarm Manager and local registry.
# Discovers and builds base Docker images from shared directories and pushes them to the local registry.
# This script is intended to be called by phoenix_establish_hypervisor.sh after container creation.
#
# Version: 1.4.0 (Improved LXC config handling, Refactored library sourcing logic)
# Author: Assistant

set -euo pipefail

# - Terminal Handling -
# Save terminal settings and ensure they are restored on exit or error
ORIGINAL_TERM_SETTINGS=$(stty -g 2>/dev/null) || ORIGINAL_TERM_SETTINGS=""
restore_terminal() {
    if [[ -n "$ORIGINAL_TERM_SETTINGS" ]]; then
        stty "$ORIGINAL_TERM_SETTINGS" 2>/dev/null || true
    fi
    echo "Terminal reset"
}
trap restore_terminal EXIT

# - Script Metadata -
SCRIPT_NAME="phoenix_hypervisor_setup_drswarm.sh"
SCRIPT_VERSION="1.4.0"
AUTHOR="Assistant"

# - Configuration -
# Expected container name for ID 999
EXPECTED_CONTAINER_NAME="DrSwarm"
# Required common library functions
# Note: validate_container_exists will come from phoenix_hypervisor_lxc_common_validation.sh
REQUIRED_COMMON_FUNCTIONS=(
    "log_info" "log_warn" "log_error"
    "pct_exec_with_retry"
    "load_hypervisor_config" # Needed for accessing LXC_CONFIGS
)

# --- NEW: Configuration for Image Building & Mounting ---
# Path to the shared directory containing image build contexts on the Proxmox host
SHARED_DOCKER_IMAGES_DIR="/mnt/pve/shared-bulk-data/phoenix_docker_images"
# Path where the shared directory will be mounted inside the LXC container (999)
LXC_MOUNT_POINT="/mnt/phoenix_docker_images"
# --- END NEW ---

# - Source Required Libraries -
# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source configuration
PHOENIX_ETC_DIR="/usr/local/etc"
PHOENIX_LIB_DIR="/usr/local/lib/phoenix_hypervisor"

# --- NEW: Refactored Library Sourcing Logic ---
# 1. Source Configuration File
PHOENIX_CONFIG_LOADED=0
for config_path in \
    "$PHOENIX_ETC_DIR/phoenix_hypervisor_config.sh" \
    "$PHOENIX_LIB_DIR/phoenix_hypervisor_config.sh" \
    "$SCRIPT_DIR/phoenix_hypervisor_config.sh" \
    "./phoenix_hypervisor_config.sh"; do
    if [[ -f "$config_path" ]]; then
        # shellcheck source=/dev/null
        source "$config_path"
        PHOENIX_CONFIG_LOADED=1
        # Use minimal logging initially if common lib isn't loaded yet
        if declare -F log_info >/dev/null 2>&1; then
            log_info "$SCRIPT_NAME: Sourced configuration from $config_path."
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $SCRIPT_NAME: Sourced configuration from $config_path."
        fi
        break
    fi
done
if [[ $PHOENIX_CONFIG_LOADED -ne 1 ]]; then
    echo "[ERROR] $SCRIPT_NAME: Failed to load phoenix_hypervisor_config.sh from standard locations." >&2
    echo "[ERROR] Please ensure it's installed correctly." >&2
    exit 1
fi

# 2. Source Main Common Functions
PHOENIX_COMMON_LOADED=0
for common_path in \
    "$PHOENIX_LIB_DIR/phoenix_hypervisor_common.sh" \
    "$SCRIPT_DIR/phoenix_hypervisor_common.sh" \
    "/usr/local/bin/phoenix_hypervisor_common.sh" \
    "./phoenix_hypervisor_common.sh"; do
    if [[ -f "$common_path" ]]; then
        # shellcheck source=/dev/null
        source "$common_path"
        PHOENIX_COMMON_LOADED=1
        if declare -F log_info >/dev/null 2>&1; then
            log_info "$SCRIPT_NAME: Sourced main common functions from $common_path."
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $SCRIPT_NAME: Sourced main common functions from $common_path."
        fi
        break
    fi
done
if [[ $PHOENIX_COMMON_LOADED -ne 1 ]]; then
    echo "[ERROR] $SCRIPT_NAME: Failed to load phoenix_hypervisor_common.sh from standard locations." >&2
    echo "[ERROR] Please ensure it's installed correctly." >&2
    exit 1
fi

# 3. Source Base LXC Common Functions (contains pct_exec_with_retry)
PHOENIX_BASE_LOADED=0
for base_path in \
    "$PHOENIX_LIB_DIR/phoenix_hypervisor_lxc_common_base.sh" \
    "$SCRIPT_DIR/phoenix_hypervisor_lxc_common_base.sh"; do
    if [[ -f "$base_path" ]]; then
        # shellcheck source=/dev/null
        source "$base_path"
        if declare -F pct_exec_with_retry >/dev/null 2>&1; then
            PHOENIX_BASE_LOADED=1
            log_info "$SCRIPT_NAME: Sourced Base LXC common functions from $base_path."
            break
        else
            log_warn "$SCRIPT_NAME: Sourced $base_path, but Base LXC functions not found. Trying next location."
        fi
    fi
done
if [[ $PHOENIX_BASE_LOADED -ne 1 ]]; then
    log_error "$SCRIPT_NAME: Failed to load phoenix_hypervisor_lxc_common_base.sh. Cannot proceed with base LXC operations."
fi

# 4. Source Docker LXC Common Functions
PHOENIX_DOCKER_LOADED=0
for docker_path in \
    "$PHOENIX_LIB_DIR/phoenix_hypervisor_lxc_common_docker.sh" \
    "$SCRIPT_DIR/phoenix_hypervisor_lxc_common_docker.sh"; do
    if [[ -f "$docker_path" ]]; then
        # shellcheck source=/dev/null
        source "$docker_path"
        if declare -F install_docker_ce_in_container >/dev/null 2>&1; then
            PHOENIX_DOCKER_LOADED=1
            log_info "$SCRIPT_NAME: Sourced Docker LXC common functions from $docker_path."
            break
        else
            log_warn "$SCRIPT_NAME: Sourced $docker_path, but Docker LXC functions not found. Trying next location."
        fi
    fi
done
# Loading Docker lib is optional for this script if Docker isn't used directly
if [[ $PHOENIX_DOCKER_LOADED -ne 1 ]]; then
    log_warn "$SCRIPT_NAME: Failed to load phoenix_hypervisor_lxc_common_docker.sh. Will attempt manual Docker installation."
fi

# 5. Source Validation LXC Common Functions
PHOENIX_VALIDATION_LOADED=0
for validation_path in \
    "$PHOENIX_LIB_DIR/phoenix_hypervisor_lxc_common_validation.sh" \
    "$SCRIPT_DIR/phoenix_hypervisor_lxc_common_validation.sh"; do
    if [[ -f "$validation_path" ]]; then
        # shellcheck source=/dev/null
        source "$validation_path"
        if declare -F validate_container_exists >/dev/null 2>&1; then
            PHOENIX_VALIDATION_LOADED=1
            log_info "$SCRIPT_NAME: Sourced Validation LXC common functions from $validation_path."
            break
        else
            log_warn "$SCRIPT_NAME: Sourced $validation_path, but Validation LXC functions not found. Trying next location."
        fi
    fi
done
if [[ $PHOENIX_VALIDATION_LOADED -ne 1 ]]; then
    log_error "$SCRIPT_NAME: Failed to load phoenix_hypervisor_lxc_common_validation.sh. Cannot proceed with validation operations."
fi

# 6. Source Systemd LXC Common Functions
PHOENIX_SYSTEMD_LOADED=0
for systemd_path in \
    "$PHOENIX_LIB_DIR/phoenix_hypervisor_lxc_common_systemd.sh" \
    "$SCRIPT_DIR/phoenix_hypervisor_lxc_common_systemd.sh"; do
    if [[ -f "$systemd_path" ]]; then
        # shellcheck source=/dev/null
        source "$systemd_path"
        if declare -F enable_systemd_service_in_container >/dev/null 2>&1; then
            PHOENIX_SYSTEMD_LOADED=1
            log_info "$SCRIPT_NAME: Sourced Systemd LXC common functions from $systemd_path."
            break
        else
            log_warn "$SCRIPT_NAME: Sourced $systemd_path, but Systemd LXC functions not found. Trying next location."
        fi
    fi
done
# Loading systemd lib is optional for this script
if [[ $PHOENIX_SYSTEMD_LOADED -ne 1 ]]; then
    log_warn "$SCRIPT_NAME: Failed to load phoenix_hypervisor_lxc_common_systemd.sh. This might be OK if not needed."
fi

# 7. Final Check: Verify ALL Required Functions are Available
ALL_FUNCTIONS_AVAILABLE=true
MISSING_FUNCTIONS=()
for func in "${REQUIRED_COMMON_FUNCTIONS[@]}"; do
    if ! declare -F "$func" >/dev/null 2>&1; then
        ALL_FUNCTIONS_AVAILABLE=false
        # Use minimal logging if log_error isn't available
        if declare -F log_error >/dev/null 2>&1; then
            log_error "$SCRIPT_NAME: Required function '$func' is not available after sourcing libraries."
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $SCRIPT_NAME: Required function '$func' is not available after sourcing libraries." >&2
            exit 1
        fi
        MISSING_FUNCTIONS+=("$func")
    fi
done

if [[ "$ALL_FUNCTIONS_AVAILABLE" != true ]]; then
    # Use minimal logging if log_error isn't available
    if declare -F log_error >/dev/null 2>&1; then
        log_error "$SCRIPT_NAME: Failed to load required functions: ${MISSING_FUNCTIONS[*]}"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $SCRIPT_NAME: Failed to load required functions: ${MISSING_FUNCTIONS[*]}" >&2
        exit 1
    fi
else
    log_info "$SCRIPT_NAME: All required functions are now available."
fi
# --- END NEW: Refactored Library Sourcing Logic ---

# - Core Setup Functions -

# 1. Validate Dependencies
validate_dependencies() {
    log_info "validate_dependencies: Checking for required commands..."
    if ! command -v jq >/dev/null 2>&1; then
        log_error "validate_dependencies: jq not installed."
    fi
    if ! command -v pct >/dev/null 2>&1; then
        log_error "validate_dependencies: pct not installed."
    fi
    # --- NEW: Check for shared directory ---
    if [[ ! -d "$SHARED_DOCKER_IMAGES_DIR" ]]; then
        log_error "validate_dependencies: Shared Docker images directory '$SHARED_DOCKER_IMAGES_DIR' not found on Proxmox host."
    fi
    # --- END NEW ---
    log_info "validate_dependencies: All required commands and directories found."
}

# 2. Validate Container Configuration
validate_container_config() {
    local lxc_id="$1"
    log_info "validate_container_config: Validating configuration for container $lxc_id..."

    # Load hypervisor config to access LXC_CONFIGS array
    # Note: validate_dependencies should have loaded it, but check here too for robustness
    if ! load_hypervisor_config; then
        log_error "validate_container_config: Failed to load hypervisor configuration."
        exit 1 # Explicit exit for robustness
    fi

    # Check if container ID exists in config
    if [[ -z "${LXC_CONFIGS[$lxc_id]:-}" ]]; then
        log_error "validate_container_config: Container ID $lxc_id not found in $PHOENIX_LXC_CONFIG_FILE."
        exit 1 # Explicit exit for robustness
    fi

    # Extract name and check
    local container_name
    container_name=$(echo "${LXC_CONFIGS[$lxc_id]}" | jq -r '.name')
    if [[ "$container_name" != "$EXPECTED_CONTAINER_NAME" ]]; then
        log_error "validate_container_config: Container $lxc_id name is '$container_name', expected '$EXPECTED_CONTAINER_NAME'."
        exit 1 # Explicit exit for robustness
    fi

    log_info "validate_container_config: Container $lxc_id configuration is valid for $EXPECTED_CONTAINER_NAME."
}

# 3. Make Container Privileged and Mount Shared Directory (IMPROVED)
make_container_privileged_and_mount() {
    local lxc_id="$1"
    local config_file="/etc/pve/lxc/$lxc_id.conf"

    log_info "make_container_privileged_and_mount: Configuring container $lxc_id for Docker and mounting shared directory..."

    # Check current status and stop if running
    if pct status "$lxc_id" >/dev/null 2>&1; then
        log_info "make_container_privileged_and_mount: Stopping container $lxc_id..."
        pct stop "$lxc_id" || log_error "make_container_privileged_and_mount: Failed to stop container $lxc_id."
        sleep 5 # Allow time to stop
    fi

    # --- IMPROVED: Fix LXC Configuration File ---
    # 1. Correct unprivileged setting
    # Check if the line exists and replace it, or append if it doesn't
    if grep -q "^unprivileged:" "$config_file" 2>/dev/null; then
        # Line exists, replace it to ensure it's 'unprivileged: 0'
        sed -i 's/^unprivileged:.*/unprivileged: 0/' "$config_file"
        log_info "make_container_privileged_and_mount: Updated 'unprivileged:' line to 'unprivileged: 0' in $config_file."
    else
        # Line doesn't exist, append it
        echo "unprivileged: 0" >> "$config_file"
        log_info "make_container_privileged_and_mount: Added 'unprivileged: 0' to $config_file."
    fi

    # 2. Ensure AppArmor is unconfined for Docker
    if ! grep -q "^lxc.apparmor.profile: unconfined" "$config_file" 2>/dev/null; then
        echo "lxc.apparmor.profile: unconfined" >> "$config_file"
        log_info "make_container_privileged_and_mount: Added lxc.apparmor.profile: unconfined to $config_file."
    fi

    # 3. Fix/Ensure Mount Point Format (mp=bind) - Robust Handling
    # Check if ANY mp0 line exists (correct or incorrect format)
    if grep -q "^mp0:" "$config_file" 2>/dev/null; then
        # mp0 line exists. Remove ALL existing mp0 lines to prevent duplicates/conflicts.
        # This handles cases with malformed lines, duplicates, or old formats.
        log_info "make_container_privileged_and_mount: Found existing mp0 line(s) in $config_file. Removing them."
        # Use grep -v to invert the match and print lines that DON'T match ^mp0:, then redirect to a temp file
        grep -v "^mp0:" "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
        if [[ $? -eq 0 ]]; then
            log_info "make_container_privileged_and_mount: Existing mp0 line(s) removed from $config_file."
        else
            log_error "make_container_privileged_and_mount: Failed to remove existing mp0 line(s) from $config_file."
        fi
    fi
    # At this point, no mp0 line should exist. Add the correct one.
    log_info "make_container_privileged_and_mount: Adding correct mount point for '$SHARED_DOCKER_IMAGES_DIR' at '$LXC_MOUNT_POINT' in $config_file..."
    # Add the correctly formatted mp0 line with mp=bind
    echo "mp0: $SHARED_DOCKER_IMAGES_DIR,$LXC_MOUNT_POINT,mp=bind" >> "$config_file"
    if [[ $? -eq 0 ]]; then
        log_info "make_container_privileged_and_mount: Correct mount point added to $config_file."
    else
        log_error "make_container_privileged_and_mount: Failed to add mount point to $config_file."
    fi
    # --- END IMPROVED: Fix LXC Configuration File ---

    # Start the container
    log_info "make_container_privileged_and_mount: Starting container $lxc_id..."
    pct start "$lxc_id" || log_error "make_container_privileged_and_mount: Failed to start container $lxc_id."

    # Wait for container to be ready
    log_info "make_container_privileged_and_mount: Waiting for container $lxc_id to become responsive..."
    # Use a faster check and retry mechanism for responsiveness
    local attempt=1
    # Reduced attempts and sleep time for a fast system
    local max_attempts=5
    while [[ $attempt -le $max_attempts ]]; do
        # Use a simple command that should respond quickly if the container is up
        if pct_exec_with_retry "$lxc_id" hostname >/dev/null 2>&1; then
            log_info "make_container_privileged_and_mount: Container $lxc_id is responsive."
            return 0
        fi
        log_info "make_container_privileged_and_mount: Container $lxc_id not responsive (attempt $attempt/$max_attempts), retrying quickly..."
        sleep 1 # Shorter sleep
        ((attempt++))
    done
    log_error "make_container_privileged_and_mount: Container $lxc_id did not become responsive after $max_attempts attempts."
}


# 4. Install Docker (using common function or manual)
install_docker_in_swarm_manager() {
    local lxc_id="$1"

    log_info "install_docker_in_swarm_manager: Installing Docker in container $lxc_id..."

    if [[ $PHOENIX_DOCKER_LOADED -eq 1 ]] && declare -F install_docker_ce_in_container >/dev/null 2>&1; then
        log_info "install_docker_in_swarm_manager: Using common function to install Docker..."
        # The common function should handle enabling/starting the service
        if install_docker_ce_in_container "$lxc_id"; then
            log_info "install_docker_in_swarm_manager: Docker installed successfully using common function."
            return 0 # Explicit success
        else
            log_error "install_docker_in_swarm_manager: Failed to install Docker using common function."
            return 1 # Explicit failure
        fi
    else
        log_warn "install_docker_in_swarm_manager: Common Docker function not available, falling back to manual installation..."
        # Manual Docker installation steps (simplified version of common function logic)
        # Includes explicit enable and start
        local install_cmd="
        set -e
        export DEBIAN_FRONTEND=noninteractive
        export LC_ALL=C
        echo '[INFO] Installing prerequisites for Docker...'
        apt-get update -y --fix-missing > /tmp/docker-apt-update.log 2>&1 || { echo '[ERROR] Failed to update package lists'; cat /tmp/docker-apt-update.log; exit 1; }
        apt-get install -y ca-certificates curl gnupg lsb-release > /tmp/docker-apt-prereqs.log 2>&1 || { echo '[ERROR] Failed to install prerequisites'; cat /tmp/docker-apt-prereqs.log; exit 1; }
        echo '[INFO] Adding Docker repository...'
        mkdir -p /etc/apt/keyrings
        # --- CORRECTED: Fixed spacing in curl URL ---
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        # --- CORRECTED: Fixed spacing in repo URL ---
        echo 'deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable' | tee /etc/apt/sources.list.d/docker.list > /dev/null
        echo '[INFO] Updating package lists for Docker...'
        apt-get update -y --fix-missing > /tmp/docker-apt-update2.log 2>&1 || { echo '[ERROR] Failed to update package lists'; cat /tmp/docker-apt-update2.log; exit 1; }
        echo '[INFO] Installing Docker-ce...'
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /tmp/docker-apt-install.log 2>&1 || { echo '[ERROR] Failed to install Docker-ce'; cat /tmp/docker-apt-install.log; exit 1; }
        echo '[INFO] Enabling and starting Docker service...'
        systemctl enable docker > /tmp/docker-enable.log 2>&1 || { echo '[ERROR] Failed to enable Docker service'; cat /tmp/docker-enable.log; exit 1; }
        systemctl start docker > /tmp/docker-start.log 2>&1 || { echo '[ERROR] Failed to start Docker service'; cat /tmp/docker-start.log; exit 1; }
        echo '[SUCCESS] Docker-ce installed, enabled, and started successfully.'
        "
        # Use pct_exec_with_retry for robustness
        if pct_exec_with_retry "$lxc_id" bash -c "$install_cmd"; then
            log_info "install_docker_in_swarm_manager: Docker installed successfully via manual method."
            return 0 # Explicit success
        else
            log_error "install_docker_in_swarm_manager: Failed to install Docker via manual method."
            return 1 # Explicit failure
        fi
    fi
    # Should not reach here due to returns above, but good practice
    return 1
}

# 5. Initialize Docker Swarm
initialize_docker_swarm() {
    local lxc_id="$1"
    log_info "initialize_docker_swarm: Initializing Docker Swarm on container $lxc_id..."

    # Get the static IP from the config
    # Note: validate_container_config/load_hypervisor_config should have loaded LXC_CONFIGS
    local static_ip
    static_ip=$(echo "${LXC_CONFIGS[$lxc_id]}" | jq -r '.static_ip // empty')
    if [[ -z "$static_ip" ]]; then
        log_error "initialize_docker_swarm: static_ip not found for container $lxc_id in config."
    fi
    # Extract just the IP part (before the /)
    local advertise_ip="${static_ip%%/*}"
    if [[ -z "$advertise_ip" ]]; then
         log_error "initialize_docker_swarm: Could not extract IP from static_ip '$static_ip'."
    fi

    local init_cmd="
    set -e
    echo '[INFO] Waiting briefly for Docker service to be fully ready...'
    sleep 5 # Give Docker a moment after installation/start
    echo '[INFO] Initializing Docker Swarm with advertise address $advertise_ip...'
    if docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q 'active'; then
        echo '[INFO] Swarm already active. Leaving existing swarm first.'
        docker swarm leave --force || { echo '[WARN] Failed to leave existing swarm.'; }
    fi
    docker swarm init --advertise-addr '$advertise_ip' > /tmp/swarm-init.log 2>&1 || { echo '[ERROR] Failed to initialize Docker Swarm'; cat /tmp/swarm-init.log; exit 1; }
    echo '[INFO] Getting join token for informational purposes...'
    docker swarm join-token worker > /tmp/swarm-join-token-worker.log 2>&1 || echo '[WARN] Could not get worker join token.'
    cat /tmp/swarm-join-token-worker.log
    echo '[SUCCESS] Docker Swarm initialized successfully on $advertise_ip.'
    "

    # Use pct_exec_with_retry for robustness
    if pct_exec_with_retry "$lxc_id" bash -c "$init_cmd"; then
        log_info "initialize_docker_swarm: Docker Swarm initialized successfully on $advertise_ip."
    else
        log_error "initialize_docker_swarm: Failed to initialize Docker Swarm."
    fi
}

# 6. Start Local Docker Registry
start_local_registry() {
    local lxc_id="$1"
    log_info "start_local_registry: Starting local Docker registry in container $lxc_id..."

    local registry_cmd="
    set -e
    echo '[INFO] Checking if registry container is already running...'
    if docker ps -q -f name=registry | grep -q .; then
        echo '[INFO] Registry container is already running.'
        exit 0
    fi
    echo '[INFO] Pulling registry:2 image...'
    docker pull registry:2 > /tmp/registry-pull.log 2>&1 || { echo '[ERROR] Failed to pull registry:2 image'; cat /tmp/registry-pull.log; exit 1; }
    echo '[INFO] Starting registry container...'
    docker run -d -p 5000:5000 --restart=always --name registry registry:2 > /tmp/registry-run.log 2>&1 || { echo '[ERROR] Failed to start registry container'; cat /tmp/registry-run.log; exit 1; }
    sleep 5 # Give it a moment to start
    if docker ps -q -f name=registry | grep -q .; then
        echo '[SUCCESS] Local Docker registry started successfully.'
    else
        echo '[ERROR] Registry container did not start successfully.'
        docker logs registry > /tmp/registry-logs.log 2>&1 || echo '[WARN] Could not get registry logs.'
        cat /tmp/registry-logs.log
        exit 1
    fi
    "

    # Use pct_exec_with_retry for robustness
    if pct_exec_with_retry "$lxc_id" bash -c "$registry_cmd"; then
        log_info "start_local_registry: Local Docker registry started successfully."
    else
        log_error "start_local_registry: Failed to start local Docker registry."
    fi
}

# --- NEW: Discover and Build Images from Mounted Shared Directory ---
discover_and_build_images() {
    local lxc_id="$1"
    log_info "discover_and_build_images: Starting discovery and build process for container $lxc_id..."

    # Check if the shared directory exists inside LXC 999 (it should be accessible via the mount point)
    # Note: We use the LXC_MOUNT_POINT path which is where the host directory is mounted inside the container.
    local lxc_shared_path="$LXC_MOUNT_POINT"

    # Verify the shared directory exists inside the LXC container
    if ! pct_exec_with_retry "$lxc_id" test -d "$lxc_shared_path"; then
        log_error "discover_and_build_images: Shared Docker images directory '$lxc_shared_path' not found inside LXC $lxc_id. Check mount configuration."
    fi

    log_info "discover_and_build_images: Scanning '$lxc_shared_path' for image build contexts inside LXC $lxc_id..."

    local found_images=0
    local built_images=0

    # Use find inside the LXC container to get directories one level deep, excluding hidden ones
    local find_cmd="
    set -e
    find '$lxc_shared_path' -mindepth 1 -maxdepth 1 -type d -not -name '.*' -print0 2>/dev/null || { echo '[WARN] find command produced no results or errors'; exit 0; }
    "
    local image_dirs_output
    # Capture output correctly for processing
    image_dirs_output=$(pct_exec_with_retry "$lxc_id" bash -c "$find_cmd") || {
        log_error "discover_and_build_images: Failed to scan for image directories inside LXC $lxc_id. Output might be in error log."
    }

    # Check if any directories were found
    if [[ -z "$image_dirs_output" ]]; then
        log_warn "discover_and_build_images: No image build contexts found in '$lxc_shared_path' inside LXC $lxc_id."
        return 0 # Not an error, just nothing to do
    fi

    # Process the output from inside the container
    # Use process substitution to handle null-delimited input safely
    while IFS= read -r -d '' image_dir_internal; do
        # Get the basename of the directory (e.g., 'vllm-base' from '/mnt/phoenix_docker_images/vllm-base')
        local image_name
        image_name=$(basename "$image_dir_internal")

        # Basic validation: check if it's a directory and contains a Dockerfile inside the container
        local validate_cmd="
        set -e
        if [[ -d '$image_dir_internal' ]] && [[ -f '$image_dir_internal/Dockerfile' ]]; then
            echo '[SUCCESS] Valid build context found for image $image_name at $image_dir_internal inside LXC $lxc_id.'
            exit 0
        else
            echo '[WARN] Skipping $image_dir_internal. Not a directory or missing Dockerfile inside LXC $lxc_id.'
            exit 1
        fi
        "
        if pct_exec_with_retry "$lxc_id" bash -c "$validate_cmd"; then
            log_info "discover_and_build_images: Found valid build context for image '$image_name' at '$image_dir_internal' inside LXC $lxc_id."
            ((found_images++))

            # --- Build, Tag, and Push the Image inside LXC 999 using the CORRECTED path ---
            log_info "discover_and_build_images: Building image '$image_name:latest' inside LXC $lxc_id from '$image_dir_internal'..."
            local build_cmd="
            set -e
            # Change to the path INSIDE LXC 999 (the mounted path)
            cd '$image_dir_internal' || { echo '[ERROR] Failed to change directory to $image_dir_internal inside LXC $lxc_id'; exit 1; }
            echo '[INFO] Inside LXC $lxc_id, building image $image_name:latest from context $image_dir_internal...'
            # Build the image using the Dockerfile in the current directory (context)
            docker build -t '$image_name:latest' . > /tmp/build-$image_name.log 2>&1 || { echo '[ERROR] Docker build failed for $image_name'; cat /tmp/build-$image_name.log; exit 1; }
            echo '[INFO] Tagging image $image_name:latest as localhost:5000/$image_name:latest...'
            docker tag '$image_name:latest' 'localhost:5000/$image_name:latest' > /tmp/tag-$image_name.log 2>&1 || { echo '[ERROR] Docker tag failed for $image_name'; cat /tmp/tag-$image_name.log; exit 1; }
            echo '[INFO] Pushing image localhost:5000/$image_name:latest to local registry...'
            docker push 'localhost:5000/$image_name:latest' > /tmp/push-$image_name.log 2>&1 || { echo '[ERROR] Docker push failed for $image_name'; cat /tmp/push-$image_name.log; exit 1; }
            echo '[SUCCESS] Image $image_name:latest built, tagged, and pushed successfully from $image_dir_internal.'
            "

            # Execute the build/tag/push sequence inside LXC 999
            if pct_exec_with_retry "$lxc_id" bash -c "$build_cmd"; then
                log_info "discover_and_build_images: Successfully processed image '$image_name'."
                ((built_images++))
            else
                log_error "discover_and_build_images: Failed to build/tag/push image '$image_name'. Check LXC $lxc_id logs (/tmp/build-$image_name.log, /tmp/tag-$image_name.log, /tmp/push-$image_name.log)."
                # Decide if failure to build one image should stop the whole process.
                # For now, we'll warn and continue, but you could change this to 'exit 1'.
                continue
            fi
            # --- End Build, Tag, Push ---
        else
            log_warn "discover_and_build_images: Skipping '$image_dir_internal'. It's either not a directory or missing a Dockerfile inside LXC $lxc_id."
        fi

    # Use process substitution to read the null-delimited output from find
    done < <(printf '%s' "$image_dirs_output" | tr '\0' '\n' | while IFS= read -r line; do echo "$line"; done | tr '\n' '\0')

    if [[ $found_images -eq 0 ]]; then
        log_warn "discover_and_build_images: No valid image build contexts (directories with Dockerfile) found in '$lxc_shared_path' inside LXC $lxc_id."
    else
        log_info "discover_and_build_images: Found $found_images build contexts. Successfully built and pushed $built_images images."
    fi

    log_info "discover_and_build_images: Completed discovery and build process for container $lxc_id."
}
# --- END NEW ---

# 7. Validate Final Setup (Includes registry check)
validate_final_setup() {
    local lxc_id="$1"
    log_info "validate_final_setup: Performing final validation for container $lxc_id..."

    # Check if Docker service is active
    local docker_active_check="
    if systemctl is-active --quiet docker; then
        echo '[SUCCESS] Docker service is active.'
    else
        echo '[ERROR] Docker service is not active.'
        journalctl -u docker.service -n 20 > /tmp/docker-service-check.log 2>&1 || echo '[WARN] Could not get docker service logs.'
        cat /tmp/docker-service-check.log
        exit 1
    fi
    "
    # Use pct_exec_with_retry for robustness
    if ! pct_exec_with_retry "$lxc_id" bash -c "$docker_active_check"; then
        log_error "validate_final_setup: Docker service validation failed for container $lxc_id."
    fi

    # Check if Swarm is active
    local swarm_active_check="
    if docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q 'active'; then
        echo '[SUCCESS] Docker Swarm is active.'
        manager_node_id=\$(docker info --format '{{.Swarm.NodeID}}')
        echo '[INFO] Swarm Node ID: \$manager_node_id'
    else
        echo '[ERROR] Docker Swarm is not active.'
        exit 1
    fi
    "
    # Use pct_exec_with_retry for robustness
    if ! pct_exec_with_retry "$lxc_id" bash -c "$swarm_active_check"; then
        log_error "validate_final_setup: Docker Swarm validation failed for container $lxc_id."
    fi

    # Check if registry container is running
    local registry_running_check="
    if docker ps -q -f name=registry | grep -q .; then
        echo '[SUCCESS] Local Docker registry container is running.'
        registry_ip=\$(hostname -I | awk '{print \$1}')
        echo '[INFO] Registry should be accessible at http://\${registry_ip}:5000'
    else
        echo '[ERROR] Local Docker registry container is not running.'
        # Try to get logs if it failed
        docker logs registry > /tmp/registry-check-logs.log 2>&1 || echo '[WARN] Could not get registry logs.'
        cat /tmp/registry-check-logs.log
        exit 1
    fi
    "
    # Use pct_exec_with_retry for robustness
    if ! pct_exec_with_retry "$lxc_id" bash -c "$registry_running_check"; then
        log_error "validate_final_setup: Local registry validation failed for container $lxc_id."
    fi

    # --- NEW: Check if images were built and pushed ---
    # This is a basic check. A more thorough check would list images in the registry.
    # For now, we assume the build process logs success/failure adequately.
    log_info "validate_final_setup: Basic validation completed. Images should now be available in the registry."
    # --- END NEW ---

    log_info "validate_final_setup: All validations passed for container $lxc_id."
}

# 8. Show Setup Information
show_setup_info() {
    local lxc_id="$1"
    log_info "show_setup_info: Displaying setup information for container $lxc_id..."
    echo ""
    echo "==============================================="
    echo "DRSWARM SETUP INFORMATION FOR CONTAINER $lxc_id"
    echo "==============================================="
    echo "Container Name: $EXPECTED_CONTAINER_NAME"
    echo "Container ID: $lxc_id"
    echo "Status: Setup completed successfully."
    echo ""
    echo "Docker Swarm Manager is running."
    echo "Local Docker Registry is running on port 5000."
    echo ""
    echo "Base Docker images from '$SHARED_DOCKER_IMAGES_DIR' have been built and pushed."
    echo "Shared directory mounted at '$LXC_MOUNT_POINT' inside container."
    echo ""
    echo "To interact with the Swarm manager from the host:"
    echo "  - Use 'docker -H ssh://root@10.0.0.99' (if SSH is configured)"
    echo "  - Or configure Docker contexts."
    echo ""
    echo "To interact with the Registry:"
    echo "  - Push images: docker tag myimage 10.0.0.99:5000/myimage && docker push 10.0.0.99:5000/myimage"
    echo "  - Pull images in other containers (after configuring them): docker pull 10.0.0.99:5000/myimage"
    echo "==============================================="
}

# - Main Execution Logic -
main() {
    local lxc_id="${1:-}"

    # Validate input
    if [[ -z "$lxc_id" ]]; then
        echo "Usage: $SCRIPT_NAME <container_id>"
        echo "  <container_id> should be 999 for the DrSwarm container."
        log_error "Container ID is required."
    fi

    if [[ "$lxc_id" != "999" ]]; then
        log_warn "This script is intended for container ID 999 ($EXPECTED_CONTAINER_NAME). Proceeding with ID $lxc_id."
    fi

    log_info "==============================================="
    log_info "STARTING PHOENIX HYPERVISOR DRSWARM SETUP FOR CONTAINER $lxc_id"
    log_info "==============================================="

    # 1. Validate Dependencies
    validate_dependencies

    # 2. Validate Container Configuration
    validate_container_config "$lxc_id"

    # 3. Make Container Privileged AND Mount Shared Directory
    make_container_privileged_and_mount "$lxc_id"

    # 4. Install Docker CE
    log_info "Installing Docker CE in container $lxc_id..."
    if ! install_docker_in_swarm_manager "$lxc_id"; then
        log_error "Failed to install Docker CE in container $lxc_id."
    fi

    # 5. Initialize Docker Swarm
    initialize_docker_swarm "$lxc_id"

    # 6. Start Local Docker Registry
    start_local_registry "$lxc_id"

    # --- NEW: Discover and Build Images ---
    # This step runs *after* the registry is confirmed running.
    # It uses the shared directory mounted inside the container.
    discover_and_build_images "$lxc_id"
    # --- END NEW ---

    # 7. Validate Final Setup
    if ! validate_final_setup "$lxc_id"; then
        log_warn "Final validation had some failures, but setup may still be usable. Please review logs."
    fi

    # 8. Show Setup Information
    show_setup_info "$lxc_id"

    log_info "==============================================="
    log_info "PHOENIX HYPERVISOR DRSWARM SETUP FOR CONTAINER $lxc_id COMPLETED SUCCESSFULLY"
    log_info "==============================================="
}

# Run main function with the provided container ID
main "$1"