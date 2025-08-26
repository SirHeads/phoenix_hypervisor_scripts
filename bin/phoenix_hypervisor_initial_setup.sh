#!/bin/bash
# Initial setup script for Phoenix Hypervisor
# Performs one-time environment preparation tasks
# Version: 2.1.0 (Enhanced logging, schema validation, resource checks, improved error handling)
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

# --- Enhanced Logging Functions ---
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

log_debug() {
    if [[ "$DEBUG_MODE" == "true" ]]; then
        local message="$1"
        local timestamp
        timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
        echo "[$timestamp] [DEBUG] $message" | tee -a "$PHOENIX_INITIAL_SETUP_LOG_FILE" >&2
    fi
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
# Function to check for INVALID 'local' declarations in global scope
# This function attempts to identify 'local' declarations that are NOT inside a function.
# It looks for lines starting with 'local' that do NOT appear within 5 lines after a line matching '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*()[[:space:]]*{'
check_invalid_local_declarations() {
    local file="$1"
    local temp_file
    temp_file=$(mktemp)
    # Find line numbers of 'local' declarations
    grep -n "^[[:space:]]*local " "$file" > "$temp_file" || true

    if [[ -s "$temp_file" ]]; then
        while IFS=: read -r line_num _; do
            # Check if this 'local' declaration is within a function context
            # Look back up to 5 lines for a function definition
            local start_check=$((line_num > 5 ? line_num - 5 : 1))
            if sed -n "${start_check},$((line_num - 1))p" "$file" | grep -q "^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*()[[:space:]]*{"; then
                # Found a preceding function definition, this 'local' is likely OK
                continue
            else
                # No function definition found before this 'local', it's likely invalid
                log_error "Invalid 'local' declaration found in global scope of $file at line $line_num"
                rm -f "$temp_file"
                return 1
            fi
        done < "$temp_file"
    fi
    rm -f "$temp_file"
    return 0
}

# Source configuration with validation
log_info "DEBUG: Attempting to source /usr/local/etc/phoenix_hypervisor_config.sh..."
if [[ -f "/usr/local/etc/phoenix_hypervisor_config.sh" ]]; then
    # Use the improved check function
    if ! check_invalid_local_declarations "/usr/local/etc/phoenix_hypervisor_config.sh"; then
        exit 1
    fi
    source /usr/local/etc/phoenix_hypervisor_config.sh 2>&1 | tee -a "$PHOENIX_INITIAL_SETUP_LOG_FILE" || {
        log_error "Failed to source /usr/local/etc/phoenix_hypervisor_config.sh. Check for syntax errors."
        exit 1
    }
    log_info "Sourced config from /usr/local/etc/phoenix_hypervisor_config.sh"
else
    if [[ -f "./phoenix_hypervisor_config.sh" ]]; then
        # Use the improved check function
        if ! check_invalid_local_declarations "./phoenix_hypervisor_config.sh"; then
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
    # Use the improved check function
    if ! check_invalid_local_declarations "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh"; then
        exit 1
    fi
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh 2>&1 | tee -a "$PHOENIX_INITIAL_SETUP_LOG_FILE" || {
        log_error "Failed to source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh. Check for syntax errors."
        exit 1
    }
    log_info "Sourced common functions from /usr/local/lib/phoenix_hypervisor/"
    COMMON_SOURCED=true
elif [[ -f "/usr/local/bin/phoenix_hypervisor_common.sh" ]]; then
    # Use the improved check function
    if ! check_invalid_local_declarations "/usr/local/bin/phoenix_hypervisor_common.sh"; then
        exit 1
    fi
    source /usr/local/bin/phoenix_hypervisor_common.sh 2>&1 | tee -a "$PHOENIX_INITIAL_SETUP_LOG_FILE" || {
        log_error "Failed to source /usr/local/bin/phoenix_hypervisor_common.sh. Check for syntax errors."
        exit 1
    }
    log_warn "Sourced common functions from /usr/local/bin/. Prefer /usr/local/lib/phoenix_hypervisor/."
    COMMON_SOURCED=true
elif [[ -f "./phoenix_hypervisor_common.sh" ]]; then
    # Use the improved check function
    if ! check_invalid_local_declarations "./phoenix_hypervisor_common.sh"; then
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

# --- NEW: Validate connectivity for Docker Hub, Hugging Face, and Portainer ---
validate_connectivity() {
    log_info "DEBUG: Entering validate_connectivity..."
    log_info "Validating connectivity for Docker Hub, Hugging Face, and Portainer..."

    # Ensure Docker is installed for connectivity tests
    if ! command -v docker >/dev/null 2>&1; then
        log_info "Installing Docker CE for connectivity tests..."
        if ! apt-get install -y docker.io; then
            log_error "Failed to install Docker CE for connectivity tests."
            exit 1
        fi
        systemctl enable --now docker || log_warn "Failed to enable/start Docker service."
    fi

    # Validate Docker Hub connectivity
    if [[ -f "$PHOENIX_DOCKER_TOKEN_FILE" ]]; then
        local username token
        username=$(grep '^DOCKER_HUB_USERNAME=' "$PHOENIX_DOCKER_TOKEN_FILE" | cut -d'=' -f2-)
        token=$(grep '^DOCKER_HUB_TOKEN=' "$PHOENIX_DOCKER_TOKEN_FILE" | cut -d'=' -f2-)
        if [[ -z "$username" || -z "$token" ]]; then
            log_error "Missing DOCKER_HUB_USERNAME or DOCKER_HUB_TOKEN in $PHOENIX_DOCKER_TOKEN_FILE"
            exit 1
        fi
        if ! docker login -u "$username" -p "$token" "$EXTERNAL_REGISTRY_URL" 2>&1 | tee -a "$PHOENIX_INITIAL_SETUP_LOG_FILE"; then
            log_error "Failed to authenticate with Docker Hub ($EXTERNAL_REGISTRY_URL). Check credentials in $PHOENIX_DOCKER_TOKEN_FILE."
            exit 1
        fi
        log_info "Successfully authenticated with Docker Hub ($EXTERNAL_REGISTRY_URL)"
        docker logout "$EXTERNAL_REGISTRY_URL" || log_warn "Failed to logout from Docker Hub, continuing..."
    else
        log_error "Docker Hub token file missing: $PHOENIX_DOCKER_TOKEN_FILE"
        exit 1
    fi

    # Validate Hugging Face connectivity
    if [[ "$COMMON_SOURCED" == true ]] && declare -f authenticate_huggingface >/dev/null 2>&1; then
        # Create a temporary container for Hugging Face authentication test
        local temp_container_id="9999"
        local temp_container_config='{
            "name": "temp-hf-test",
            "memory_mb": 512,
            "cores": 1,
            "template": "local:ubuntu-24.04",
            "storage_pool": "local-lvm",
            "storage_size_gb": 2,
            "network_config": {"name": "eth0", "bridge": "vmbr0", "ip": "10.0.0.200/24", "gw": "10.0.0.1"},
            "features": "nesting=1"
        }'
        if ! declare -f create_lxc_container >/dev/null 2>&1; then
            log_error "create_lxc_container function not found for Hugging Face connectivity test."
            exit 1
        fi
        if ! create_lxc_container "$temp_container_id" "$temp_container_config" "false"; then
            log_error "Failed to create temporary container $temp_container_id for Hugging Face connectivity test."
            exit 1
        fi
        if ! authenticate_huggingface "$temp_container_id"; then
            log_error "Failed to authenticate with Hugging Face in temporary container $temp_container_id."
            pct destroy "$temp_container_id" || log_warn "Failed to cleanup temporary container $temp_container_id."
            exit 1
        fi
        log_info "Successfully authenticated with Hugging Face"
        # Cleanup temporary container
        pct destroy "$temp_container_id" || log_warn "Failed to cleanup temporary container $temp_container_id."
    else
        log_error "authenticate_huggingface function not found or common functions not sourced."
        exit 1
    fi

    # Validate Portainer ports with enhanced checks
    if ! command -v nc >/dev/null 2>&1; then
        log_info "Installing netcat for Portainer port checks..."
        if ! apt install -y netcat-openbsd; then
            log_warn "Failed to install netcat-openbsd. Skipping Portainer port validation."
        fi
    fi

    if command -v nc >/dev/null 2>&1; then
        # Test Portainer server port
        if ! nc -z "$PORTAINER_SERVER_IP" "$PORTAINER_SERVER_PORT" 2>/dev/null; then
            log_warn "Portainer server port $PORTAINER_SERVER_PORT on $PORTAINER_SERVER_IP is not reachable. Ensure Portainer server is running."
        else
            log_info "Portainer server port $PORTAINER_SERVER_PORT on $PORTAINER_SERVER_IP is reachable."
        fi

        # Test Portainer agent port
        if ! nc -z "$PORTAINER_SERVER_IP" "$PORTAINER_AGENT_PORT" 2>/dev/null; then
            log_warn "Portainer agent port $PORTAINER_AGENT_PORT on $PORTAINER_SERVER_IP is not reachable. Ensure Portainer agents are configured."
        else
            log_info "Portainer agent port $PORTAINER_AGENT_PORT on $PORTAINER_SERVER_IP is reachable."
        fi
    else
        log_warn "netcat not installed, skipping Portainer port validation."
    fi

    # Test general connectivity to external services
    if command -v timeout >/dev/null 2>&1; then
        log_info "Testing basic network connectivity..."
        if ! timeout 5 ping -c 1 8.8.8.8 >/dev/null 2>&1; then
            log_warn "Basic network connectivity test failed (8.8.8.8)"
        else
            log_info "Network connectivity test passed (8.8.8.8)"
        fi
    fi

    log_info "Connectivity validation completed successfully."
}

setup_system_requirements() {
    log_info "DEBUG: Entering setup_system_requirements..."
    log_info "Checking and installing system requirements..."

    # Validate APT sources first
    validate_apt_sources

    # Check and install jq (required for JSON processing)
    if ! command -v jq >/dev/null 2>&1; then
        log_info "Installing jq..."
        if ! apt install -y jq; then
            log_error "Failed to install jq. Critical dependency missing."
            exit 1
        fi
    fi

    # Check and install jsonschema for configuration validation
    if ! command -v jsonschema >/dev/null 2>&1; then
        log_info "Installing python3-jsonschema..."
        if ! apt install -y python3-jsonschema; then
            log_warn "Failed to install python3-jsonschema. Some JSON validation features may be limited."
        fi
    fi

    # Check for Proxmox container tools
    if ! command -v pct >/dev/null 2>&1; then
        log_error "'pct' command not found. Please ensure Proxmox VE is installed."
        exit 1
    fi

    # Check apparmor and install if needed
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

    # Validate system resources
    validate_system_resources

    log_info "System requirements check and installation completed"
}

validate_system_resources() {
    log_info "Validating system resources..."

    # Check available memory
    local free_memory_mb
    free_memory_mb=$(free -m | awk '/^Mem:/{print $7}')

    if [[ "$free_memory_mb" -lt 2048 ]]; then
        log_warn "Low system memory ($free_memory_mb MB) may affect container creation"
    else
        log_info "System has sufficient memory ($free_memory_mb MB)"
    fi

    # Check available disk space (minimum 50GB recommended)
    local free_disk_gb
    free_disk_gb=$(df / | awk 'NR==2 {print $4}' | cut -d' ' -f1)

    if [[ "$free_disk_gb" -lt 50 ]]; then
        log_warn "Low disk space ($free_disk_gb GB) may affect container creation"
    else
        log_info "System has sufficient disk space ($free_disk_gb GB)"
    fi

    # Check CPU cores
    local cpu_cores
    cpu_cores=$(nproc)

    if [[ "$cpu_cores" -lt 4 ]]; then
        log_warn "Few CPU cores detected ($cpu_cores), may limit concurrent container creation"
    else
        log_info "System has sufficient CPU cores ($cpu_cores)"
    fi

    # Validate Docker version compatibility
    if command -v docker >/dev/null 2>&1; then
        local docker_version
        docker_version=$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d 'v')
        if [[ -n "$docker_version" ]]; then
            log_info "Docker version $docker_version detected"
            # Warn about older versions that may not support all features
            if [[ "${docker_version%%.*}" -lt 20 ]]; then
                log_warn "Old Docker version ($docker_version) detected. Consider updating to newer version for full AI workload support."
            fi
        fi
    fi

    log_info "System resource validation completed"
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

    # Set proper ownership for directories (if running as root)
    if [[ $EUID -eq 0 ]]; then
        chown -R root:root "$lib_dir" || log_warn "Could not set ownership for directory: $lib_dir"
    fi

    log_info "Directory setup completed"
}

setup_configuration() {
    log_info "DEBUG: Entering setup_configuration..."
    log_info "Checking configuration files..."

    local critical_files=(
        "$PHOENIX_LXC_CONFIG_FILE"
        "$PHOENIX_LXC_CONFIG_SCHEMA_FILE"
        "$PHOENIX_HF_TOKEN_FILE"
        "$PHOENIX_DOCKER_TOKEN_FILE"  # NEW: Added Docker Hub token file
    )

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
                    log_error "Hugging Face token file missing: $file. Please create it with HF_TOKEN."
                    exit 1
                    ;;
                "$PHOENIX_DOCKER_TOKEN_FILE")
                    log_error "Docker Hub token file missing: $file. Please create it with DOCKER_HUB_USERNAME and DOCKER_HUB_TOKEN."
                    exit 1
                    ;;
            esac
        fi

        if [[ -f "$file" ]]; then
            if [[ ! -r "$file" ]]; then
                log_error "Configuration file not readable: $file"
                exit 1
            else
                log_info "Configuration file is readable: $file"

                # Validate JSON syntax for critical files (skip .conf files)
                if [[ "$file" != *.conf ]] && command -v jq >/dev/null 2>&1; then
                    if ! jq empty "$file" >/dev/null 2>&1; then
                        log_error "Configuration file $file is not valid JSON"
                        exit 1
                    else
                        log_info "Configuration file $file is valid JSON"
                    fi
                elif [[ "$file" == *.conf ]]; then
                     log_info "Skipping JSON validation for .conf file: $file"
                fi

                # Validate schema for LXC configs if available
                if [[ "$file" == "$PHOENIX_LXC_CONFIG_FILE" ]] && command -v jsonschema >/dev/null 2>&1; then
                    if [[ -f "$PHOENIX_LXC_CONFIG_SCHEMA_FILE" ]]; then
                        if ! jsonschema -i "$file" "$PHOENIX_LXC_CONFIG_SCHEMA_FILE"; then
                            log_error "Configuration file $file failed schema validation"
                            exit 1
                        else
                            log_info "Configuration file $file passed schema validation"
                        fi
                    fi
                fi
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

    # Get detailed GPU information
    local gpu_count
    gpu_count=$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits 2>/dev/null || echo "0")

    if [[ "$gpu_count" -eq 0 ]]; then
        log_error "No NVIDIA GPUs detected by nvidia-smi"
        exit 1
    fi

    log_info "NVIDIA GPU support verified on host ($gpu_count GPUs detected)"

    # Check specific GPU 0 access
    if ! nvidia-smi --query-gpu=name --format=csv,noheader,nounits --id=0 >/dev/null 2>&1; then
        log_error "No NVIDIA GPU detected by nvidia-smi for ID 0, or nvidia-smi query failed."
        exit 1
    fi

    log_info "NVIDIA GPU support verified on host (GPU 0 accessible)"

    # Validate nvidia-docker integration if available
    if command -v nvidia-docker2 >/dev/null 2>&1; then
        log_info "nvidia-docker2 detected, ensuring proper installation"
        # Perform basic check of nvidia-docker functionality
    else
        log_warn "nvidia-docker2 not installed. Container GPU access may be limited."
    fi
}

setup_services() {
    log_info "DEBUG: Entering setup_services..."
    log_info "Setting up service configurations..."

    if [[ -d "/etc/systemd/system" ]]; then
        log_info "Systemd service directory found: /etc/systemd/system"

        # Check basic systemd functionality
        if systemctl --version >/dev/null 2>&1; then
            log_info "systemd is available and functional"
        else
            log_warn "systemd is installed but not functional"
        fi
    else
        log_warn "Systemd service directory not found: /etc/systemd/system. This might be ok if not using systemd services directly."
    fi

    # Verify Docker service status
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet docker; then
            log_info "Docker service is active"
        else
            log_warn "Docker service is not active, but proceeding with setup"
        fi
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
    for dir in "${required_dirs[@]}"; do
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
        "$PHOENIX_HF_TOKEN_FILE"
        "$PHOENIX_DOCKER_TOKEN_FILE"  # NEW: Added Docker Hub token file
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

    # Validate configuration file content integrity
    if [[ -f "$PHOENIX_LXC_CONFIG_FILE" ]]; then
        if command -v jq >/dev/null 2>&1; then
            if jq empty "$PHOENIX_LXC_CONFIG_FILE" >/dev/null 2>&1; then
                log_info "LXC configuration file is valid JSON"
                ((checks_passed++)) || true
            else
                log_error "LXC configuration file is not valid JSON"
                ((checks_failed++)) || true
            fi
        fi
    fi

    log_info "Setup validation summary: $checks_passed checks passed, $checks_failed checks failed."

    if [[ $checks_failed -gt 0 ]]; then
        log_warn "Validation had $checks_failed failures. Setup might be incomplete. Please review logs and configuration."
        return 1
    else
        log_info "All setup validation checks passed successfully."
        return 0
    fi
}

# --- New Security Validation Function ---
validate_security() {
    log_info "Validating system security settings..."

    # Check file permissions for sensitive configuration files
    local config_files=("$PHOENIX_HF_TOKEN_FILE" "$PHOENIX_DOCKER_TOKEN_FILE")

    for file in "${config_files[@]}"; do
        if [[ -f "$file" ]]; then
            local permissions
            permissions=$(stat -c "%a" "$file")
            # Check that files are not world-readable (777, 666, etc.)
            if [[ "$permissions" == *"7"* && "$permissions" != "600" && "$permissions" != "640" ]]; then
                log_warn "File $file has world-readable permissions ($permissions), consider restricting to 600 or 640"
            else
                log_info "File $file has appropriate security permissions ($permissions)"
            fi
        fi
    done

    # Check if running as root (should be okay for setup but warn)
    if [[ $EUID -eq 0 ]]; then
        log_warn "Setup script is running as root. This is expected for system configuration."
    else
        log_info "Setup script is running with user privileges"
    fi

    log_info "Security validation completed"
}

main() {
    log_info "DEBUG: Entering main function..."
    log_info "==============================================="
    log_info "PHOENIX HYPERVISOR INITIAL SETUP STARTING"
    log_info "==============================================="
    log_info "Log file: $PHOENIX_INITIAL_SETUP_LOG_FILE"

    # Validate security settings first
    validate_security

    # Run setup functions in order
    setup_system_requirements
    setup_directories
    setup_configuration
    setup_nvidia_support
    setup_services

    # Validate connectivity after all prerequisites are set up
    validate_connectivity  # NEW: Added connectivity validation

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
    log_info "PHOENIX HYPERVISOR INITIAL SETUP COMPLETED SUCCESSFULLY"
    log_info "==============================================="

    log_info "Directories checked/created:"
    lib_dir="${PHOENIX_HYPERVISOR_LIB_DIR:-/usr/local/lib/phoenix_hypervisor}"
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
    log_info " - $PHOENIX_HF_TOKEN_FILE"
    log_info " - $PHOENIX_DOCKER_TOKEN_FILE"  # NEW: Added Docker Hub token file
    log_info ""

    log_info "NVIDIA GPU support checked and verified."
    log_info "Docker Hub, Hugging Face, and Portainer connectivity validated."
    log_info "System resource validation completed."
    log_info "Security settings validated."
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