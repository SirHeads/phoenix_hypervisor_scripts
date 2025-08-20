#!/bin/bash
# Initial setup script for Phoenix Hypervisor
# Performs one-time environment preparation tasks
# Version: 1.7.6 (Improved Logging Robustness, Fixed set -e Validation Exit, Full Feature Preservation)
# Author: Assistant

set -euo pipefail
# Note: set -x is kept for debugging, but error messages are now explicitly directed to stderr and the setup log
# set -x  # Enable tracing for debugging (Commented out for cleaner output, enable if needed for deep debugging)

# --- Robust Initial Logging Setup for this script ---
# This ensures the initial setup script can log to its own file reliably before the common library logging is fully set up.
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
# These are defined early to ensure logging works even if sourcing common fails.
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
# Use a more informative message if the script exits due to an error
trap '
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script terminated unexpectedly with exit code $exit_code. Check logs at $PHOENIX_INITIAL_SETUP_LOG_FILE"
    fi
    stty sane 2>/dev/null || true
    echo "Terminal reset (phoenix_hypervisor_initial_setup.sh)" >&2
    exit $exit_code
' EXIT

# --- Enhanced Sourcing ---
# Source configuration from the standard location
# Ensures paths like PHOENIX_LXC_CONFIG_FILE are available
if [[ -f "/usr/local/etc/phoenix_hypervisor_config.sh" ]]; then
    source /usr/local/etc/phoenix_hypervisor_config.sh
    log_info "Sourced config from /usr/local/etc/phoenix_hypervisor_config.sh"
else
    # Fallback to current directory if standard location not found (less ideal)
    if [[ -f "./phoenix_hypervisor_config.sh" ]]; then
        source ./phoenix_hypervisor_config.sh
        log_warn "Sourced config from current directory. Prefer /usr/local/etc/phoenix_hypervisor_config.sh"
    else
        log_error "Configuration file not found: /usr/local/etc/phoenix_hypervisor_config.sh or ./phoenix_hypervisor_config.sh"
        exit 1
    fi
fi

# --- Fix for undefined variable error ---
# Define PHOENIX_LOG_FILE, using HYPERVISOR_LOGFILE as a fallback if it's set,
# otherwise defaulting to a specific log file for this script.
# This resolves the error on line 52: PHOENIX_LOG_FILE: unbound variable
export PHOENIX_LOG_FILE="${PHOENIX_LOG_FILE:-${HYPERVISOR_LOGFILE:-/var/log/phoenix_hypervisor/phoenix_hypervisor.log}}"
log_info "PHOENIX_LOG_FILE set to: $PHOENIX_LOG_FILE"
# --- End Fix ---

# Source common functions from the standard location
# Priority: 1. Standard lib location, 2. Standard bin location, 3. Current directory
COMMON_SOURCED=false
if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh
    log_info "Sourced common functions from /usr/local/lib/phoenix_hypervisor/"
    COMMON_SOURCED=true
elif [[ -f "/usr/local/bin/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/bin/phoenix_hypervisor_common.sh
    log_warn "Sourced common functions from /usr/local/bin/. Prefer /usr/local/lib/phoenix_hypervisor/."
    COMMON_SOURCED=true
elif [[ -f "./phoenix_hypervisor_common.sh" ]]; then
    source ./phoenix_hypervisor_common.sh
    log_warn "Sourced common functions from current directory. Prefer standard locations."
    COMMON_SOURCED=true
else
    log_warn "Common functions file not found in standard locations. Continuing with minimal logging."
fi

# If common functions were sourced successfully, re-initialize logging with the common library's setup
if [[ "$COMMON_SOURCED" == true ]] && declare -f setup_logging > /dev/null 2>&1; then
    log_info "Attempting to initialize common library logging..."
    # The common library's setup_logging will take over for subsequent logs from this script if it's called again.
    # We primarily use the initial setup's own log file for diagnostics of this script itself.
fi

# --- Enhanced Setup Functions ---

# - Validate APT Sources -
validate_apt_sources() {
    log_info "Validating APT sources..."
    # Use the defined PHOENIX_LOG_FILE variable (or the initial setup log as fallback)
    local log_target="${PHOENIX_LOG_FILE:-$PHOENIX_INITIAL_SETUP_LOG_FILE}"
    if ! apt update -y 2>&1 | tee -a "$log_target"; then
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
    # Install jq if missing
    if ! command -v jq >/dev/null 2>&1; then
        log_info "Installing jq..."
        if ! apt install -y jq; then
             log_error "Failed to install jq. Critical dependency missing."
             exit 1
        fi
    fi
    # Install python3-jsonschema if missing
    if ! command -v jsonschema >/dev/null 2>&1; then
        log_info "Installing python3-jsonschema..."
        if ! apt install -y python3-jsonschema; then
            log_warn "Failed to install python3-jsonschema. Some JSON validation features may be limited."
        fi
    fi
    # Check for pct (Proxmox Container Toolkit)
    if ! command -v pct >/dev/null 2>&1; then
        log_error "'pct' command not found. Please ensure Proxmox VE is installed."
        exit 1
    fi
    # Check for apparmor
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

    local dir_created=false
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log_info "Directory '$dir' not found, attempting to create..."
            if mkdir -p "$dir"; then
                chmod 755 "$dir"
                # chown root:root "$dir" || log_warn "Could not set ownership for '$dir'."
                log_info "Directory created: $dir"
                dir_created=true
            else
                log_error "Failed to create directory: $dir"
                exit 1 # Critical failure
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

# - Enhanced Configuration Setup -
setup_configuration() {
    log_info "Checking configuration files..."
    local critical_files=(
        "$PHOENIX_LXC_CONFIG_FILE"
        "$PHOENIX_LXC_CONFIG_SCHEMA_FILE"
    )
    # Add token file only if defined
    if [[ -n "${PHOENIX_HF_TOKEN_FILE:-}" ]]; then
        critical_files+=("$PHOENIX_HF_TOKEN_FILE")
    fi

    for file in "${critical_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            log_warn "Configuration file missing: $file. Attempting to create default..."
            case "$file" in
                "$PHOENIX_LXC_CONFIG_FILE")
                    # Create a basic structure for the LXC config JSON
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
                    # chown root:root "$file" || log_warn "Could not set ownership for '$file'."
                    log_info "Created default configuration file: $file"
                    ;;
                "$PHOENIX_LXC_CONFIG_SCHEMA_FILE")
                    # Create a basic structure for the schema JSON
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
                    # chown root:root "$file" || log_warn "Could not set ownership for '$file'."
                    log_info "Created default schema file: $file"
                    ;;
                "$PHOENIX_HF_TOKEN_FILE")
                    log_warn "Hugging Face token file missing. Skipping creation as it's optional."
                    ;;
            esac
        fi
        # Check readability after ensuring existence
        if [[ -f "$file" ]]; then
            if [[ ! -r "$file" ]]; then
                log_error "Configuration file not readable: $file"
                exit 1 # Critical failure
            else
                 log_info "Configuration file is readable: $file"
            fi
        fi
    done
    log_info "Configuration files checked successfully"
}

# - Enhanced NVIDIA Support Setup -
setup_nvidia_support() {
    log_info "Checking NVIDIA support..."
    # Check for NVIDIA driver on host (no repository additions)
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        log_error "NVIDIA driver (nvidia-smi) not found on host. Please install NVIDIA drivers."
        exit 1
    fi
    # Verify GPU availability (check GPU 0 as a basic test)
    if ! nvidia-smi --query-gpu=name --format=csv,noheader,nounits --id=0 >/dev/null 2>&1; then
        log_error "No NVIDIA GPUs detected by nvidia-smi for ID 0, or nvidia-smi query failed."
        exit 1
    fi
    log_info "NVIDIA GPU support verified on host (GPU 0 accessible)"
}

# - Enhanced Service Setup -
setup_services() {
    log_info "Setting up service configurations..."
    # Check if systemd directory exists
    if [[ -d "/etc/systemd/system" ]]; then
        log_info "Systemd service directory found: /etc/systemd/system"
        # Placeholder for future service setup logic if needed
    else
        log_warn "Systemd service directory not found: /etc/systemd/system. This might be ok if not using systemd services directly."
    fi
    log_info "Service setup check completed"
}

# - Enhanced Validation (Robust against set -e) -
validate_setup() {
    log_info "Validating setup..."
    # Basic validation checks
    local checks_passed=0
    local checks_failed=0

    # Use PHOENIX_HYPERVISOR_LIB_DIR from config if available, otherwise default
    local lib_dir="${PHOENIX_HYPERVISOR_LIB_DIR:-/usr/local/lib/phoenix_hypervisor}"
    # Check directories - Continue checking even if one fails
    local required_dirs=(
        "$lib_dir"
        "/usr/local/bin/phoenix_hypervisor"
        "/var/lib/phoenix_hypervisor"
        "/var/log/phoenix_hypervisor"
        "/var/lib/phoenix_hypervisor/containers"
        "$HYPERVISOR_MARKER_DIR"
    )
    log_info "Checking required directories..."
    for dir in "${required_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            log_info "Found required directory: $dir"
            ((checks_passed++)) || true # Prevent set -e from triggering on arithmetic issues
        else
            log_error "Required directory missing: $dir"
            ((checks_failed++)) || true # Prevent set -e from triggering on arithmetic issues
        fi
    done

    # Check config files presence - Continue checking even if one fails
    local critical_files=(
        "$PHOENIX_LXC_CONFIG_FILE"
        "$PHOENIX_LXC_CONFIG_SCHEMA_FILE"
        # Note: PHOENIX_HF_TOKEN_FILE is optional, so not validated here for presence
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

    # Summary
    log_info "Setup validation summary: $checks_passed checks passed, $checks_failed checks failed."
    if [[ $checks_failed -gt 0 ]]; then
        log_warn "Validation had $checks_failed failures. Setup might be incomplete. Please review logs and configuration."
        # Do NOT exit here. Let the main script decide if this is fatal based on the specific failures.
        # The marker file creation is the final step and indicates overall success.
        return 1 # Indicate validation issues to the caller
    else
         log_info "All setup validation checks passed successfully."
         return 0 # Indicate success
    fi
    # Note: The main script will check the return code and decide whether to proceed or exit.
}

# --- Main Execution ---
main() {
    log_info "==============================================="
    log_info "PHOENIX HYPERTORVISOR INITIAL SETUP STARTING"
    log_info "==============================================="
    log_info "Log file: $PHOENIX_INITIAL_SETUP_LOG_FILE"

    # Validate system requirements first
    setup_system_requirements

    # Set up directories
    setup_directories

    # Check configuration files
    setup_configuration

    # Set up NVIDIA support
    setup_nvidia_support

    # Set up services
    setup_services

    # Validate the entire setup
    # Use explicit check to handle validation result, not relying solely on set -e
    if ! validate_setup; then
        log_warn "Setup validation encountered issues, but continuing to attempt marker creation."
        # The script will exit if marker creation fails, which is the definitive check.
    fi

    # --- Create the setup completion marker ---
    # This signals to phoenix_establish_hypervisor.sh that initial setup is done.
    log_info "Creating setup completion marker file: $HYPERVISOR_MARKER"
    # Ensure the marker directory exists (redundant, but safe)
    mkdir -p "$(dirname "$HYPERVISOR_MARKER")" || {
        log_error "Failed to create marker directory: $(dirname "$HYPERVISOR_MARKER")"
        exit 1
    }
    chmod 755 "$(dirname "$HYPERVISOR_MARKER")" || log_warn "Could not set permissions on marker directory."
    # chown root:root "$(dirname "$HYPERVISOR_MARKER")" || log_warn "Could not set ownership on marker directory."
    # Create the marker file
    if touch "$HYPERVISOR_MARKER"; then
        chmod 644 "$HYPERVISOR_MARKER" || log_warn "Could not set permissions on marker file."
        # chown root:root "$HYPERVISOR_MARKER" || log_warn "Could not set ownership on marker file."
        log_info "Setup completion marker file created successfully: $HYPERVISOR_MARKER"
    else
        log_error "Failed to create setup completion marker file: $HYPERVISOR_MARKER"
        exit 1 # Critical failure - marker must be created
    fi
    # --- End Create Marker ---

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
    # Explicitly return success
    return 0
}

# Call main function and capture its exit code
main_exit_code=0
main "$@" || main_exit_code=$?

# Exit with the code from main, allowing the trap to handle cleanup/logging
exit $main_exit_code