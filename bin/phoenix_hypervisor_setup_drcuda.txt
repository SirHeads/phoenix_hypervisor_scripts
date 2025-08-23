#!/usr/bin/env bash

# phoenix_hypervisor_setup_drcuda.sh
#
# Sets up the DrCuda container (ID 900) with Docker, NVIDIA support (Driver 580.76.05, CUDA 12.8),
# and pulls a pre-built PyTorch environment from the DrSwarm registry.
# This script is intended to be called by phoenix_establish_hypervisor.sh after container creation.
#
# Version: 1.3.2 (Integrated DrSwarm Registry Image Pull)
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

# Source Phoenix Hypervisor Systemd Functions
PHOENIX_SYSTEMD_LOADED=0
for systemd_path in \
    "$PHOENIX_LIB_DIR/phoenix_hypervisor_lxc_common_systemd.sh" \
    "$SCRIPT_DIR/phoenix_hypervisor_lxc_common_systemd.sh"; do
    if [[ -f "$systemd_path" ]]; then
        # shellcheck source=/dev/null
        source "$systemd_path"
        if declare -F create_systemd_service_in_container >/dev/null 2>&1; then
            PHOENIX_SYSTEMD_LOADED=1
            echo "[INFO] Sourced Phoenix Hypervisor systemd functions from $systemd_path."
            break
        else
            echo "[WARN] Sourced $systemd_path, but systemd functions not found. Trying next location."
        fi
    fi
done

if [[ $PHOENIX_SYSTEMD_LOADED -ne 1 ]]; then
    echo "[ERROR] Failed to load phoenix_hypervisor_lxc_common_systemd.sh from standard locations." >&2
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

# --- NEW: Source Swarm Pull LXC Common Functions ---
PHOENIX_SWARM_PULL_LOADED=0
for swarm_pull_path in \
    "$PHOENIX_LIB_DIR/phoenix_hypervisor_lxc_common_swarmpull.sh" \
    "$SCRIPT_DIR/phoenix_hypervisor_lxc_common_swarmpull.sh"; do
    if [[ -f "$swarm_pull_path" ]]; then
        # shellcheck source=/dev/null
        source "$swarm_pull_path"
        if declare -F configure_local_registry_trust >/dev/null 2>&1; then
            PHOENIX_SWARM_PULL_LOADED=1
            log_info "phoenix_hypervisor_setup_drcuda.sh: Sourced Swarm Pull LXC common functions from $swarm_pull_path."
            break
        else
            log_warn "Sourced $swarm_pull_path, but Swarm Pull LXC functions not found. Trying next location."
        fi
    fi
done

if [[ $PHOENIX_SWARM_PULL_LOADED -ne 1 ]]; then
    log_error "Failed to load phoenix_hypervisor_lxc_common_swarmpull.sh. Cannot proceed with registry integration."
fi
# --- END NEW ---

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
# ... (This function remains unchanged) ...

# 3. Setup NVIDIA Packages (using NEW project-required functions)
# ... (This function remains unchanged) ...

# 4. Install Docker CE (using common function)
# ... (This function remains unchanged) ...

# --- NEW: Configure Registry Trust ---
configure_registry_trust_in_drcuda() {
    local lxc_id="$1"
    log_info "configure_registry_trust_in_drcuda: Configuring registry trust in container $lxc_id..."

    # Hardcoded registry address based on DrSwarm config
    local registry_address="10.0.0.99:5000"

    if [[ $PHOENIX_SWARM_PULL_LOADED -eq 1 ]]; then
        if ! configure_local_registry_trust "$lxc_id" "$registry_address"; then
            log_error "configure_registry_trust_in_drcuda: Failed to configure registry trust in container $lxc_id using common function."
        fi
    else
        log_error "configure_registry_trust_in_drcuda: phoenix_hypervisor_lxc_common_swarmpull.sh not loaded. Cannot configure registry trust."
    fi

    log_info "configure_registry_trust_in_drcuda: Registry trust configured in container $lxc_id."
}
# --- END NEW ---

# --- REPLACED/REMOVED: Complex build/push logic ---
# The function `push_pytorch_image_to_registry` is removed or replaced.

# --- NEW: Pull PyTorch Image from Registry into Container ---
pull_pytorch_image_from_registry() {
    local lxc_id="$1"
    log_info "pull_pytorch_image_from_registry: Pulling PyTorch image into container $lxc_id..."

    # Define the image tag as known in the registry and expected locally
    # This should match the directory name in phoenix_docker_images (pytorch-cuda)
    # and the tag used during the build/push process in DrSwarm setup.
    local image_tag="pytorch-cuda:12.8"

    if [[ $PHOENIX_SWARM_PULL_LOADED -eq 1 ]]; then
        if ! pull_from_swarm_registry "$lxc_id" "$image_tag"; then
            log_error "pull_pytorch_image_from_registry: Failed to pull image $image_tag into container $lxc_id using common function."
        fi
    else
        log_error "pull_pytorch_image_from_registry: phoenix_hypervisor_lxc_common_swarmpull.sh not loaded. Cannot pull image."
    fi

    log_info "pull_pytorch_image_from_registry: PyTorch image pulled into container $lxc_id."
}
# --- END NEW ---

# 6. Final Validation (adapted from drdevstral)
# ... (This function remains largely unchanged, but the image tag is updated) ...
# --- Slightly Updated Validation ---
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
    if pct_exec_with_retry "$lxc_id" -- bash -c "$docker_check_cmd"; then
        log_info "validate_final_setup: Docker is installed and running in container $lxc_id"
        ((checks_passed++)) || true
    else
        log_error "validate_final_setup: Docker check failed in container $lxc_id"
        ((checks_failed++)) || true
    fi

    # --- Check GPU Access via Docker ---
    # Use a standard CUDA base image for testing (matching the PyTorch image base updated for CUDA 12.8)
    if verify_docker_gpu_access_in_container "$lxc_id" "nvidia/cuda:12.8.0-base-ubuntu24.04"; then
        log_info "validate_final_setup: Docker GPU access verified for container $lxc_id"
        ((checks_passed++)) || true
    else
        log_error "validate_final_setup: Docker GPU access verification failed in container $lxc_id"
        ((checks_failed++)) || true
    fi

    # --- NEW: Check if PyTorch Image is Present Locally ---
    local image_check_cmd="set -e
if docker images -q pytorch-cuda:12.8 | grep -q .; then
    echo '[SUCCESS] PyTorch image pytorch-cuda:12.8 found locally'
    exit 0
else
    echo '[ERROR] PyTorch image pytorch-cuda:12.8 not found locally'
    exit 1
fi"
    if pct_exec_with_retry "$lxc_id" -- bash -c "$image_check_cmd"; then
        log_info "validate_final_setup: PyTorch image found locally in container $lxc_id"
        ((checks_passed++)) || true
    else
        log_error "validate_final_setup: PyTorch image not found locally in container $lxc_id"
        ((checks_failed++)) || true
    fi
    # --- END NEW ---

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
# --- END Slightly Updated Validation ---

# 7. Show Setup Information (adapted from drdevstral)
# ... (This function remains largely unchanged, but the image tag is updated) ...
show_setup_info() {
    local lxc_id="$1"
    log_info "show_setup_info: Displaying setup information for container $lxc_id..."
    echo ""
    echo "==============================================="
    echo "DR CUDA SETUP COMPLETED FOR CONTAINER $lxc_id"
    echo "==============================================="
    # Updated image tag
    echo "PyTorch Docker Image: pytorch-cuda:12.8 (pulled from registry into container)"
    echo ""
    echo "You can now run PyTorch jobs using Docker inside the container."
    echo "Example command to test:"
    # Updated example command
    echo "  pct exec $lxc_id -- docker run --rm --gpus all pytorch-cuda:12.8 python3 -c \"import torch; print(torch.cuda.is_available())\""
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

    # === ORDER CORRECTED HERE ===
    # 4. Install Docker CE (NOW BEFORE NVIDIA Setup)
    install_docker_in_container "$lxc_id"

    # 3. Setup NVIDIA Packages (Driver 580.76.05 via runfile, CUDA 12.8, Toolkit, Docker Runtime)
    # Now Docker is available when configure_docker_nvidia_runtime is called
    setup_nvidia_packages "$lxc_id"

    # --- NEW: Configure Registry Trust ---
    # Configure the DrCuda container's Docker daemon to trust the DrSwarm registry
    configure_registry_trust_in_drcuda "$lxc_id"
    # --- END NEW ---

    # --- NEW: Pull Pre-Built Image ---
    # Pull the pre-built image from the DrSwarm registry into the DrCuda container
    pull_pytorch_image_from_registry "$lxc_id"
    # --- END NEW ---

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
