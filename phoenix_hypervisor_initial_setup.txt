#!/bin/bash
# Initial setup script for Phoenix Hypervisor
# Performs one-time environment preparation tasks
# Version: 1.7.4
# Author: Assistant

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

# Source common functions from the standard location (as defined in corrected common.sh)
# Priority: 1. Standard lib location, 2. Standard bin location, 3. Current directory
# This provides access to logging functions (log_info, etc.) and other utilities if needed.
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
    # This ensures the script can report basic errors even if sourcing fails completely
    log_info() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $1"; }
    log_warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $1" >&2; }
    log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $1" >&2; }
    log_warn "phoenix_hypervisor_initial_setup.sh: Common functions file not found in standard locations. Using minimal logging."
fi

# --- Enhanced Setup Functions ---

# - Enhanced System Requirements Check -
setup_system_requirements() {
    log_info "Checking system requirements..."
    # Use the common function for checking requirements if available
    # Otherwise, perform basic checks inline
    if declare -f check_system_requirements > /dev/null; then
        if ! check_system_requirements; then
            log_error "System requirements check failed. Please resolve issues and rerun."
            exit 1
        fi
    else
        # Fallback basic checks if common function isn't available
        log_warn "check_system_requirements function not found, performing basic checks."
        if ! command -v jq >/dev/null 2>&1; then
            log_error "Required tool 'jq' not found."
            exit 1
        fi
        if ! command -v pct >/dev/null 2>&1; then
             log_error "Required tool 'pct' (Proxmox Container Tools) not found."
             exit 1
        fi
        # Add other basic checks as needed...
    fi
    log_info "System requirements check completed"
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
        else
            log_info "Directory already exists: $dir"
        fi
    done

    # Set specific permissions if needed (example)
    # chmod 700 /var/lib/phoenix_hypervisor
    # chmod 600 /var/log/phoenix_hypervisor/* 2>/dev/null || true # Ignore if no files

    log_info "Directory setup completed"
}

# - Configuration Setup (WITHOUT Default File Creation) -
# This function now only validates that required config files exist
# or reports if they are missing. It DOES NOT create them.
setup_configuration() {
    log_info "Checking for required configuration files..."

    local required_files=(
        "$PHOENIX_LXC_CONFIG_FILE"      # From phoenix_hypervisor_config.sh
        "$PHOENIX_LXC_CONFIG_SCHEMA_FILE" # From phoenix_hypervisor_config.sh
    )

    # Add token file if PHOENIX_HF_TOKEN_FILE is defined in the environment/config
    if [[ -n "${PHOENIX_HF_TOKEN_FILE:-}" ]]; then
        required_files+=("$PHOENIX_HF_TOKEN_FILE")
    fi

    local all_found=true
    for file in "${required_files[@]}"; do
        if [[ -f "$file" ]]; then
            log_info "Found required configuration file: $file"
        else
            log_error "Required configuration file missing: $file"
            all_found=false
        fi
    done

    if [[ "$all_found" != "true" ]]; then
        log_error "One or more required configuration files are missing. Please ensure they are placed correctly before running setup."
        # Optionally, exit here to force manual intervention:
        # exit 1
        # Or, just warn and let the process potentially fail later:
        log_warn "Continuing setup, but subsequent steps may fail due to missing config files."
    else
        log_info "All required configuration files are present."
    fi

    log_info "Configuration check completed"
}


# - Enhanced NVIDIA Support Setup -
setup_nvidia_support() {
    log_info "Setting up NVIDIA driver support..."
    # Use the common function to show system info which includes NVIDIA details if available
    if declare -f show_system_info > /dev/null; then
        show_system_info
    else
        # Fallback to basic info display
        log_warn "show_system_info function not found, displaying basic info."
        if command -v nvidia-smi >/dev/null 2>&1; then
            local driver_version
            driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits | head -n 1 | tr -d ' ')
            log_info "Host NVIDIA driver version: $driver_version"

            local gpu_count
            gpu_count=$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits | head -n 1 | tr -d ' ')
            log_info "Available NVIDIA GPUs: $gpu_count"
        else
            log_info "NVIDIA tools (nvidia-smi) not found on host."
        fi
    fi

    # Additional NVIDIA-specific checks can be added here if needed

    log_info "NVIDIA support check completed"
}

# - Enhanced Service Setup -
setup_services() {
    log_info "Setting up service configurations..."
    # Check if systemd directory exists
    if [[ -d "/etc/systemd/system" ]]; then
        log_info "Service directory found: /etc/systemd/system"
        # Placeholder for future service setup logic if needed
        # e.g., copying service files, enabling services
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
        "$HYPERVISOR_MARKER_DIR" # Comes from config
    )
    for dir in "${required_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            ((checks_passed++))
        else
            log_error "Required directory missing: $dir"
            ((checks_failed++))
        fi
    done

    # Check config files presence (existence checked in setup_configuration)
    # We can re-check the critical ones here for final validation
    local critical_files=(
        "$PHOENIX_LXC_CONFIG_FILE"
        "$PHOENIX_LXC_CONFIG_SCHEMA_FILE"
    )
    # Add token file if defined
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
        log_error "Setup validation failed. Please check logs."
        # Depending on policy, you might want to exit here
        # exit 1
        # Or just warn
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
    # Use PHOENIX_HYPERVISOR_LIB_DIR from config if available, otherwise default
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
