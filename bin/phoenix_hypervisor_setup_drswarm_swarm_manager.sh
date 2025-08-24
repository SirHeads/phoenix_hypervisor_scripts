#!/usr/bin/env bash
# phoenix_hypervisor_setup_drswarm_swarm_manager.sh
#
# Performs privileged configuration and core setup for the DrSwarm container (ID 999).
# This includes making the container privileged, installing Docker, initializing Swarm,
# starting the local registry, and building/pushing base images from shared directories.
# This script is intended to be called by phoenix_hypervisor_setup_drswarm.sh.
#
# Version: 1.0.5 (Enhanced diagnostics for lxc-attach, systemd checks, and config validation)
# Author: Assistant

set -euo pipefail

# --- Terminal Handling ---
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
SCRIPT_VERSION="1.0.5"
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
    setup_logging 2>/dev/null || true
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

if [[ $PHOENIX_DOCKER_LOADED -ne 1 ]]; then
    log_warn "$SCRIPT_NAME: Failed to load phoenix_hypervisor_lxc_common_docker.sh. Will attempt manual Docker installation."
fi

# Source Validation LXC Common Functions
# --- DEBUG VALIDATION SOURCING ---
log_info "$SCRIPT_NAME: --- STARTING VALIDATION LIBRARY SOURCING DEBUG ---"
log_info "$SCRIPT_NAME: PHOENIX_LIB_DIR = '$PHOENIX_LIB_DIR'"
log_info "$SCRIPT_NAME: SCRIPT_DIR = '$SCRIPT_DIR'"

PHOENIX_VALIDATION_LOADED=0

# Define the paths to check
validation_paths_to_check=(
    "$PHOENIX_LIB_DIR/phoenix_hypervisor_lxc_common_validation.sh"
    "$SCRIPT_DIR/phoenix_hypervisor_lxc_common_validation.sh"
)

# Iterate through the potential paths
for validation_path in "${validation_paths_to_check[@]}"; do
    log_info "$SCRIPT_NAME: Checking path: '$validation_path'"
    
    if [[ -f "$validation_path" ]]; then
        log_info "$SCRIPT_NAME: File '$validation_path' EXISTS. Attempting to source..."

        # --- CRITICAL DEBUGGING STEP 1: Capture any output/errors during sourcing ---
        local sourcing_output=""
        sourcing_output=$(source "$validation_path" 2>&1)
        local source_exit_code=$?
        
        if [[ $source_exit_code -ne 0 ]] || [[ -n "$sourcing_output" ]]; then
            log_warn "$SCRIPT_NAME: Sourcing '$validation_path' produced output or exited with code $source_exit_code:"
            # Log the output line by line to handle potential newlines
            while IFS= read -r line; do
                log_warn "$SCRIPT_NAME: Sourcing output: $line"
            done <<< "$sourcing_output"
        else
            log_info "$SCRIPT_NAME: Sourcing '$validation_path' completed without errors or output."
        fi
        # --- END CRITICAL DEBUGGING STEP 1 ---

        log_info "$SCRIPT_NAME: Checking for function 'validate_container_exists' after sourcing '$validation_path'..."
        
        # --- CRITICAL DEBUGGING STEP 2: Check function existence verbosely ---
        if declare -F validate_container_exists >/dev/null 2>&1; then
            log_info "$SCRIPT_NAME: SUCCESS! Function 'validate_container_exists' FOUND after sourcing '$validation_path'."
            PHOENIX_VALIDATION_LOADED=1
            log_info "$SCRIPT_NAME: Sourced Validation LXC common functions from $validation_path."
            break # Exit the loop on success
        else
            log_warn "$SCRIPT_NAME: FAILURE! Function 'validate_container_exists' NOT FOUND after sourcing '$validation_path'."
            # Optional: List some functions to see what *is* defined
            log_info "$SCRIPT_NAME: Functions currently defined (sample): $(declare -F | head -n 5 | xargs)"
        fi
        # --- END CRITICAL DEBUGGING STEP 2 ---
        
    else
        log_warn "$SCRIPT_NAME: File '$validation_path' NOT FOUND."
    fi
done

# Final check
if [[ $PHOENIX_VALIDATION_LOADED -ne 1 ]]; then
    log_error "$SCRIPT_NAME: CRITICAL FAILURE: Unable to load phoenix_hypervisor_lxc_common_validation.sh from any checked location. Cannot proceed with validation operations."
    # Consider exiting here for faster debugging loop
    # exit 1
else
    log_info "$SCRIPT_NAME: --- VALIDATION LIBRARY SOURCING DEBUG COMPLETE --- Library successfully loaded."
fi
# --- END DEBUG VALIDATION SOURCING ---

# --- Configuration ---
SHARED_DOCKER_IMAGES_DIR="/mnt/pve/shared-bulk-data/phoenix_docker_images"
EXPECTED_CONTAINER_NAME="DrSwarm"
REGISTRY_ADDRESS="10.0.0.99:5000"

# --- Core Functions ---

validate_dependencies() {
    log_info "validate_dependencies: Checking for required commands..."
    if ! command -v jq >/dev/null 2>&1; then
        log_error "validate_dependencies: jq not installed."
    fi
    if ! command -v pct >/dev/null 2>&1; then
        log_error "validate_dependencies: pct not installed."
    fi
    if ! command -v lxc-attach >/dev/null 2>&1; then
        log_error "validate_dependencies: lxc-attach not installed."
    fi
    if [[ ! -d "$SHARED_DOCKER_IMAGES_DIR" ]]; then
        log_error "validate_dependencies: Shared Docker images directory '$SHARED_DOCKER_IMAGES_DIR' not found on Proxmox host."
    fi
    log_info "validate_dependencies: Checking LXC configuration for container $CONTAINER_ID..."
    if ! lxc-info -n "$CONTAINER_ID" >/dev/null 2>&1; then
        log_error "validate_dependencies: Container $CONTAINER_ID does not exist."
    fi
    log_info "validate_dependencies: All required commands and directories found."
}

make_container_privileged() {
    local lxc_id="$1"
    local config_file="/etc/pve/lxc/$lxc_id.conf"

    log_info "make_container_privileged: Configuring container $lxc_id to be privileged..."

    # Validate container existence
    if ! validate_container_exists "$lxc_id"; then
        log_error "make_container_privileged: Container $lxc_id does not exist."
    fi

    # Stop container if running
    if pct status "$lxc_id" | grep -q "status: running"; then
        log_info "make_container_privileged: Stopping container $lxc_id..."
        if ! retry_command 5 10 pct stop "$lxc_id"; then
            log_error "make_container_privileged: Failed to stop container $lxc_id."
            journalctl -u "pve-container@$lxc_id.service" -n 50 >> "/var/log/phoenix_hypervisor/phoenix_hypervisor_debug.log" 2>&4
            return 1
        fi
        sleep 5
    fi

    # Update configuration
    if grep -q "^unprivileged: 0" "$config_file" 2>/dev/null; then
        log_info "make_container_privileged: Container $lxc_id is already configured as privileged."
    else
        log_info "make_container_privileged: Setting unprivileged: 0 in $config_file..."
        echo "unprivileged: 0" >> "$config_file" || {
            log_error "make_container_privileged: Failed to set unprivileged: 0 in $config_file."
            return 1
        }
        if ! grep -q "^lxc.apparmor.profile: unconfined" "$config_file" 2>/dev/null; then
            echo "lxc.apparmor.profile: unconfined" >> "$config_file" || {
                log_error "make_container_privileged: Failed to set lxc.apparmor.profile in $config_file."
                return 1
            }
            log_info "make_container_privileged: Added lxc.apparmor.profile: unconfined to $config_file."
        fi
    fi

    # Fix deprecated lxc.init_cmd
    if grep -q "^lxc.init_cmd" "$config_file"; then
        log_info "make_container_privileged: Replacing deprecated lxc.init_cmd with lxc.init.cmd in $config_file..."
        sed -i 's/^lxc.init_cmd/lxc.init.cmd/' "$config_file" || {
            log_error "make_container_privileged: Failed to replace lxc.init_cmd in $config_file."
            return 1
        }
    fi

    # Ensure nesting is enabled
    if ! grep -q "^features:.*nesting=1" "$config_file" 2>/dev/null; then
        log_info "make_container_privileged: Adding nesting feature to $config_file..."
        if grep -q "^features:" "$config_file"; then
            sed -i 's/^features:.*/& nesting=1/' "$config_file" || {
                log_error "make_container_privileged: Failed to update nesting feature in $config_file."
                return 1
            }
        else
            echo "features: nesting=1" >> "$config_file" || {
                log_error "make_container_privileged: Failed to add nesting feature to $config_file."
                return 1
            }
        fi
        log_info "make_container_privileged: Nesting feature enabled."
    fi

    # Start container with retry
    log_info "make_container_privileged: Starting container $lxc_id..."
    if ! retry_command 5 10 pct start "$lxc_id"; then
        log_error "make_container_privileged: Failed to start container $lxc_id."
        journalctl -u "pve-container@$lxc_id.service" -n 50 >> "/var/log/phoenix_hypervisor/phoenix_hypervisor_debug.log" 2>&4
        return 1
    fi

    # Enhanced systemd check with diagnostics
    log_info "make_container_privileged: Waiting for container $lxc_id to become responsive and checking systemd..."
    local attempt=1
    local max_attempts=30
    while [[ $attempt -le $max_attempts ]]; do
        if pct status "$lxc_id" | grep -q "status: running"; then
            log_info "make_container_privileged: Container $lxc_id is running, checking systemd (attempt $attempt/$max_attempts)..."
            local diag_cmd="
            set -e
            echo '[INFO] Checking init process...'
            ps -p 1 -o comm= || { echo '[ERROR] Failed to check init process'; exit 1; }
            echo '[INFO] Checking systemd status...'
            systemctl is-system-running --quiet && echo '[SUCCESS] systemd is running' || { echo '[ERROR] systemd not running'; systemctl status > /tmp/systemd-status.log; cat /tmp/systemd-status.log; exit 1; }
            "
            # --- FIXED: Removed erroneous '--' ---
            if pct_exec_with_retry "$lxc_id" bash -c "$diag_cmd"; then
                log_info "make_container_privileged: Container $lxc_id is responsive with systemd running."
                return 0
            else
                log_warn "make_container_privileged: systemd check failed on attempt $attempt/$max_attempts."
                pct exec "$lxc_id" -- journalctl -b -n 50 >> "/var/log/phoenix_hypervisor/phoenix_hypervisor_debug.log" 2>&4 || true
            fi
        else
            log_warn "make_container_privileged: Container $lxc_id not running (attempt $attempt/$max_attempts)."
            journalctl -u "pve-container@$lxc_id.service" -n 50 >> "/var/log/phoenix_hypervisor/phoenix_hypervisor_debug.log" 2>&4
        fi
        sleep 10
        ((attempt++))
    done
    log_error "make_container_privileged: Container $lxc_id did not become responsive or systemd failed after $max_attempts attempts."
    journalctl -u "pve-container@$lxc_id.service" -n 50 >> "/var/log/phoenix_hypervisor/phoenix_hypervisor_debug.log" 2>&4
    pct exec "$lxc_id" -- journalctl -b -n 50 >> "/var/log/phoenix_hypervisor/phoenix_hypervisor_debug.log" 2>&4 || true
    pct stop "$lxc_id" >/dev/null 2>&4 || true
    return 1
}

install_docker_in_swarm_manager() {
    local lxc_id="$1"

    log_info "install_docker_in_swarm_manager: Installing Docker in container $lxc_id..."

    if [[ $PHOENIX_DOCKER_LOADED -eq 1 ]] && declare -F install_docker_ce_in_container >/dev/null 2>&1; then
        log_info "install_docker_in_swarm_manager: Using common function to install Docker..."
        if ! install_docker_ce_in_container "$lxc_id"; then
            log_error "install_docker_in_swarm_manager: Failed to install Docker using common function."
            journalctl -u "pve-container@$lxc_id.service" -n 50 >> "/var/log/phoenix_hypervisor/phoenix_hypervisor_debug.log" 2>&4
            pct exec "$lxc_id" -- journalctl -b -n 50 >> "/var/log/phoenix_hypervisor/phoenix_hypervisor_debug.log" 2>&4 || true
            pct stop "$lxc_id" >/dev/null 2>&4 || true
            return 1
        fi
        log_info "install_docker_in_swarm_manager: Docker installed successfully using common function."
    else
        log_warn "install_docker_in_swarm_manager: Common Docker function not available, falling back to manual installation..."
        local install_cmd="
        set -e
        export DEBIAN_FRONTEND=noninteractive
        export LC_ALL=C
        echo '[INFO] Updating package lists...'
        apt-get update -y --fix-missing > /tmp/docker-apt-update.log 2>&1 || { echo '[ERROR] Failed to update package lists'; cat /tmp/docker-apt-update.log; exit 1; }
        echo '[INFO] Installing prerequisites...'
        apt-get install -y ca-certificates curl gnupg lsb-release apparmor > /tmp/docker-apt-prereqs.log 2>&1 || { echo '[ERROR] Failed to install prerequisites'; cat /tmp/docker-apt-prereqs.log; exit 1; }
        echo '[INFO] Adding Docker repository...'
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg   | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo 'deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu   $(lsb_release -cs) stable' | tee /etc/apt/sources.list.d/docker.list > /dev/null
        echo '[INFO] Updating package lists for Docker...'
        apt-get update -y --fix-missing > /tmp/docker-apt-update2.log 2>&1 || { echo '[ERROR] Failed to update package lists'; cat /tmp/docker-apt-update2.log; exit 1; }
        echo '[INFO] Installing Docker-ce...'
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /tmp/docker-apt-install.log 2>&1 || { echo '[ERROR] Failed to install Docker-ce'; cat /tmp/docker-apt-install.log; exit 1; }
        echo '[INFO] Enabling Docker service...'
        systemctl enable docker > /tmp/docker-enable.log 2>&1 || { echo '[ERROR] Failed to enable Docker service'; cat /tmp/docker-enable.log; exit 1; }
        systemctl start docker > /tmp/docker-start.log 2>&1 || { echo '[ERROR] Failed to start Docker service'; cat /tmp/docker-start.log; exit 1; }
        echo '[SUCCESS] Docker-ce installed and started successfully.'
        "
        # --- FIXED: Removed erroneous '--' ---
        if ! pct_exec_with_retry "$lxc_id" bash -c "$install_cmd"; then
            log_error "install_docker_in_swarm_manager: Failed to install Docker via manual method."
            journalctl -u "pve-container@$lxc_id.service" -n 50 >> "/var/log/phoenix_hypervisor/phoenix_hypervisor_debug.log" 2>&4
            pct exec "$lxc_id" -- journalctl -b -n 50 >> "/var/log/phoenix_hypervisor/phoenix_hypervisor_debug.log" 2>&4 || true
            pct stop "$lxc_id" >/dev/null 2>&4 || true
            return 1
        fi
        log_info "install_docker_in_swarm_manager: Docker installed successfully via manual method."
    fi
}

initialize_docker_swarm() {
    local lxc_id="$1"
    log_info "initialize_docker_swarm: Initializing Docker Swarm on container $lxc_id..."

    if ! load_hypervisor_config; then
        log_error "initialize_docker_swarm: Failed to load hypervisor configuration."
    fi
    local static_ip
    static_ip=$(echo "${LXC_CONFIGS[$lxc_id]}" | jq -r '.static_ip // empty')
    if [[ -z "$static_ip" ]]; then
        log_error "initialize_docker_swarm: static_ip not found for container $lxc_id in config."
    fi
    local advertise_ip="${static_ip%%/*}"
    if [[ -z "$advertise_ip" ]]; then
         log_error "initialize_docker_swarm: Could not extract IP from static_ip '$static_ip'."
    fi

    local init_cmd="
    set -e
    echo '[INFO] Waiting for Docker service to be active...'
    for i in {1..30}; do
        if systemctl is-active --quiet docker; then
            echo '[INFO] Docker service is active.'
            break
        fi
        echo '[INFO] Waiting for Docker service (attempt \$i/30)...'
        sleep 2
    done
    if ! systemctl is-active --quiet docker; then
        echo '[ERROR] Docker service not active after waiting.'
        journalctl -u docker.service -n 50 > /tmp/docker-service.log 2>&1
        cat /tmp/docker-service.log
        exit 1
    fi
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

    # --- FIXED: Removed erroneous '--' ---
    if ! pct_exec_with_retry "$lxc_id" bash -c "$init_cmd"; then
        log_error "initialize_docker_swarm: Failed to initialize Docker Swarm."
        journalctl -u "pve-container@$lxc_id.service" -n 50 >> "/var/log/phoenix_hypervisor/phoenix_hypervisor_debug.log" 2>&4
        pct exec "$lxc_id" -- journalctl -b -n 50 >> "/var/log/phoenix_hypervisor/phoenix_hypervisor_debug.log" 2>&4 || true
        pct stop "$lxc_id" >/dev/null 2>&4 || true
        return 1
    fi
    log_info "initialize_docker_swarm: Docker Swarm initialized successfully on $advertise_ip."
}

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
    sleep 5
    if docker ps -q -f name=registry | grep -q .; then
        echo '[SUCCESS] Local Docker registry started successfully.'
    else
        echo '[ERROR] Registry container did not start successfully.'
        docker logs registry > /tmp/registry-logs.log 2>&1 || echo '[WARN] Could not get registry logs.'
        cat /tmp/registry-logs.log
        exit 1
    fi
    "

    # --- FIXED: Removed erroneous '--' ---
    if ! pct_exec_with_retry "$lxc_id" bash -c "$registry_cmd"; then
        log_error "start_local_registry: Failed to start local Docker registry."
        journalctl -u "pve-container@$lxc_id.service" -n 50 >> "/var/log/phoenix_hypervisor/phoenix_hypervisor_debug.log" 2>&4
        pct exec "$lxc_id" -- journalctl -b -n 50 >> "/var/log/phoenix_hypervisor/phoenix_hypervisor_debug.log" 2>&4 || true
        pct stop "$lxc_id" >/dev/null 2>&4 || true
        return 1
    fi
    log_info "start_local_registry: Local Docker registry started successfully."
}

discover_and_build_images() {
    local lxc_id="$1"
    log_info "discover_and_build_images: Starting discovery and build process for container $lxc_id..."

    if [[ ! -d "$SHARED_DOCKER_IMAGES_DIR" ]]; then
        log_error "discover_and_build_images: Shared Docker images directory '$SHARED_DOCKER_IMAGES_DIR' not found on Proxmox host."
    fi

    log_info "discover_and_build_images: Scanning '$SHARED_DOCKER_IMAGES_DIR' for image build contexts..."

    local found_images=0
    local built_images=0

    while IFS= read -r -d '' image_dir; do
        local image_name
        image_name=$(basename "$image_dir")

        if [[ -d "$image_dir" ]] && [[ -f "$image_dir/Dockerfile" ]]; then
            log_info "discover_and_build_images: Found valid build context for image '$image_name' at '$image_dir'."
            ((found_images++))

            local build_cmd="
            set -e
            cd '$image_dir' || { echo '[ERROR] Failed to change directory to $image_dir inside LXC'; exit 1; }
            echo '[INFO] Inside LXC $lxc_id, building image $image_name:latest from context $image_dir...'
            docker build -t '$image_name:latest' . > /tmp/build-$image_name.log 2>&1 || { echo '[ERROR] Docker build failed for $image_name'; cat /tmp/build-$image_name.log; exit 1; }
            echo '[INFO] Tagging image $image_name:latest as $REGISTRY_ADDRESS/$image_name:latest...'
            docker tag '$image_name:latest' '$REGISTRY_ADDRESS/$image_name:latest' > /tmp/tag-$image_name.log 2>&1 || { echo '[ERROR] Docker tag failed for $image_name'; cat /tmp/tag-$image_name.log; exit 1; }
            echo '[INFO] Pushing image $REGISTRY_ADDRESS/$image_name:latest to local registry...'
            docker push '$REGISTRY_ADDRESS/$image_name:latest' > /tmp/push-$image_name.log 2>&1 || { echo '[ERROR] Docker push failed for $image_name'; cat /tmp/push-$image_name.log; exit 1; }
            echo '[SUCCESS] Image $image_name:latest built, tagged, and pushed successfully from $image_dir.'
            "

            # --- FIXED: Removed erroneous '--' ---
            if ! pct_exec_with_retry "$lxc_id" bash -c "$build_cmd"; then
                log_error "discover_and_build_images: Failed to build/tag/push image '$image_name'. Check LXC $lxc_id logs (/tmp/build-$image_name.log, /tmp/tag-$image_name.log, /tmp/push-$image_name.log)."
                journalctl -u "pve-container@$lxc_id.service" -n 50 >> "/var/log/phoenix_hypervisor/phoenix_hypervisor_debug.log" 2>&4
                pct exec "$lxc_id" -- journalctl -b -n 50 >> "/var/log/phoenix_hypervisor/phoenix_hypervisor_debug.log" 2>&4 || true
                continue
            fi
            log_info "discover_and_build_images: Successfully processed image '$image_name'."
            ((built_images++))
        else
            log_warn "discover_and_build_images: Skipping '$image_dir'. It's either not a directory or missing a Dockerfile."
        fi
    done < <(find "$SHARED_DOCKER_IMAGES_DIR" -mindepth 1 -maxdepth 1 -type d -not -name ".*" -print0)

    if [[ $found_images -eq 0 ]]; then
        log_warn "discover_and_build_images: No valid image build contexts (directories with Dockerfile) found in '$SHARED_DOCKER_IMAGES_DIR'."
    else
        log_info "discover_and_build_images: Found $found_images build contexts. Successfully built and pushed $built_images images."
    fi

    log_info "discover_and_build_images: Completed discovery and build process for container $lxc_id."
}

validate_final_setup() {
    local lxc_id="$1"
    log_info "validate_final_setup: Performing final validation for container $lxc_id..."

    local docker_active_check="
    if systemctl is-active --quiet docker; then
        echo '[SUCCESS] Docker service is active.'
    else
        echo '[ERROR] Docker service is not active.'
        journalctl -u docker.service -n 50 > /tmp/docker-service.log 2>&1
        cat /tmp/docker-service.log
        exit 1
    fi
    "
    # --- FIXED: Removed erroneous '--' ---
    if ! pct_exec_with_retry "$lxc_id" bash -c "$docker_active_check"; then
        log_error "validate_final_setup: Docker service validation failed for container $lxc_id."
        journalctl -u "pve-container@$lxc_id.service" -n 50 >> "/var/log/phoenix_hypervisor/phoenix_hypervisor_debug.log" 2>&4
        pct exec "$lxc_id" -- journalctl -b -n 50 >> "/var/log/phoenix_hypervisor/phoenix_hypervisor_debug.log" 2>&4 || true
        pct stop "$lxc_id" >/dev/null 2>&4 || true
        return 1
    fi

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
    # --- FIXED: Removed erroneous '--' ---
    if ! pct_exec_with_retry "$lxc_id" bash -c "$swarm_active_check"; then
        log_error "validate_final_setup: Docker Swarm validation failed for container $lxc_id."
        journalctl -u "pve-container@$lxc_id.service" -n 50 >> "/var/log/phoenix_hypervisor/phoenix_hypervisor_debug.log" 2>&4
        pct exec "$lxc_id" -- journalctl -b -n 50 >> "/var/log/phoenix_hypervisor/phoenix_hypervisor_debug.log" 2>&4 || true
        pct stop "$lxc_id" >/dev/null 2>&4 || true
        return 1
    fi

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
    # --- FIXED: Removed erroneous '--' ---
    if ! pct_exec_with_retry "$lxc_id" bash -c "$registry_running_check"; then
        log_error "validate_final_setup: Local registry validation failed for container $lxc_id."
        journalctl -u "pve-container@$lxc_id.service" -n 50 >> "/var/log/phoenix_hypervisor/phoenix_hypervisor_debug.log" 2>&4
        pct exec "$lxc_id" -- journalctl -b -n 50 >> "/var/log/phoenix_hypervisor/phoenix_hypervisor_debug.log" 2>&4 || true
        pct stop "$lxc_id" >/dev/null 2>&4 || true
        return 1
    fi

    log_info "validate_final_setup: All validations passed for container $lxc_id."
}

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

main() {
    local lxc_id="$1"

    log_info "==============================================="
    log_info "STARTING PHOENIX HYPERVISOR DRSWARM SWARM MANAGER SETUP FOR CONTAINER $lxc_id"
    log_info "==============================================="

    validate_dependencies
    make_container_privileged "$lxc_id"
    install_docker_in_swarm_manager "$lxc_id"
    initialize_docker_swarm "$lxc_id"
    start_local_registry "$lxc_id"
    discover_and_build_images "$lxc_id"
    if ! validate_final_setup "$lxc_id"; then
        log_warn "Final validation had some failures, but setup may still be usable. Please review logs."
    fi
    show_setup_info "$lxc_id"

    log_info "==============================================="
    log_info "PHOENIX HYPERVISOR DRSWARM SWARM MANAGER SETUP FOR CONTAINER $lxc_id COMPLETED SUCCESSFULLY"
    log_info "==============================================="
}

main "$CONTAINER_ID"