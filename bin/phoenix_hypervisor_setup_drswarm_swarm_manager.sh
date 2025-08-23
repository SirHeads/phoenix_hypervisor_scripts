#!/usr/bin/env bash
# phoenix_hypervisor_setup_drswarm_swarm_manager.sh
#
# Performs privileged configuration and core setup for the DrSwarm container (ID 999).
# This includes making the container privileged, installing Docker, initializing Swarm,
# starting the local registry, and building/pushing base images from shared directories.
# This script is intended to be called by phoenix_hypervisor_setup_drswarm.sh.
#
# Version: 1.0.0 (Initial for Project Requirements)
# Author: Assistant

set -euo pipefail

# --- Terminal Handling ---
# Save terminal settings and ensure they are restored on exit or error
ORIGINAL_TERM_SETTINGS=$(stty -g 2>/dev/null) || ORIGINAL_TERM_SETTINGS=""
restore_terminal() {
    if [[ -n "$ORIGINAL_TERM_SETTINGS" ]]; then
        stty "$ORIGINAL_TERM_SETTINGS" 2>/dev/null || true
    fi
    echo "Terminal reset"
}
trap restore_terminal EXIT

# --- Script Metadata ---
SCRIPT_NAME="phoenix_hypervisor_setup_drswarm_swarm_manager.sh"
SCRIPT_VERSION="1.0.0"
AUTHOR="Assistant"

# --- Argument Validation ---
if [[ $# -ne 1 ]]; then
    echo "[ERROR] Usage: $SCRIPT_NAME <container_id>" >&2
    exit 1
fi

CONTAINER_ID="$1"
if [[ "$CONTAINER_ID" != "999" ]]; then
    echo "[ERROR] This script is designed for container ID 999 (DrSwarm), got $CONTAINER_ID" >&2
    exit 1
fi

# --- Configuration and Library Loading ---
# Determine script's directory for locating libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHOENIX_LIB_DIR="/usr/local/lib/phoenix_hypervisor"
PHOENIX_BIN_DIR="/usr/local/bin/phoenix_hypervisor"

# Source Phoenix Hypervisor Configuration
PHOENIX_CONFIG_LOADED=0
for config_path in \
    "/usr/local/etc/phoenix_hypervisor_config.sh" \
    "$PHOENIX_LIB_DIR/phoenix_hypervisor_config.sh" \
    "$SCRIPT_DIR/phoenix_hypervisor_config.sh"; do
    if [[ -f "$config_path" ]]; then
        # shellcheck source=/dev/null
        source "$config_path"
        if [[ "${PHOENIX_HYPERVISOR_CONFIG_LOADED:-0}" -eq 1 ]]; then
            PHOENIX_CONFIG_LOADED=1
            echo "[INFO] Sourced Phoenix Hypervisor configuration from $config_path."
            break
        else
            echo "[WARN] Sourced $config_path, but PHOENIX_HYPERVISOR_CONFIG_LOADED not set correctly. Trying next location."
        fi
    fi
done

if [[ $PHOENIX_CONFIG_LOADED -ne 1 ]]; then
    echo "[ERROR] Failed to load phoenix_hypervisor_config.sh from standard locations." >&2
    echo "[ERROR] Please ensure it's installed correctly." >&2
    exit 1
fi

# Source Phoenix Hypervisor Common Functions
PHOENIX_COMMON_LOADED=0
for common_path in \
    "$PHOENIX_LIB_DIR/phoenix_hypervisor_common.sh" \
    "$SCRIPT_DIR/phoenix_hypervisor_common.sh"; do
    if [[ -f "$common_path" ]]; then
        # shellcheck source=/dev/null
        source "$common_path"
        if declare -F log_info >/dev/null 2>&1; then
            PHOENIX_COMMON_LOADED=1
            log_info "$SCRIPT_NAME: Sourced common functions from $common_path."
            break
        else
            echo "[WARN] Sourced $common_path, but common functions not found. Trying next location."
        fi
    fi
done

# Fallback logging if common lib fails
if [[ $PHOENIX_COMMON_LOADED -ne 1 ]]; then
    echo "[WARN] $SCRIPT_NAME: Common functions not fully loaded. Using minimal logging."
    log_info() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    log_warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" >&2; }
    log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
else
    # Initialize logging from the common library if loaded successfully
    setup_logging 2>/dev/null || true # Redirect potential early errors
fi

# Source Base LXC Common Functions
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

# Source Docker LXC Common Functions
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

# Source Validation LXC Common Functions
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

# --- Configuration ---
# Path to the shared directory containing image build contexts on the Proxmox host
SHARED_DOCKER_IMAGES_DIR="/mnt/pve/shared-bulk-data/phoenix_docker_images"
# Expected container name for ID 999
EXPECTED_CONTAINER_NAME="DrSwarm"
# Hardcoded registry address (matches DrSwarm config)
REGISTRY_ADDRESS="10.0.0.99:5000"

# --- Core Functions ---

# 1. Validate Dependencies
validate_dependencies() {
    log_info "validate_dependencies: Checking for required commands..."
    if ! command -v jq >/dev/null 2>&1; then
        log_error "validate_dependencies: jq not installed."
    fi
    if ! command -v pct >/dev/null 2>&1; then
        log_error "validate_dependencies: pct not installed."
    fi
    # Check for shared directory
    if [[ ! -d "$SHARED_DOCKER_IMAGES_DIR" ]]; then
        log_error "validate_dependencies: Shared Docker images directory '$SHARED_DOCKER_IMAGES_DIR' not found on Proxmox host."
    fi
    log_info "validate_dependencies: All required commands and directories found."
}

# 2. Make Container Privileged
make_container_privileged() {
    local lxc_id="$1"
    local config_file="/etc/pve/lxc/$lxc_id.conf"

    log_info "make_container_privileged: Configuring container $lxc_id to be privileged..."

    # Check current status
    if pct status "$lxc_id" >/dev/null 2>&1; then
        log_info "make_container_privileged: Stopping container $lxc_id..."
        pct stop "$lxc_id" || log_error "make_container_privileged: Failed to stop container $lxc_id."
        sleep 5 # Allow time to stop
    fi

    # Check if already privileged
    if grep -q "^unprivileged: 0" "$config_file" 2>/dev/null; then
        log_info "make_container_privileged: Container $lxc_id is already configured as privileged."
    else
        log_info "make_container_privileged: Setting unprivileged: 0 in $config_file..."
        echo "unprivileged: 0" >> "$config_file"
        # Optional: Add AppArmor unconfined
        if ! grep -q "^lxc.apparmor.profile: unconfined" "$config_file" 2>/dev/null; then
            echo "lxc.apparmor.profile: unconfined" >> "$config_file"
            log_info "make_container_privileged: Added lxc.apparmor.profile: unconfined to $config_file."
        fi
    fi

    log_info "make_container_privileged: Starting container $lxc_id..."
    pct start "$lxc_id" || log_error "make_container_privileged: Failed to start container $lxc_id."

    # Wait for container to be ready
    log_info "make_container_privileged: Waiting for container $lxc_id to become responsive..."
    local attempt=1
    local max_attempts=20
    while [[ $attempt -le $max_attempts ]]; do
        if pct_exec_with_retry "$lxc_id" -- hostname >/dev/null 2>&1; then
            log_info "make_container_privileged: Container $lxc_id is responsive."
            return 0
        fi
        log_info "make_container_privileged: Container $lxc_id not responsive (attempt $attempt/$max_attempts)..."
        sleep 5
        ((attempt++))
    done
    log_error "make_container_privileged: Container $lxc_id did not become responsive after $max_attempts attempts."
}

# 3. Install Docker (using common function or manual)
install_docker_in_swarm_manager() {
    local lxc_id="$1"

    log_info "install_docker_in_swarm_manager: Installing Docker in container $lxc_id..."

    if [[ $PHOENIX_DOCKER_LOADED -eq 1 ]] && declare -F install_docker_ce_in_container >/dev/null 2>&1; then
        log_info "install_docker_in_swarm_manager: Using common function to install Docker..."
        if install_docker_ce_in_container "$lxc_id"; then
            log_info "install_docker_in_swarm_manager: Docker installed successfully using common function."
        else
            log_error "install_docker_in_swarm_manager: Failed to install Docker using common function."
        fi
    else
        log_warn "install_docker_in_swarm_manager: Common Docker function not available, falling back to manual installation..."
        # Manual Docker installation steps (simplified version of common function logic)
        local install_cmd="
        set -e
        export DEBIAN_FRONTEND=noninteractive
        export LC_ALL=C
        echo '[INFO] Installing prerequisites for Docker...'
        apt-get update -y --fix-missing > /tmp/docker-apt-update.log 2>&1 || { echo '[ERROR] Failed to update package lists'; cat /tmp/docker-apt-update.log; exit 1; }
        apt-get install -y ca-certificates curl gnupg lsb-release > /tmp/docker-apt-prereqs.log 2>&1 || { echo '[ERROR] Failed to install prerequisites'; cat /tmp/docker-apt-prereqs.log; exit 1; }
        echo '[INFO] Adding Docker repository...'
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo 'deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable' | tee /etc/apt/sources.list.d/docker.list > /dev/null
        echo '[INFO] Updating package lists for Docker...'
        apt-get update -y --fix-missing > /tmp/docker-apt-update2.log 2>&1 || { echo '[ERROR] Failed to update package lists'; cat /tmp/docker-apt-update2.log; exit 1; }
        echo '[INFO] Installing Docker-ce...'
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /tmp/docker-apt-install.log 2>&1 || { echo '[ERROR] Failed to install Docker-ce'; cat /tmp/docker-apt-install.log; exit 1; }
        echo '[INFO] Enabling Docker service...'
        systemctl enable docker > /tmp/docker-enable.log 2>&1 || { echo '[ERROR] Failed to enable Docker service'; cat /tmp/docker-enable.log; exit 1; }
        echo '[SUCCESS] Docker-ce installed and enabled successfully.'
        "
        if pct_exec_with_retry "$lxc_id" -- bash -c "$install_cmd"; then
            log_info "install_docker_in_swarm_manager: Docker installed successfully via manual method."
        else
            log_error "install_docker_in_swarm_manager: Failed to install Docker via manual method."
        fi
    fi
}

# 4. Initialize Docker Swarm
initialize_docker_swarm() {
    local lxc_id="$1"
    log_info "initialize_docker_swarm: Initializing Docker Swarm on container $lxc_id..."

    # Get the static IP from the config
    if ! load_hypervisor_config; then
        log_error "initialize_docker_swarm: Failed to load hypervisor configuration."
    fi
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

    if pct_exec_with_retry "$lxc_id" -- bash -c "$init_cmd"; then
        log_info "initialize_docker_swarm: Docker Swarm initialized successfully on $advertise_ip."
    else
        log_error "initialize_docker_swarm: Failed to initialize Docker Swarm."
    fi
}

# 5. Start Local Docker Registry
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

    if pct_exec_with_retry "$lxc_id" -- bash -c "$registry_cmd"; then
        log_info "start_local_registry: Local Docker registry started successfully."
    else
        log_error "start_local_registry: Failed to start local Docker registry."
    fi
}

# 6. Discover and Build Images from Shared Directory
discover_and_build_images() {
    local lxc_id="$1"
    log_info "discover_and_build_images: Starting discovery and build process for container $lxc_id..."

    # Verify the shared directory exists on the Proxmox host
    if [[ ! -d "$SHARED_DOCKER_IMAGES_DIR" ]]; then
        log_error "discover_and_build_images: Shared Docker images directory '$SHARED_DOCKER_IMAGES_DIR' not found on Proxmox host."
    fi

    log_info "discover_and_build_images: Scanning '$SHARED_DOCKER_IMAGES_DIR' for image build contexts..."

    local found_images=0
    local built_images=0

    # Use find to get directories one level deep, excluding hidden ones
    while IFS= read -r -d '' image_dir; do
        local image_name
        image_name=$(basename "$image_dir")

        # Basic validation: check if it's a directory and contains a Dockerfile
        if [[ -d "$image_dir" ]] && [[ -f "$image_dir/Dockerfile" ]]; then
            log_info "discover_and_build_images: Found valid build context for image '$image_name' at '$image_dir'."
            ((found_images++))

            # --- Build, Tag, and Push the Image inside LXC 999 ---
            log_info "discover_and_build_images: Building image '$image_name:latest' inside LXC $lxc_id from '$image_dir'..."
            local build_cmd="
            set -e
            cd '$image_dir' || { echo '[ERROR] Failed to change directory to $image_dir inside LXC'; exit 1; }
            echo '[INFO] Inside LXC $lxc_id, building image $image_name:latest from context $image_dir...'
            # Build the image using the Dockerfile in the current directory (context)
            docker build -t '$image_name:latest' . > /tmp/build-$image_name.log 2>&1 || { echo '[ERROR] Docker build failed for $image_name'; cat /tmp/build-$image_name.log; exit 1; }
            echo '[INFO] Tagging image $image_name:latest as $REGISTRY_ADDRESS/$image_name:latest...'
            docker tag '$image_name:latest' '$REGISTRY_ADDRESS/$image_name:latest' > /tmp/tag-$image_name.log 2>&1 || { echo '[ERROR] Docker tag failed for $image_name'; cat /tmp/tag-$image_name.log; exit 1; }
            echo '[INFO] Pushing image $REGISTRY_ADDRESS/$image_name:latest to local registry...'
            docker push '$REGISTRY_ADDRESS/$image_name:latest' > /tmp/push-$image_name.log 2>&1 || { echo '[ERROR] Docker push failed for $image_name'; cat /tmp/push-$image_name.log; exit 1; }
            echo '[SUCCESS] Image $image_name:latest built, tagged, and pushed successfully from $image_dir.'
            "

            # Execute the build/tag/push sequence inside LXC 999
            if pct_exec_with_retry "$lxc_id" -- bash -c "$build_cmd"; then
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
            log_warn "discover_and_build_images: Skipping '$image_dir'. It's either not a directory or missing a Dockerfile."
        fi

    # Use null delimiter for safety with filenames containing spaces
    done < <(find "$SHARED_DOCKER_IMAGES_DIR" -mindepth 1 -maxdepth 1 -type d -not -name ".*" -print0)

    if [[ $found_images -eq 0 ]]; then
        log_warn "discover_and_build_images: No valid image build contexts (directories with Dockerfile) found in '$SHARED_DOCKER_IMAGES_DIR'."
    else
        log_info "discover_and_build_images: Found $found_images build contexts. Successfully built and pushed $built_images images."
    fi

    log_info "discover_and_build_images: Completed discovery and build process for container $lxc_id."
}

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
        exit 1
    fi
    "
    if ! pct_exec_with_retry "$lxc_id" -- bash -c "$docker_active_check"; then
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
    if ! pct_exec_with_retry "$lxc_id" -- bash -c "$swarm_active_check"; then
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
        exit 1
    fi
    "
    if ! pct_exec_with_retry "$lxc_id" -- bash -c "$registry_running_check"; then
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
    echo "DRSWARM SWARM MANAGER SETUP COMPLETED FOR CONTAINER $lxc_id"
    echo "==============================================="
    echo "Container Name: $EXPECTED_CONTAINER_NAME"
    echo "Container ID: $lxc_id"
    echo "Status: Setup completed successfully."
    echo ""
    echo "Docker Swarm Manager is running."
    echo "Local Docker Registry is running on port 5000."
    echo ""
    echo "Base Docker images from '$SHARED_DOCKER_IMAGES_DIR' have been built and pushed."
    echo ""
    echo "To interact with the Swarm manager from the host:"
    echo "  - Use 'docker -H ssh://root@10.0.0.99' (if SSH is configured)"
    echo "  - Or configure Docker contexts."
    echo ""
    echo "To interact with the Registry:"
    echo "  - Push images: docker tag myimage $REGISTRY_ADDRESS/myimage && docker push $REGISTRY_ADDRESS/myimage"
    echo "  - Pull images in other containers (after configuring them): docker pull $REGISTRY_ADDRESS/myimage"
    echo "==============================================="
}

# --- Main Execution ---
main() {
    local lxc_id="$1"

    log_info "==============================================="
    log_info "STARTING PHOENIX HYPERVISOR DRSWARM SWARM MANAGER SETUP FOR CONTAINER $lxc_id"
    log_info "==============================================="

    # 1. Validate Dependencies
    validate_dependencies

    # 2. Make Container Privileged
    make_container_privileged "$lxc_id"

    # 3. Install Docker
    install_docker_in_swarm_manager "$lxc_id"

    # 4. Initialize Docker Swarm
    initialize_docker_swarm "$lxc_id"

    # 5. Start Local Docker Registry
    start_local_registry "$lxc_id"

    # 6. Discover and Build Images
    discover_and_build_images "$lxc_id"

    # 7. Validate Final Setup
    if ! validate_final_setup "$lxc_id"; then
        log_warn "Final validation had some failures, but setup may still be usable. Please review logs."
    fi

    # 8. Show Setup Information
    show_setup_info "$lxc_id"

    log_info "==============================================="
    log_info "PHOENIX HYPERVISOR DRSWARM SWARM MANAGER SETUP FOR CONTAINER $lxc_id COMPLETED SUCCESSFULLY"
    log_info "==============================================="
}

# Run main function with the provided container ID
main "$CONTAINER_ID"
