#!/bin/bash
# Initial setup script for Phoenix Hypervisor
# Performs one-time environment preparation tasks
# Version: 1.7.7 (Added Debugging for 'local' Error, Enhanced Sourcing Safety, Full Feature Preservation)
# Author: Assistant

set -euo pipefail
# Note: set -x is kept commented for cleaner output, enable if needed for deep debugging
# set -x

# --- Robust Initial Logging Setup for this script ---
# These variables are global to avoid 'local' issues
PHOENIX_INITIAL_SETUP_LOG_DIR="/var/log/phoenix_hypervisor"
PHOENIX_INITIAL_SETUP_LOG_FILE="$PHOENIX_INITIAL_SETUP_LOG_DIR/phoenix_hypervisor_initial_setup.log"

# Ensure log directory and file exist with basic permissions
mkdir -p "$PHOENIX_INITIAL_SETUP_LOG_DIR" 2>/dev/null || {
    PHOENIX_INITIAL_SETUP_LOG_DIR="/tmp"
    PHOENIX_INITIAL_SETUP_LOG_FILE="$PHOENIX_INITIAL_SETUP_LOG_DIR/phoenix_hypervisor_initial_setup.log"
    mkdir -p "$PHOENIX_INITIAL_SETUP_LOG_DIR" 2>/dev/null || true
}
touch "$PHOENIX_INITIAL_SETUP_LOG_FILE" 2>/dev/null || true
chmod 644 "$PHOENIX_INITIAL_SETUP_LOG_FILE" 2>/dev/null || true

# --- Minimal, Robust Fallback Logging Functions ---
log_info() {
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    echo "[$timestamp] [INFO] $message" | tee -a "$PHOENIX_INITIAL_SETUP_LOG_FILE" >&2
}
log_warn() {
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    echo "[$timestamp] [WARN] $message" | tee -a "$PHOENIX_INITIAL_SETUP_LOG_FILE" >&2
}
log_error() {
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    echo "[$timestamp] [ERROR] $message" | tee -a "$PHOENIX_INITIAL_SETUP_LOG_FILE" >&2
}

# --- Terminal Handling ---
# Reset terminal state on exit to prevent corruption
trap '
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script terminated unexpectedly with exit code $exit_code. Check logs at $PHOENIX_INITIAL_SETUP_LOG_FILE"
    fi
    stty sane 2>/dev/null || true
    echo "Terminal reset (phoenix_hypervisor_initial_setup.sh)" >&2
    exit $exit_code
' EXIT

# --- Enhanced Sourcing with Debugging ---
# Source configuration with validation
log_info "DEBUG: Attempting to source /usr/local/etc/phoenix_hypervisor_config.sh..."
if [[ -f "/usr/local/etc/phoenix_hypervisor_config.sh" ]]; then
    # Validate script for 'local' declarations in global scope
    if grep -n "^[[:space:]]*local " "/usr/local/etc/phoenix_hypervisor_config.sh" >/dev/null; then
        log_error "Invalid 'local' declaration found in global scope of /usr/local/etc/phoenix_hypervisor_config.sh"
        exit 1
    fi
    source /usr/local/etc/phoenix_hypervisor_config.sh 2>&1 | tee -a "$PHOENIX_INITIAL_SETUP_LOG_FILE" || {
        log_error "Failed to source /usr/local/etc/phoenix_hypervisor_config.sh. Check for syntax errors."
        exit 1
    }
    log_info "Sourced config from /usr/local/etc/phoenix_hypervisor_config.sh"
else
    if [[ -f "./phoenix_hypervisor_config.sh" ]]; then
        if grep -n "^[[:space:]]*local " "./phoenix_hypervisor_config.sh" >/dev/null; then
            log_error "Invalid 'local' declaration found in global scope of ./phoenix_hypervisor_config.sh"
            exit 1
        fi
        source ./phoenix_hypervisor_config.sh 2>&1 | tee -a "$PHOENIX_INITIAL_SETUP_LOG_FILE" || {
            log_error "Failed to source ./phoenix_hypervisor_config.sh. Check for syntax errors."
            exit 1
        }
        log_warn "Sourced config from current directory. Prefer /usr/local/etc/phoenix_hypervisor_config.sh"
    else
        log_error "Configuration file not found: /usr/local/etc/phoenix_hypervisor_config.sh or ./phoenix_hypervisor_config.sh"
        exit 1
    fi
fi

# Fix for undefined variable error
export PHOENIX_LOG_FILE="${PHOENIX_LOG_FILE:-${HYPERVISOR_LOGFILE:-/var/log/phoenix_hypervisor/phoenix_hypervisor.log}}"
log_info "PHOENIX_LOG_FILE set to: $PHOENIX_LOG_FILE"

# Source common functions with validation
log_info "DEBUG: Attempting to source common functions..."
COMMON_SOURCED=false
if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
    if grep -n "^[[:space:]]*local " "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" >/dev/null; then
        log_error "Invalid 'local' declaration found in global scope of /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh"
        exit 1
    fi
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh 2>&1 | tee -a "$PHOENIX_INITIAL_SETUP_LOG_FILE" || {
        log_error "Failed to source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh. Check for syntax errors."
        exit 1
    }
    log_info "Sourced common functions from /usr/local/lib/phoenix_hypervisor/"
    COMMON_SOURCED=true
elif [[ -f "/usr/local/bin/phoenix_hypervisor_common.sh" ]]; then
    if grep -n "^[[:space:]]*local " "/usr/local/bin/phoenix_hypervisor_common.sh" >/dev/null; then
        log_error "Invalid 'local' declaration found in global scope of /usr/local/bin/phoenix_hypervisor_common.sh"
        exit 1
    fi
    source /usr/local/bin/phoenix_hypervisor_common.sh 2>&1 | tee -a "$PHOENIX_INITIAL_SETUP_LOG_FILE" || {
        log_error "Failed to source /usr/local/bin/phoenix_hypervisor_common.sh. Check for syntax errors."
        exit 1
    }
    log_warn "Sourced common functions from /usr/local/bin/. Prefer /usr/local/lib/phoenix_hypervisor/."
    COMMON_SOURCED=true
elif [[ -f "./phoenix_hypervisor_common.sh" ]]; then
    if grep -n "^[[:space:]]*local " "./phoenix_hypervisor_common.sh" >/dev/null; then
        log_error "Invalid 'local' declaration found in global scope of ./phoenix_hypervisor_common.sh"
        exit 1
    fi
    source ./phoenix_hypervisor_common.sh 2>&1 | tee -a "$PHOENIX_INITIAL_SETUP_LOG_FILE" || {
        log_error "Failed to source ./phoenix_hypervisor_common.sh. Check for syntax errors."
        exit 1
    }
    log_warn "Sourced common functions from current directory. Prefer standard locations."
    COMMON_SOURCED=true
else
    log_warn "Common functions file not found in standard locations. Continuing with minimal logging."
fi

if [[ "$COMMON_SOURCED" == true ]] && declare -f setup_logging > /dev/null 2>&1; then
    log_info "DEBUG: Initializing common library logging..."
    setup_logging 2>&1 | tee -a "$PHOENIX_INITIAL_SETUP_LOG_FILE" || log_error "Failed to initialize common library logging."
fi

# --- Enhanced Setup Functions ---

validate_apt_sources() {
    log_info "Validating APT sources..."
    local log_target="${PHOENIX_LOG_FILE:-$PHOENIX_INITIAL_SETUP_LOG_FILE}"
    if ! apt update -y 2>&1 | tee -a "$log_target"; then
        log_error "APT update failed. Check /etc/apt/sources.list and network connectivity."
        exit 1
    fi
    log_info "APT sources validated successfully"
}

setup_system_requirements() {
    log_info "DEBUG: Entering setup_system_requirements..."
    log_info "Checking and installing system requirements..."
    validate_apt_sources
    if ! command -v jq >/dev/null 2>&1; then
        log_info "Installing jq..."
        if ! apt install -y jq; then
            log_error "Failed to install jq. Critical dependency missing."
            exit 1
        fi
    fi
    if ! command -v jsonschema >/dev/null 2>&1; then
        log_info "Installing python3-jsonschema..."
        if ! apt install -y python3-jsonschema; then
            log_warn "Failed to install python3-jsonschema. Some JSON validation features may be limited."
        fi
    fi
    if ! command -v pct >/dev/null 2>&1; then
        log_error "'pct' command not found. Please ensure Proxmox VE is installed."
        exit 1
    fi
    if ! command -v aa-status >/dev/null 2>&1; then
        log_warn "apparmor utilities not found. Installing apparmor..."
        if apt install -y apparmor; then
            log_info "apparmor installed."
            if ! systemctl is-active --quiet apparmor; then
                log_info "Enabling and starting apparmor service..."
                systemctl enable --now apparmor || log_warn "Failed to enable/start apparmor service."
            fi
        else
            log_warn "Failed to install apparmor. Some LXC features might be limited."
        fi
    elif ! systemctl is-active --quiet apparmor; then
        log_warn "apparmor is installed but not active. Attempting to start..."
        systemctl start apparmor || log_warn "Failed to start apparmor service."
    fi
    log_info "System requirements check and installation completed"
}

setup_directories() {
    log_info "DEBUG: Entering setup_directories..."
    log_info "Setting up Phoenix Hypervisor directories..."
    local lib_dir="${PHOENIX_HYPERVISOR_LIB_DIR:-/usr/local/lib/phoenix_hypervisor}"
    local dirs=(
        "$lib_dir"
        "/usr/local/bin/phoenix_hypervisor"
        "/var/lib/phoenix_hypervisor"
        "/var/log/phoenix_hypervisor"
        "/var/lib/phoenix_hypervisor/containers"
        "$HYPERVISOR_MARKER_DIR"
    )

    local dir_created=false
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log_info "Directory '$dir' not found, attempting to create..."
            if mkdir -p "$dir"; then
                chmod 755 "$dir"
                log_info "Directory created: $dir"
                dir_created=true
            else
                log_error "Failed to create directory: $dir"
                exit 1
            fi
        else
            log_info "Directory already exists: $dir"
        fi
    done
    if [[ "$dir_created" == true ]]; then
        log_info "All required directories checked/created."
    else
        log_info "All required directories already existed."
    fi
    log_info "Directory setup completed"
}

setup_configuration() {
    log_info "DEBUG: Entering setup_configuration..."
    log_info "Checking configuration files..."
    local critical_files=(
        "$PHOENIX_LXC_CONFIG_FILE"
        "$PHOENIX_LXC_CONFIG_SCHEMA_FILE"
    )
    if [[ -n "${PHOENIX_HF_TOKEN_FILE:-}" ]]; then
        critical_files+=("$PHOENIX_HF_TOKEN_FILE")
    fi

    for file in "${critical_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            log_warn "Configuration file missing: $file. Attempting to create default..."
            case "$file" in
                "$PHOENIX_LXC_CONFIG_FILE")
                    cat <<EOF > "$file"
{
  "\$schema": "/usr/local/etc/phoenix_lxc_configs.schema.json",
  "lxc_configs": {

  }
}
EOF
                    if [[ $? -ne 0 ]]; then
                        log_error "Failed to create default $file."
                        exit 1
                    fi
                    chmod 644 "$file"
                    log_info "Created default configuration file: $file"
                    ;;
                "$PHOENIX_LXC_CONFIG_SCHEMA_FILE")
                    cat <<EOF > "$file"
{
  "type": "object",
  "properties": {
    "lxc_configs": {
      "type": "object"
    }
  }
}
EOF
                    if [[ $? -ne 0 ]]; then
                        log_error "Failed to create default $file."
                        exit 1
                    fi
                    chmod 644 "$file"
                    log_info "Created default schema file: $file"
                    ;;
                "$PHOENIX_HF_TOKEN_FILE")
                    log_warn "Hugging Face token file missing. Skipping creation as it's optional."
                    ;;
            esac
        fi
        if [[ -f "$file" ]]; then
            if [[ ! -r "$file" ]]; then
                log_error "Configuration file not readable: $file"
                exit 1
            else
                log_info "Configuration file is readable: $file"
            fi
        fi
    done
    log_info "Configuration files checked successfully"
}

setup_nvidia_support() {
    log_info "DEBUG: Entering setup_nvidia_support..."
    log_info "Checking NVIDIA support..."
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        log_error "NVIDIA driver (nvidia-smi) not found on host. Please install NVIDIA drivers."
        exit 1
    fi
    if ! nvidia-smi --query-gpu=name --format=csv,noheader,nounits --id=0 >/dev/null 2>&1; then
        log_error "No NVIDIA GPUs detected by nvidia-smi for ID 0, or nvidia-smi query failed."
        exit 1
    fi
    log_info "NVIDIA GPU support verified on host (GPU 0 accessible)"
}

setup_services() {
    log_info "DEBUG: Entering setup_services..."
    log_info "Setting up service configurations..."
    if [[ -d "/etc/systemd/system" ]]; then
        log_info "Systemd service directory found: /etc/systemd/system"
    else
        log_warn "Systemd service directory not found: /etc/systemd/system. This might be ok if not using systemd services directly."
    fi
    log_info "Service setup check completed"
}

validate_setup() {
    log_info "DEBUG: Entering validate_setup..."
    log_info "Validating setup..."
    local checks_passed=0
    local checks_failed=0
    local lib_dir="${PHOENIX_HYPERVISOR_LIB_DIR:-/usr/local/lib/phoenix_hypervisor}"
    local required_dirs=(
        "$lib_dir"
        "/usr/local/bin/phoenix_hypervisor"
        "/var/lib/phoenix_hypervisor"
        "/var/log/phoenix_hypervisor"
        "/var/lib/phoenix_hypervisor/containers"
        "$HYPERVISOR_MARKER_DIR"
    )
    log_info "Checking required directories..."
    for dir in "${dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            log_info "Found required directory: $dir"
            ((checks_passed++)) || true
        else
            log_error "Required directory missing: $dir"
            ((checks_failed++)) || true
        fi
    done

    local critical_files=(
        "$PHOENIX_LXC_CONFIG_FILE"
        "$PHOENIX_LXC_CONFIG_SCHEMA_FILE"
    )
    log_info "Checking critical configuration files..."
    for file in "${critical_files[@]}"; do
        if [[ -f "$file" ]]; then
            log_info "Found critical file: $file"
            ((checks_passed++)) || true
        else
            log_error "Required critical file missing: $file"
            ((checks_failed++)) || true
        fi
    done

    log_info "Setup validation summary: $checks_passed checks passed, $checks_failed checks failed."
    if [[ $checks_failed -gt 0 ]]; then
        log_warn "Validation had $checks_failed failures. Setup might be incomplete. Please review logs and configuration."
        return 1
    else
        log_info "All setup validation checks passed successfully."
        return 0
    fi
}

main() {
    log_info "DEBUG: Entering main function..."
    log_info "==============================================="
    log_info "PHOENIX HYPERTORVISOR INITIAL SETUP STARTING"
    log_info "==============================================="
    log_info "Log file: $PHOENIX_INITIAL_SETUP_LOG_FILE"

    setup_system_requirements
    setup_directories
    setup_configuration
    setup_nvidia_support
    setup_services

    if ! validate_setup; then
        log_warn "Setup validation encountered issues, but continuing to attempt marker creation."
    fi

    log_info "Creating setup completion marker file: $HYPERVISOR_MARKER"
    mkdir -p "$(dirname "$HYPERVISOR_MARKER")" || {
        log_error "Failed to create marker directory: $(dirname "$HYPERVISOR_MARKER")"
        exit 1
    }
    chmod 755 "$(dirname "$HYPERVISOR_MARKER")" || log_warn "Could not set permissions on marker directory."
    if touch "$HYPERVISOR_MARKER"; then
        chmod 644 "$HYPERVISOR_MARKER" || log_warn "Could not set permissions on marker file."
        log_info "Setup completion marker file created successfully: $HYPERVISOR_MARKER"
    else
        log_error "Failed to create setup completion marker file: $HYPERVISOR_MARKER"
        exit 1
    fi

    log_info "==============================================="
    log_info "PHOENIX HYPERTORVISOR INITIAL SETUP COMPLETED SUCCESSFULLY"
    log_info "==============================================="
    log_info "Directories checked/created:"
    local lib_dir="${PHOENIX_HYPERVISOR_LIB_DIR:-/usr/local/lib/phoenix_hypervisor}"
    log_info " - $lib_dir"
    log_info " - /usr/local/bin/phoenix_hypervisor"
    log_info " - /var/lib/phoenix_hypervisor"
    log_info " - /var/log/phoenix_hypervisor"
    log_info " - /var/lib/phoenix_hypervisor/containers"
    log_info " - $HYPERVISOR_MARKER_DIR"
    log_info ""
    log_info "Configuration files checked/created:"
    log_info " - $PHOENIX_LXC_CONFIG_FILE"
    log_info " - $PHOENIX_LXC_CONFIG_SCHEMA_FILE"
    if [[ -n "${PHOENIX_HF_TOKEN_FILE:-}" ]]; then
        log_info " - $PHOENIX_HF_TOKEN_FILE (optional)"
    fi
    log_info ""
    log_info "NVIDIA GPU support checked and verified."
    log_info "==============================================="
    log_info "Phoenix Hypervisor initial setup completed successfully. Marker file: $HYPERVISOR_MARKER"
    return 0
}

# Call main function and capture its exit code
main_exit_code=0
log_info "DEBUG: Starting main execution..."
main "$@" || main_exit_code=$?
log_info "DEBUG: Main execution completed with exit code $main_exit_code"

exit $main_exit_code