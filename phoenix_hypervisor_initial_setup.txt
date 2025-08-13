#!/bin/bash
# Initial setup script for Phoenix Hypervisor
# Performs one-time environment preparation tasks
# Version: 1.7.4
# Author: Assistant

set -euo pipefail
set -x  # Enable tracing for debugging

# Reset terminal state on exit to prevent corruption
trap 'stty sane; echo "Terminal reset"' EXIT

# --- Enhanced Sourcing ---
# Source configuration from the standard location
# Ensures paths like PHOENIX_LXC_CONFIG_FILE are available
if [[ -f "/usr/local/etc/phoenix_hypervisor_config.sh" ]]; then
    source /usr/local/etc/phoenix_hypervisor_config.sh
else
    # Fallback to current directory if standard location not found (less ideal)
    if [[ -f "./phoenix_hypervisor_config.sh" ]]; then
        source ./phoenix_hypervisor_config.sh
        echo "[WARN] phoenix_hypervisor_initial_setup.sh: Sourced config from current directory. Prefer /usr/local/etc/phoenix_hypervisor_config.sh" >&2
    else
        echo "[ERROR] phoenix_hypervisor_initial_setup.sh: Configuration file not found: /usr/local/etc/phoenix_hypervisor_config.sh or ./phoenix_hypervisor_config.sh" >&2
        exit 1
    fi
fi

# Source common functions from the standard location
# Priority: 1. Standard lib location, 2. Standard bin location, 3. Current directory
if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh
elif [[ -f "/usr/local/bin/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/bin/phoenix_hypervisor_common.sh
    echo "[WARN] phoenix_hypervisor_initial_setup.sh: Sourced common functions from /usr/local/bin/. Prefer /usr/local/lib/phoenix_hypervisor/." >&2
elif [[ -f "./phoenix_hypervisor_common.sh" ]]; then
    source ./phoenix_hypervisor_common.sh
    echo "[WARN] phoenix_hypervisor_initial_setup.sh: Sourced common functions from current directory. Prefer standard locations." >&2
else
    # Define minimal fallback logging if common functions can't be sourced
    log_info() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $1"; }
    log_warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $1" >&2; }
    log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $1" >&2; }
    log_warn "phoenix_hypervisor_initial_setup.sh: Common functions file not found in standard locations. Using minimal logging."
fi

# --- Enhanced Setup Functions ---

# - Validate APT Sources -
validate_apt_sources() {
    log_info "Validating APT sources..."
    if ! apt update -y 2>&1 | tee -a "$PHOENIX_LOG_FILE"; then
        log_error "APT update failed. Check /etc/apt/sources.list and network connectivity."
        exit 1
    fi
    log_info "APT sources validated successfully"
}

# - Enhanced System Requirements Check -
setup_system_requirements() {
    log_info "Checking and installing system requirements..."
    # Validate APT sources before any apt commands
    validate_apt_sources
    # Install jq and python3-jsonschema if missing
    if ! command -v jq >/dev/null 2>&1; then
        log_info "Installing jq..."
        apt install -y jq || {
            log_error "Failed to install jq."
            exit 1
        }
    fi
    if ! command -v jsonschema >/dev/null 2>&1; then
        log_info "Installing python3-jsonschema..."
        apt install -y python3-jsonschema || {
            log_error "Failed to install python3-jsonschema."
            exit 1
        }
    fi
    if ! command -v pct >/dev/null 2>&1; then
        log_error "Required tool 'pct' (Proxmox Container Tools) not found."
        exit 1
    fi
    # Additional dependency check for apparmor
    systemctl is-active --quiet apparmor || {
        log_info "Installing apparmor..."
        apt install -y apparmor || {
            log_error "Failed to install apparmor."
            exit 1
        }
        systemctl enable --now apparmor || {
            log_error "Failed to enable apparmor service."
            exit 1
        }
    }
    log_info "System requirements check and installation completed"
}

# - Enhanced Directory Setup -
setup_directories() {
    log_info "Setting up Phoenix Hypervisor directories..."
    # Use PHOENIX_HYPERVISOR_LIB_DIR from config if available, otherwise default
    local lib_dir="${PHOENIX_HYPERVISOR_LIB_DIR:-/usr/local/lib/phoenix_hypervisor}"
    local dirs=(
        "$lib_dir"
        "/usr/local/bin/phoenix_hypervisor" # Scripts dir
        "/var/lib/phoenix_hypervisor"
        "/var/log/phoenix_hypervisor"
        "/var/lib/phoenix_hypervisor/containers"
        "$HYPERVISOR_MARKER_DIR" # Comes from phoenix_hypervisor_config.sh
    )

    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            if mkdir -p "$dir"; then
                log_info "Directory created: $dir"
            else
                log_error "Failed to create directory: $dir"
                exit 1
            fi
        fi
    done
    log_info "Directory setup completed"
}

# - Enhanced Configuration Setup -
setup_configuration() {
    log_info "Checking configuration files..."
    # Check critical config files (no creation, just validation)
    local critical_files=(
        "$PHOENIX_LXC_CONFIG_FILE"
        "$PHOENIX_LXC_CONFIG_SCHEMA_FILE"
    )
    # Add token file if defined
    if [[ -n "${PHOENIX_HF_TOKEN_FILE:-}" ]]; then
        critical_files+=("$PHOENIX_HF_TOKEN_FILE")
    fi

    for file in "${critical_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            log_error "Configuration file missing: $file"
            exit 1
        fi
        if [[ ! -r "$file" ]]; then
            log_error "Configuration file not readable: $file"
            exit 1
        fi
    done
    log_info "Configuration files checked successfully"
}

# - Enhanced NVIDIA Support Setup -
setup_nvidia_support() {
    log_info "Checking NVIDIA support..."
    # Check for NVIDIA driver on host (no repository additions)
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        log_error "NVIDIA driver not found on host. Please install NVIDIA drivers."
        exit 1
    fi
    # Verify GPU availability
    if ! nvidia-smi --query-gpu=name --format=csv --id=0 >/dev/null 2>&1; then
        log_error "No NVIDIA GPUs detected or nvidia-smi failed."
        exit 1
    fi
    log_info "NVIDIA GPU support verified on host"
}

# - Enhanced Service Setup -
setup_services() {
    log_info "Setting up service configurations..."
    # Check if systemd directory exists
    if [[ -d "/etc/systemd/system" ]]; then
        log_info "Service directory found: /etc/systemd/system"
        # Placeholder for future service setup logic if needed
    else
        log_warn "Service directory not found: /etc/systemd/system. Skipping service setup."
    fi
    log_info "Service setup completed"
}

# - Enhanced Validation -
validate_setup() {
    log_info "Validating setup..."
    # Basic validation checks
    local checks_passed=0
    local checks_failed=0

    # Use PHOENIX_HYPERVISOR_LIB_DIR from config if available, otherwise default
    local lib_dir="${PHOENIX_HYPERVISOR_LIB_DIR:-/usr/local/lib/phoenix_hypervisor}"
    # Check directories
    local required_dirs=(
        "$lib_dir"
        "/usr/local/bin/phoenix_hypervisor"
        "/var/lib/phoenix_hypervisor"
        "/var/log/phoenix_hypervisor"
        "$HYPERVISOR_MARKER_DIR"
    )
    for dir in "${required_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            ((checks_passed++))
        else
            log_error "Required directory missing: $dir"
            ((checks_failed++))
        fi
    done

    # Check config files presence
    local critical_files=(
        "$PHOENIX_LXC_CONFIG_FILE"
        "$PHOENIX_LXC_CONFIG_SCHEMA_FILE"
    )
    if [[ -n "${PHOENIX_HF_TOKEN_FILE:-}" ]]; then
        critical_files+=("$PHOENIX_HF_TOKEN_FILE")
    fi

    for file in "${critical_files[@]}"; do
        if [[ -f "$file" ]]; then
            ((checks_passed++))
        else
            log_error "Required file missing for final validation: $file"
            ((checks_failed++))
        fi
    done

    # Summary
    log_info "Setup validation: $checks_passed passed, $checks_failed failed"
    if [[ $checks_failed -gt 0 ]]; then
        log_warn "Validation had failures, but continuing. Subsequent steps may fail."
    fi
    log_info "Setup validation completed successfully"
}

# --- Main Execution ---
main() {
    log_info "Starting Phoenix Hypervisor initial setup..."
    echo ""
    echo "==============================================="
    echo "PHOENIX HYPERTORVISOR INITIAL SETUP"
    echo "==============================================="
    echo ""

    # Validate system requirements first
    setup_system_requirements

    # Set up directories
    setup_directories

    # Check configuration files (NO CREATION)
    setup_configuration

    # Set up NVIDIA support
    setup_nvidia_support

    # Set up services
    setup_services

    # Validate the entire setup
    validate_setup

    echo ""
    echo "==============================================="
    echo "SETUP COMPLETED SUCCESSFULLY"
    echo "==============================================="
    echo "Directories checked/created:"
    local lib_dir="${PHOENIX_HYPERVISOR_LIB_DIR:-/usr/local/lib/phoenix_hypervisor}"
    echo "- $lib_dir"
    echo "- /usr/local/bin/phoenix_hypervisor"
    echo "- /var/lib/phoenix_hypervisor"
    echo "- /var/log/phoenix_hypervisor"
    echo "- $HYPERVISOR_MARKER_DIR"
    echo ""
    echo "Configuration files checked (not created by this script):"
    echo "- $PHOENIX_LXC_CONFIG_FILE"
    echo "- $PHOENIX_LXC_CONFIG_SCHEMA_FILE"
    if [[ -n "${PHOENIX_HF_TOKEN_FILE:-}" ]]; then
        echo "- $PHOENIX_HF_TOKEN_FILE"
    fi
    echo ""
    echo "NVIDIA GPU support checked"
    echo "==============================================="
    log_info "Phoenix Hypervisor initial setup completed successfully"
}

# Call main function
main "$@"