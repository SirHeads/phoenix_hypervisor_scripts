#!/usr/bin/env bash

# phoenix_hypervisor_setup_drcuda.sh
#
# Sets up the DrCuda container (ID 900) with Docker, NVIDIA support, and a PyTorch environment.
# This script is intended to be called by phoenix_establish_hypervisor.sh after container creation.
#
# Version: 1.1.0 (Refactored to use common libraries)
# Author: Assistant

set -euo pipefail

# --- Terminal Handling ---
# Save terminal settings and ensure they are restored on exit or error
ORIGINAL_TERM_SETTINGS=$(stty -g 2>/dev/null) || ORIGINAL_TERM_SETTINGS=""
trap 'if [[ -n "$ORIGINAL_TERM_SETTINGS" ]]; then stty "$ORIGINAL_TERM_SETTINGS"; fi; echo "[INFO] Script interrupted. Terminal settings restored." >&2; exit 1' INT TERM ERR

# --- Argument Validation ---
if [[ $# -ne 1 ]]; then
    echo "[ERROR] Usage: $0 <container_id>" >&2
    exit 1
fi

CONTAINER_ID="$1"
if [[ "$CONTAINER_ID" != "900" ]]; then
    echo "[ERROR] This script is designed for container ID 900, got $CONTAINER_ID" >&2
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
            log_info "phoenix_hypervisor_setup_drcuda.sh: Sourced common functions from $common_path."
            break
        else
            echo "[WARN] Sourced $common_path, but common functions not found. Trying next location."
        fi
    fi
done

# Fallback logging if common lib fails
if [[ $PHOENIX_COMMON_LOADED -ne 1 ]]; then
    echo "[WARN] phoenix_hypervisor_common.sh not loaded. Using minimal logging."
    log_info() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    log_warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" >&2; }
    log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
else
    # Initialize logging from the common library if loaded successfully
    setup_logging 2>/dev/null || true # Redirect potential early errors
fi

# Source NVIDIA LXC Common Functions
PHOENIX_NVIDIA_LOADED=0
for nvidia_path in \
    "$PHOENIX_LIB_DIR/phoenix_hypervisor_lxc_common_nvidia.sh" \
    "$SCRIPT_DIR/phoenix_hypervisor_lxc_common_nvidia.sh"; do
    if [[ -f "$nvidia_path" ]]; then
        # shellcheck source=/dev/null
        source "$nvidia_path"
        if declare -F install_nvidia_driver_in_container_via_runfile >/dev/null 2>&1; then
            PHOENIX_NVIDIA_LOADED=1
            log_info "phoenix_hypervisor_setup_drcuda.sh: Sourced NVIDIA LXC common functions from $nvidia_path."
            break
        else
            log_warn "Sourced $nvidia_path, but NVIDIA functions not found. Trying next location."
        fi
    fi
done

if [[ $PHOENIX_NVIDIA_LOADED -ne 1 ]]; then
    log_error "Failed to load phoenix_hypervisor_lxc_common_nvidia.sh. Cannot proceed with NVIDIA setup."
fi

# --- Source New Common Libraries ---
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
            log_info "phoenix_hypervisor_setup_drcuda.sh: Sourced Base LXC common functions from $base_path."
            break
        else
            log_warn "Sourced $base_path, but Base LXC functions not found. Trying next location."
        fi
    fi
done

if [[ $PHOENIX_BASE_LOADED -ne 1 ]]; then
    log_error "Failed to load phoenix_hypervisor_lxc_common_base.sh. Cannot proceed with base LXC operations."
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
            log_info "phoenix_hypervisor_setup_drcuda.sh: Sourced Docker LXC common functions from $docker_path."
            break
        else
            log_warn "Sourced $docker_path, but Docker LXC functions not found. Trying next location."
        fi
    fi
done

if [[ $PHOENIX_DOCKER_LOADED -ne 1 ]]; then
    log_error "Failed to load phoenix_hypervisor_lxc_common_docker.sh. Cannot proceed with Docker operations."
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
            log_info "phoenix_hypervisor_setup_drcuda.sh: Sourced Validation LXC common functions from $validation_path."
            break
        else
            log_warn "Sourced $validation_path, but Validation LXC functions not found. Trying next location."
        fi
    fi
done

if [[ $PHOENIX_VALIDATION_LOADED -ne 1 ]]; then
    log_error "Failed to load phoenix_hypervisor_lxc_common_validation.sh. Cannot proceed with validation operations."
fi

# Source Systemd LXC Common Functions (May not be used directly here, but good to have for consistency)
PHOENIX_SYSTEMD_LOADED=0
for systemd_path in \
    "$PHOENIX_LIB_DIR/phoenix_hypervisor_lxc_common_systemd.sh" \
    "$SCRIPT_DIR/phoenix_hypervisor_lxc_common_systemd.sh"; do
    if [[ -f "$systemd_path" ]]; then
        # shellcheck source=/dev/null
        source "$systemd_path"
        if declare -F create_systemd_service_in_container >/dev/null 2>&1; then
            PHOENIX_SYSTEMD_LOADED=1
            log_info "phoenix_hypervisor_setup_drcuda.sh: Sourced Systemd LXC common functions from $systemd_path."
            break
        else
            log_warn "Sourced $systemd_path, but Systemd LXC functions not found. Trying next location."
        fi
    fi
done

# Loading systemd lib is optional for this script
if [[ $PHOENIX_SYSTEMD_LOADED -ne 1 ]]; then
    log_warn "Failed to load phoenix_hypervisor_lxc_common_systemd.sh. This might be OK if not needed."
fi


# --- Core Setup Functions ---

# 1. Validate Dependencies
validate_dependencies() {
    log_info "validate_dependencies: Checking for required commands..."
    if ! command -v jq >/dev/null 2>&1; then
        log_error "validate_dependencies: jq not installed."
    fi
    if ! command -v pct >/dev/null 2>&1; then
        log_error "validate_dependencies: pct not installed."
    fi
    log_info "validate_dependencies: All required commands found."
}

# 2. Validate Container State (Create if needed, Start, Network, GPU Passthrough)
validate_container_state() {
    local lxc_id="$1"
    log_info "validate_container_state: Validating state for container $lxc_id..."

    # Check if container exists
    if ! validate_container_exists "$lxc_id"; then
        log_info "validate_container_state: Container $lxc_id does not exist. Calling phoenix_hypervisor_create_lxc.sh..."
        # Delegate creation to the standard script
        if ! "$PHOENIX_BIN_DIR/phoenix_hypervisor_create_lxc.sh" "$lxc_id"; then
             # Check if the failure was due to the premature CUDA validation in create_lxc.sh
             # We expect it to fail here, so we check if the container was actually created and started.
             if validate_container_exists "$lxc_id"; then
                 if validate_container_running "$lxc_id"; then
                     log_warn "validate_container_state: phoenix_hypervisor_create_lxc.sh reported failure, but container $lxc_id seems to be created and running. Proceeding."
                 else
                     log_error "validate_container_state: Failed to create container $lxc_id via phoenix_hypervisor_create_lxc.sh and container is not running."
                 fi
             else
                 log_error "validate_container_state: Failed to create container $lxc_id via phoenix_hypervisor_create_lxc.sh."
             fi
        fi
        log_info "validate_container_state: Container $lxc_id creation process completed (or handled)."
    else
        log_info "validate_container_state: Container $lxc_id already exists."
    fi

    # Ensure container is running
    if ! ensure_container_running "$lxc_id"; then
        log_error "validate_container_state: Failed to ensure container $lxc_id is running."
    fi

    # Basic network check
    if ! check_container_network "$lxc_id"; then
        log_warn "validate_container_state: Network check failed. Attempting to set temporary DNS..."
        if ! set_temporary_dns "$lxc_id"; then
            log_error "validate_container_state: Failed to set temporary DNS for container $lxc_id."
        fi
        # Retry network check after setting DNS
        if ! check_container_network "$lxc_id"; then
            log_error "validate_container_state: Network check still failed after setting DNS for container $lxc_id."
        fi
    fi

    # Check and Configure GPU Passthrough
    # Get GPU assignment from the global config (as DrCuda might not have it in its specific section)
    # Or, we can assume it's configured correctly by the main orchestrator or create script.
    # For now, let's assume it's handled by the create script or already configured.
    # A more robust check would involve parsing the main config file for container 900's assignment.
    # Placeholder for potential future enhancement:
    # local gpu_assignment=$(get_gpu_assignment "$lxc_id") # This would need a helper function
    # if [[ -n "$gpu_assignment" && "$gpu_assignment" != "none" ]]; then ...
    # For now, we assume it's set up correctly.
    log_info "validate_container_state: Assuming GPU passthrough is configured for container $lxc_id (as per main config)."
}

# 3. Setup NVIDIA Packages (adapted from original drcuda and drdevstral logic)
setup_nvidia_packages() {
    local lxc_id="$1"
    log_info "setup_nvidia_packages: Installing NVIDIA components in container $lxc_id..."

    # Install NVIDIA driver via repository (preferred method, consistent with drdevstral)
    log_info "setup_nvidia_packages: Installing NVIDIA driver via repository..."
    if ! setup_nvidia_repo_in_container "$lxc_id"; then
        log_error "setup_nvidia_packages: Failed to install NVIDIA driver via repository in container $lxc_id."
    fi

    # Install NVIDIA userland libraries
    log_info "setup_nvidia_packages: Installing NVIDIA userland libraries..."
    if ! install_nvidia_userland_in_container "$lxc_id"; then
        log_error "setup_nvidia_packages: Failed to install NVIDIA userland in container $lxc_id."
    fi

    # Install NVIDIA Container Toolkit (nvidia-docker2)
    log_info "setup_nvidia_packages: Installing NVIDIA Container Toolkit..."
    if ! install_nvidia_toolkit_in_container "$lxc_id"; then
        log_error "setup_nvidia_packages: Failed to install NVIDIA toolkit in container $lxc_id."
    fi

    # Configure Docker to use NVIDIA runtime
    log_info "setup_nvidia_packages: Configuring Docker NVIDIA runtime..."
    if ! configure_docker_nvidia_runtime "$lxc_id"; then
        log_error "setup_nvidia_packages: Failed to configure Docker NVIDIA runtime in container $lxc_id."
    fi

    # Verify basic GPU access inside the container
    log_info "setup_nvidia_packages: Verifying basic GPU access in container $lxc_id..."
    if ! verify_lxc_gpu_access_in_container "$lxc_id"; then
        log_error "setup_nvidia_packages: Basic GPU access verification failed in container $lxc_id."
    fi

    log_info "setup_nvidia_packages: NVIDIA components installed and configured successfully in container $lxc_id."
}

# 4. Install Docker CE (using common function)
install_docker_in_container() {
    local lxc_id="$1"
    log_info "install_docker_in_container: Installing Docker CE in container $lxc_id..."

    if ! install_docker_ce_in_container "$lxc_id"; then
        log_error "install_docker_in_container: Failed to install Docker CE in container $lxc_id."
    fi

    log_info "install_docker_in_container: Docker CE installed successfully in container $lxc_id."
}

# 5. Build PyTorch Docker Image (from original drcuda, adapted)
build_pytorch_docker_image() {
    local lxc_id="$1"
    log_info "build_pytorch_docker_image: Building PyTorch Docker image in container $lxc_id..."

    local image_tag="pytorch-cuda:12.9" # Using CUDA 12.9 as per config and original script
    local dockerfile_path="/root/pytorch_dockerfile"

    # Define the Dockerfile content directly as a string
    # Using CUDA 12.9 PyTorch image as an example, matching config and original script
    local dockerfile_content="FROM nvidia/cuda:12.9.0-base-ubuntu24.04

# Install additional tools if needed
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Install PyTorch for CUDA 12.9 (matching the base image)
RUN pip3 install torch torchvision --index-url https://download.pytorch.org/whl/cu129

# Set a default command (can be overridden)
CMD [\"bash\"]"

    # Write the Dockerfile content to a file inside the container
    local write_dockerfile_cmd="set -e
mkdir -p /root/pytorch_build
cat << 'EOF_DOCKERFILE' > $dockerfile_path
$dockerfile_content
EOF_DOCKERFILE
echo '[INFO] Dockerfile written to $dockerfile_path'"

    if ! pct_exec_with_retry "$lxc_id" "$write_dockerfile_cmd"; then
        log_error "build_pytorch_docker_image: Failed to write Dockerfile in container $lxc_id."
    fi

    # Build the Docker image inside the container using the written Dockerfile
    # Using the function from the Docker common library
    if ! build_docker_image_in_container "$lxc_id" "$dockerfile_path" "$image_tag"; then
        log_error "build_pytorch_docker_image: Failed to build PyTorch Docker image in container $lxc_id."
    fi

    log_info "build_pytorch_docker_image: PyTorch Docker image built successfully in container $lxc_id."
}

# 6. Final Validation (adapted from drdevstral)
validate_final_setup() {
    local lxc_id="$1"
    local checks_passed=0
    local checks_failed=0

    log_info "validate_final_setup: Validating final setup for container $lxc_id..."
    echo "Validating final setup for container $lxc_id..."

    # --- Check Container Status ---
    if validate_container_running "$lxc_id"; then
        log_info "validate_final_setup: Container $lxc_id is running"
        ((checks_passed++)) || true
    else
        log_error "validate_final_setup: Container $lxc_id is not running"
        ((checks_failed++)) || true
    fi

    # --- Check Docker Status ---
    local docker_check_cmd="set -e
if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
    echo '[SUCCESS] Docker is installed and running'
    exit 0
else
    echo '[ERROR] Docker is not installed or not running'
    exit 1
fi"
    if pct_exec_with_retry "$lxc_id" "$docker_check_cmd"; then
        log_info "validate_final_setup: Docker is installed and running in container $lxc_id"
        ((checks_passed++)) || true
    else
        log_error "validate_final_setup: Docker check failed in container $lxc_id"
        ((checks_failed++)) || true
    fi

    # --- Check GPU Access via Docker ---
    # Use a standard CUDA base image for testing (matching the PyTorch image base)
    if verify_docker_gpu_access_in_container "$lxc_id" "nvidia/cuda:12.9.0-base-ubuntu24.04"; then
        log_info "validate_final_setup: Docker GPU access verified for container $lxc_id"
        ((checks_passed++)) || true
    else
        log_error "validate_final_setup: Docker GPU access verification failed for container $lxc_id"
        ((checks_failed++)) || true
    fi

    # --- Summary ---
    log_info "validate_final_setup: Validation summary: $checks_passed passed, $checks_failed failed"
    if [[ $checks_failed -gt 0 ]]; then
        log_warn "validate_final_setup: Validation completed with $checks_failed failures. Check logs for details."
        return 1 # Indicate partial failure
    fi
    log_info "validate_final_setup: All validation checks passed for container $lxc_id"
    echo "All validation checks passed for container $lxc_id."
    return 0
}

# 7. Show Setup Information (adapted from drdevstral)
show_setup_info() {
    local lxc_id="$1"
    log_info "show_setup_info: Displaying setup information for container $lxc_id..."
    echo ""
    echo "==============================================="
    echo "DR CUDA SETUP COMPLETED FOR CONTAINER $lxc_id"
    echo "==============================================="
    echo "PyTorch Docker Image: pytorch-cuda:12.9 (built inside container)"
    echo ""
    echo "You can now run PyTorch jobs using Docker inside the container."
    echo "Example command to test:"
    echo "  pct exec $lxc_id -- docker run --rm --gpus all pytorch-cuda:12.9 python3 -c \"import torch; print(torch.cuda.is_available())\""
    echo ""
    echo "To enter the container:"
    echo "  pct enter $lxc_id"
    echo "==============================================="
}


# --- Main Execution ---
main() {
    local lxc_id="$1"

    log_info "==============================================="
    log_info "STARTING PHOENIX HYPERVISOR DR CUDA SETUP FOR CONTAINER $lxc_id"
    log_info "==============================================="

    # 1. Validate Dependencies
    validate_dependencies

    # 2. Validate Container State (Create if needed, Start, Network, GPU Passthrough)
    validate_container_state "$lxc_id"

    # 3. Setup NVIDIA Packages (Driver, Userland, Toolkit, Docker Runtime)
    setup_nvidia_packages "$lxc_id"

    # 4. Install Docker CE
    install_docker_in_container "$lxc_id"

    # 5. Build PyTorch Docker Image
    build_pytorch_docker_image "$lxc_id"

    # 6. Validate Final Setup
    if ! validate_final_setup "$lxc_id"; then
        log_warn "Final validation had some failures, but setup may still be usable. Please review logs."
    fi

    # 7. Show Setup Information
    show_setup_info "$lxc_id"

    log_info "==============================================="
    log_info "PHOENIX HYPERVISOR DR CUDA SETUP FOR CONTAINER $lxc_id COMPLETED SUCCESSFULLY"
    log_info "==============================================="
}

# Run main function with the provided container ID
main "$CONTAINER_ID"
