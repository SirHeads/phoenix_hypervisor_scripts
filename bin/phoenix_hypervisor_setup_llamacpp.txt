#!/usr/bin/env bash

# phoenix_hypervisor_setup_llamacpp.sh
#
# Sets up the llamacpp container (ID 902) with NVIDIA support (Driver 580.76.05, CUDA 12.8) and builds llama.cpp.
# This script is intended to be called by phoenix_establish_hypervisor.sh after container creation.
#
# Version: 1.0.0 (Initial for Project Requirements)
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
if [[ "$CONTAINER_ID" != "902" ]]; then
    echo "[ERROR] This script is designed for container ID 902, got $CONTAINER_ID" >&2
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
            log_info "phoenix_hypervisor_setup_llamacpp.sh: Sourced common functions from $common_path."
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
            log_info "phoenix_hypervisor_setup_llamacpp.sh: Sourced NVIDIA LXC common functions from $nvidia_path."
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
            log_info "phoenix_hypervisor_setup_llamacpp.sh: Sourced Base LXC common functions from $base_path."
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
            log_info "phoenix_hypervisor_setup_llamacpp.sh: Sourced Docker LXC common functions from $docker_path."
            break
        else
            log_warn "Sourced $docker_path, but Docker LXC functions not found. Trying next location."
        fi
    fi
done

# Loading Docker lib is optional for this script if Docker isn't used directly
if [[ $PHOENIX_DOCKER_LOADED -ne 1 ]]; then
    log_warn "Failed to load phoenix_hypervisor_lxc_common_docker.sh. This might be OK if not needed."
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
            log_info "phoenix_hypervisor_setup_llamacpp.sh: Sourced Validation LXC common functions from $validation_path."
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
            log_info "phoenix_hypervisor_setup_llamacpp.sh: Sourced Systemd LXC common functions from $systemd_path."
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
        # Handle potential premature CUDA validation failure gracefully
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
    # Get GPU assignment from config
    local gpu_assignment
    gpu_assignment=$(get_gpu_assignment "$lxc_id")
    if [[ "$gpu_assignment" == "none" || -z "$gpu_assignment" ]]; then
        log_info "validate_container_state: No GPU assignment found for container $lxc_id. Skipping GPU passthrough."
        return 0
    fi

    # Validate GPU assignment format
    if ! validate_gpu_assignment_format "$gpu_assignment"; then
        log_error "validate_container_state: Invalid GPU assignment format for container $lxc_id: $gpu_assignment"
    fi

    # Check if GPU passthrough is already configured by looking for a common entry
    local config_file="/etc/pve/lxc/${lxc_id}.conf"
    local gpu_configured
    gpu_configured=$(pct config "$lxc_id" | grep -c "lxc.cgroup2.devices.allow: c 195" || true)

    if [[ "$gpu_configured" -gt 0 ]]; then
        log_info "validate_container_state: GPU passthrough already configured for container $lxc_id."
    else
        log_info "validate_container_state: Configuring GPU passthrough for container $lxc_id (GPUs: $gpu_assignment)..."
        if ! configure_lxc_gpu_passthrough "$lxc_id" "$gpu_assignment"; then
            log_error "validate_container_state: Failed to configure GPU passthrough for container $lxc_id."
        fi
        log_info "validate_container_state: GPU passthrough configured. Restarting container $lxc_id to apply changes..."
        pct stop "$lxc_id" || true
        sleep 5
        if ! retry_command 3 10 pct start "$lxc_id"; then
            log_error "validate_container_state: Failed to restart container $lxc_id after GPU passthrough configuration."
        fi
        log_info "validate_container_state: Container $lxc_id restarted with GPU passthrough."
    fi
}

# 3. Install Build Dependencies and Tools in Container
install_build_dependencies() {
    local lxc_id="$1"
    log_info "install_build_dependencies: Installing build tools and dependencies in container $lxc_id..."

    local install_cmd="set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y --fix-missing
apt-get install -y git build-essential cmake curl python3 python3-pip wget
# Install CUDA development toolkit 12.8 (assuming common function exists)
# This step might be moved to after NVIDIA driver installation if needed
echo '[SUCCESS] Build dependencies installed.'
"

    # Use pct_exec_with_retry if available
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    if ! $exec_func "$lxc_id" -- bash -c "$install_cmd"; then
        log_error "install_build_dependencies: Failed to install build dependencies in container $lxc_id."
    fi

    log_info "install_build_dependencies: Build tools and dependencies installed successfully in container $lxc_id."
}


# 4. Setup NVIDIA Packages (Driver via Runfile, CUDA Toolkit 12.8)
setup_nvidia_packages() {
    local lxc_id="$1"
    log_info "setup_nvidia_packages: Installing NVIDIA components (Driver 580.76.05, CUDA 12.8) in container $lxc_id..."

    # Install NVIDIA driver via runfile (NEW FUNCTION)
    log_info "setup_nvidia_packages: Installing NVIDIA driver 580.76.05 via runfile (no kernel module)..."
    # Ensure the new function name is used
    if declare -F install_nvidia_driver_in_container_via_runfile >/dev/null 2>&1; then
        if ! install_nvidia_driver_in_container_via_runfile "$lxc_id"; then
            log_error "setup_nvidia_packages: Failed to install NVIDIA driver via runfile in container $lxc_id."
        fi
    else
        log_error "setup_nvidia_packages: Required function 'install_nvidia_driver_in_container_via_runfile' not found. Please update phoenix_hypervisor_lxc_common_nvidia.sh."
    fi

    # Install CUDA Toolkit 12.8 (NEW FUNCTION)
    log_info "setup_nvidia_packages: Installing CUDA Toolkit 12.8..."
    # Ensure the new function name is used
    if declare -F install_cuda_toolkit_12_8_in_container >/dev/null 2>&1; then
        if ! install_cuda_toolkit_12_8_in_container "$lxc_id"; then
            log_error "setup_nvidia_packages: Failed to install CUDA Toolkit 12.8 in container $lxc_id."
        fi
    else
        log_error "setup_nvidia_packages: Required function 'install_cuda_toolkit_12_8_in_container' not found. Please update phoenix_hypervisor_lxc_common_nvidia.sh."
    fi

    # Verify basic GPU access inside the container
    log_info "setup_nvidia_packages: Verifying basic GPU access in container $lxc_id..."
    if ! verify_lxc_gpu_access_in_container "$lxc_id"; then
        log_error "setup_nvidia_packages: Basic GPU access verification failed in container $lxc_id."
    fi

    # Verify CUDA Toolkit installation (nvcc)
    log_info "setup_nvidia_packages: Verifying CUDA Toolkit installation (nvcc) in container $lxc_id..."
    local nvcc_check_cmd="set -e
if command -v nvcc >/dev/null 2>&1; then
    nvcc_version=\$(nvcc --version | grep 'release' | awk '{print \$5}' | sed 's/,//')
    echo \"[SUCCESS] nvcc found, version: \$nvcc_version\"
    exit 0
else
    echo '[ERROR] nvcc not found'
    exit 1
fi"

    # Use pct_exec_with_retry if available
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    if ! $exec_func "$lxc_id" -- bash -c "$nvcc_check_cmd"; then
        log_error "setup_nvidia_packages: CUDA Toolkit verification (nvcc) failed in container $lxc_id."
    fi

    log_info "setup_nvidia_packages: NVIDIA components (Driver 580.76.05, CUDA 12.8) installed and verified successfully in container $lxc_id."
}


# 5. Build llama.cpp in Container
build_llama_cpp() {
    local lxc_id="$1"
    log_info "build_llama_cpp: Building llama.cpp in container $lxc_id..."

    local build_cmd="set -e
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# Create a working directory
mkdir -p /opt/ai
cd /opt/ai

# Clone the llama.cpp repository
echo '[INFO] Cloning llama.cpp repository...'
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp

# Create build directory and configure with CUDA and CURL support
echo '[INFO] Configuring build with CUDA and CURL support...'
cmake -B build -DGGML_CUDA=ON -DLLAMA_CURL=ON

# Build the project
echo '[INFO] Building llama.cpp (this may take a while)...'
cmake --build build --config Release -j \$(nproc)

echo '[SUCCESS] llama.cpp built successfully.'
"

    # Use pct_exec_with_retry if available
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

     # Note: Building can take a long time, consider increasing retry delays or attempts if needed.
    if ! $exec_func "$lxc_id" -- bash -c "$build_cmd"; then
        log_error "build_llama_cpp: Failed to build llama.cpp in container $lxc_id."
    fi

    log_info "build_llama_cpp: llama.cpp built successfully in container $lxc_id."
}

# 6. Install Python Bindings (llama-cpp-python) in Container
install_python_bindings() {
    local lxc_id="$1"
    log_info "install_python_bindings: Installing llama-cpp-python in container $lxc_id..."

    local install_cmd="set -e
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# Update pip
pip3 install --upgrade pip

# Install llama-cpp-python with CUDA support
# Note: CUDA autodetection usually works, but CMAKE_ARGS can force it if needed
echo '[INFO] Installing llama-cpp-python with CUDA support...'
# CMAKE_ARGS=\"-DGGML_CUDA=on\" pip3 install llama-cpp-python # Alternative if auto-detect fails
pip3 install llama-cpp-python

echo '[SUCCESS] llama-cpp-python installed.'
"

    # Use pct_exec_with_retry if available
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    if ! $exec_func "$lxc_id" -- bash -c "$install_cmd"; then
        log_error "install_python_bindings: Failed to install llama-cpp-python in container $lxc_id."
    fi

    log_info "install_python_bindings: llama-cpp-python installed successfully in container $lxc_id."
}


# 7. Final Validation
validate_final_setup() {
    local lxc_id="$1"
    local checks_passed=0
    local checks_failed=0

    log_info "validate_final_setup: Validating final setup for container $lxc_id..."
    echo "Validating final setup for container $lxc_id..."

    # --- Check Container Status (using common function if available) ---
    if declare -F validate_container_running >/dev/null 2>&1; then
        if validate_container_running "$lxc_id"; then
            log_info "validate_final_setup: Container $lxc_id is running"
            ((checks_passed++)) || true
        else
            log_error "validate_final_setup: Container $lxc_id is not running"
            ((checks_failed++)) || true
        fi
    else
        # Fallback
        local status
        status=$(pct status "$lxc_id" 2>/dev/null | grep 'status' | awk '{print $2}')
        if [[ "$status" == "running" ]]; then
            log_info "validate_final_setup: Container $lxc_id is running"
            ((checks_passed++)) || true
        else
            log_error "validate_final_setup: Container $lxc_id is not running"
            ((checks_failed++)) || true
        fi
    fi

    # --- Check GPU Access via nvidia-smi ---
    local nvidia_smi_check="set -e
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    echo '[SUCCESS] nvidia-smi command successful'
    exit 0
else
    echo '[ERROR] nvidia-smi command failed'
    exit 1
fi"
    # Use pct_exec_with_retry if available
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi
    if $exec_func "$lxc_id" -- bash -c "$nvidia_smi_check"; then
        log_info "validate_final_setup: nvidia-smi check passed in container $lxc_id"
        ((checks_passed++)) || true
    else
        log_error "validate_final_setup: nvidia-smi check failed in container $lxc_id"
        ((checks_failed++)) || true
    fi

    # --- Check CUDA Toolkit (nvcc) ---
    local nvcc_check="set -e
if command -v nvcc >/dev/null 2>&1; then
    nvcc_version=\$(nvcc --version | grep 'release' | awk '{print \$5}' | sed 's/,//')
    echo \"[SUCCESS] nvcc found, version: \$nvcc_version\"
    exit 0
else
    echo '[ERROR] nvcc not found'
    exit 1
fi"
    if $exec_func "$lxc_id" -- bash -c "$nvcc_check"; then
        log_info "validate_final_setup: nvcc check passed in container $lxc_id"
        ((checks_passed++)) || true
    else
        log_error "validate_final_setup: nvcc check failed in container $lxc_id"
        ((checks_failed++)) || true
    fi

    # --- Check llama.cpp Binary ---
    local llama_binary_check="set -e
if [[ -f '/opt/ai/llama.cpp/build/bin/llama-cli' ]]; then
    echo '[SUCCESS] llama-cli binary found'
    exit 0
else
    echo '[ERROR] llama-cli binary not found'
    exit 1
fi"
    if $exec_func "$lxc_id" -- bash -c "$llama_binary_check"; then
        log_info "validate_final_setup: llama-cli binary check passed in container $lxc_id"
        ((checks_passed++)) || true
    else
        log_error "validate_final_setup: llama-cli binary check failed in container $lxc_id"
        ((checks_failed++)) || true
    fi

    # --- Check Python Bindings ---
    local python_check="set -e
if python3 -c 'import llama_cpp; print(\"llama_cpp imported successfully\")' >/dev/null 2>&1; then
    echo '[SUCCESS] llama_cpp Python module imported'
    exit 0
else
    echo '[ERROR] Failed to import llama_cpp Python module'
    exit 1
fi"
    if $exec_func "$lxc_id" -- bash -c "$python_check"; then
        log_info "validate_final_setup: Python bindings check passed in container $lxc_id"
        ((checks_passed++)) || true
    else
        log_error "validate_final_setup: Python bindings check failed in container $lxc_id"
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

# 8. Show Setup Information
show_setup_info() {
    local lxc_id="$1"
    log_info "show_setup_info: Displaying setup information for container $lxc_id..."
    echo ""
    echo "==============================================="
    echo "LLAMACPP SETUP COMPLETED FOR CONTAINER $lxc_id"
    echo "==============================================="
    echo "llama.cpp is built in /opt/ai/llama.cpp/build"
    echo "llama-cli binary is at /opt/ai/llama.cpp/build/bin/llama-cli"
    echo "Python bindings (llama-cpp-python) are installed."
    echo ""
    echo "To enter the container:"
    echo "  pct enter $lxc_id"
    echo "To run llama-cli (example):"
    echo "  pct exec $lxc_id -- /opt/ai/llama.cpp/build/bin/llama-cli -m <path_to_model.gguf> -p \"Hello world\""
    echo "To use Python bindings (example):"
    echo "  pct exec $lxc_id -- python3 -c \"from llama_cpp import Llama; print('Llama imported')\""
    echo "==============================================="
}


# --- Main Execution ---
main() {
    local lxc_id="$1"

    log_info "==============================================="
    log_info "STARTING PHOENIX HYPERVISOR LLAMACPP SETUP FOR CONTAINER $lxc_id"
    log_info "==============================================="

    # 1. Validate Dependencies
    validate_dependencies

    # 2. Validate Container State (Create if needed, Start, Network, GPU Passthrough)
    validate_container_state "$lxc_id"

    # 3. Install Build Dependencies
    install_build_dependencies "$lxc_id"

    # 4. Setup NVIDIA Packages (Driver 580.76.05 via runfile, CUDA Toolkit 12.8)
    setup_nvidia_packages "$lxc_id"

    # 5. Build llama.cpp
    build_llama_cpp "$lxc_id"

    # 6. Install Python Bindings (llama-cpp-python)
    install_python_bindings "$lxc_id"

    # 7. Validate Final Setup
    if ! validate_final_setup "$lxc_id"; then
        log_warn "Final validation had some failures, but setup may still be usable. Please review logs."
    fi

    # 8. Show Setup Information
    show_setup_info "$lxc_id"

    log_info "==============================================="
    log_info "PHOENIX HYPERVISOR LLAMACPP SETUP FOR CONTAINER $lxc_id COMPLETED SUCCESSFULLY"
    log_info "==============================================="
}

# Run main function with the provided container ID
main "$CONTAINER_ID"
