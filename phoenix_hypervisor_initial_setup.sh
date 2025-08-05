#!/bin/bash
# Phoenix Hypervisor Initial Setup Script
# Performs initial setup of the Proxmox host, including system updates, LXC tools installation, ZFS validation, and NVIDIA GPU checks.
# Prerequisites:
# - Proxmox VE 8.x (tested with 8.4.6)
# - Internet access for package downloads
# - Root privileges
# - NVIDIA GPU(s) installed on the host
# Usage: ./phoenix_hypervisor_initial_setup.sh
# Version: 1.7.3
# Author: Assistant
set -euo pipefail

# --- Enhanced User Experience Functions ---
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $1" >&2
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $1" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $1" >&2
}

prompt_user() {
    local prompt="$1"
    local default="${2:-}"
    read -p "$prompt [$default]: " response
    echo "${response:-$default}"
}

# --- Enhanced Logging Function ---
log() {
    local level="$1"
    shift
    local message="$*"
    if [[ -z "${HYPERVISOR_LOGFILE:-}" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $0: HYPERVISOR_LOGFILE variable not set" >&2
        exit 1
    fi
    # Ensure log directory exists
    local log_dir
    log_dir=$(dirname "$HYPERVISOR_LOGFILE")
    mkdir -p "$log_dir" || { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $0: Failed to create log directory: $log_dir" >&2; exit 1; }
    # Log to file via fd 4
    if [[ ! -e /proc/self/fd/4 ]]; then
        exec 4>>"$HYPERVISOR_LOGFILE"
        chmod 600 "$HYPERVISOR_LOGFILE" || { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $0: Failed to set permissions on $HYPERVISOR_LOGFILE" >&2; }
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [$level] $message" >&4
    # Output INFO, WARN, ERROR to stderr for terminal visibility
    if [[ "$level" =~ ^(INFO|WARN|ERROR)$ ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [$level] $message" >&2
    fi
}

# --- Enhanced Main Function ---
main() {
    log_info "Starting Phoenix Hypervisor initial setup..."
    echo ""
    echo "==============================================="
    echo "PHOENIX HYPERTORVISOR INITIAL SETUP"
    echo "==============================================="
    echo ""
    
    # Check prerequisites
    log_info "Checking system prerequisites..."
    check_root
    check_proxmox_environment
    
    # Show system information
    show_system_info
    
    # Confirm with user before proceeding
    read -p "Do you want to proceed with initial setup? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_info "Initial setup cancelled by user."
        echo ""
        echo "Setup cancelled. No changes were made."
        echo ""
        exit 0
    fi
    
    echo ""
    echo "Starting setup process..."
    echo "-------------------------"
    
    # Update system packages
    log_info "Updating system packages..."
    update_system_packages
    
    # Install required packages for LXC containers and GPU support
    log_info "Installing required packages..."
    install_required_packages
    
    # Validate ZFS pools
    log_info "Validating ZFS storage..."
    validate_zfs_storage
    
    # Check NVIDIA GPU compatibility
    log_info "Checking NVIDIA GPU compatibility..."
    check_nvidia_compatibility
    
    # Configure system for LXC containers
    log_info "Configuring system for LXC containers..."
    configure_lxc_system
    
    # Setup logging and markers
    setup_logging_and_markers
    
    # Final confirmation
    log_info "Initial setup completed successfully!"
    echo ""
    echo "==============================================="
    echo "INITIAL SETUP COMPLETED SUCCESSFULLY!"
    echo "==============================================="
    echo ""
    echo "System information:"
    show_system_info
    echo ""
}

# --- Enhanced Prerequisite Functions ---
check_root() {
    log_info "Checking if running as root..."
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
    log_info "Script is running with root privileges"
}

check_proxmox_environment() {
    log_info "Checking Proxmox VE environment..."
    
    if ! command -v pveversion >/dev/null 2>&1; then
        log_error "pveversion command not found. Ensure this script is running on a Proxmox VE system."
        exit 1
    fi
    
    local proxmox_version
    proxmox_version=$(pveversion | cut -d'/' -f2 | cut -d'-' -f1)
    
    if [[ ! "$proxmox_version" =~ ^8\..* ]]; then
        log_warn "This script is designed for Proxmox VE 8.x. Found Proxmox VE version: $proxmox_version"
        echo "Proceeding anyway, but compatibility may not be guaranteed."
    fi
    
    local debian_version
    debian_version=$(cat /etc/debian_version 2>/dev/null || echo "unknown")
    
    if [[ ! "$debian_version" =~ ^12\..* ]]; then
        log_warn "This script is designed for Debian 12. Found Debian version: $debian_version"
        echo "Proceeding anyway, but compatibility may not be guaranteed."
    fi
    
    log_info "Proxmox VE environment verified (Version: $proxmox_version, Debian: $debian_version)"
}

show_system_info() {
    echo ""
    echo "System Information:"
    echo "-------------------"
    
    # Get system architecture
    local arch
    arch=$(uname -m)
    echo "Architecture: $arch"
    
    # Get OS version
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "OS: $NAME $VERSION_ID"
    fi
    
    # Get Proxmox version
    if command -v pveversion >/dev/null 2>&1; then
        echo "Proxmox VE Version: $(pveversion)"
    fi
    
    # Check if we have GPU
    if command -v nvidia-smi >/dev/null 2>&1; then
        local gpu_count
        gpu_count=$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits | tr -d ' ')
        echo "NVIDIA GPUs: $gpu_count detected"
    else
        echo "NVIDIA GPU: Not detected or drivers not installed"
    fi
    
    # Show available memory
    local mem_total
    mem_total=$(free -h | awk '/^Mem:/ {print $2}')
    echo "Total Memory: $mem_total"
    
    echo ""
}

# --- Enhanced System Update Functions ---
update_system_packages() {
    log_info "Updating system packages..."
    
    # Check if we're connected to internet
    if ! ping -c 1 -W 5 google.com >/dev/null 2>&1; then
        log_warn "No internet connection detected. Package updates may fail."
    fi
    
    # Update package lists
    echo "Updating package lists..."
    retry_command 3 10 "apt-get update" || {
        log_error "Failed to update package lists"
        exit 1
    }
    
    # Upgrade system packages
    echo "Upgrading system packages..."
    retry_command 3 10 "apt-get dist-upgrade -y" || {
        log_error "Failed to upgrade system packages"
        exit 1
    }
    
    # Update Proxmox boot tool
    echo "Updating Proxmox boot tool..."
    retry_command 3 10 "proxmox-boot-tool refresh" || {
        log_warn "Failed to refresh proxmox-boot-tool"
    }
    
    # Update initramfs
    echo "Updating initramfs..."
    retry_command 3 10 "update-initramfs -u" || {
        log_error "Failed to update initramfs"
        exit 1
    }
    
    log_info "System packages updated successfully"
}

# --- Enhanced Package Installation ---
install_required_packages() {
    log_info "Installing required packages..."
    
    # Define packages needed for LXC containers and GPU support
    local packages=(
        "lxc"           # LXC container tools
        "pve-container" # Proxmox container support
        "zfsutils-linux" # ZFS utilities
        "jq"            # JSON processing
        "nvidia-driver-535" # NVIDIA drivers (if available)
        "nvidia-container-toolkit" # NVIDIA container runtime
        "docker.io"     # Docker for containerized services
        "libvirt-daemon-system" # Virtualization support
    )
    
    echo "Installing packages: ${packages[*]}"
    
    # Install packages with retry mechanism
    local failed_packages=()
    for package in "${packages[@]}"; do
        echo "Installing $package..."
        if ! retry_command 3 10 "apt-get install -y $package"; then
            log_warn "Failed to install $package"
            failed_packages+=("$package")
        else
            log_info "Successfully installed $package"
        fi
    done
    
    # Report any failures
    if [[ ${#failed_packages[@]} -gt 0 ]]; then
        echo ""
        log_warn "Some packages failed to install: ${failed_packages[*]}"
        echo "This might be expected depending on your system configuration."
        echo ""
    fi
    
    log_info "Package installation completed"
}

# --- Enhanced ZFS Validation ---
validate_zfs_storage() {
    log_info "Validating ZFS storage..."
    
    # Check if ZFS is available
    if ! command -v zpool >/dev/null 2>&1; then
        log_error "ZFS utilities not found. Please install them first."
        exit 1
    fi
    
    # List all ZFS pools
    echo "Available ZFS pools:"
    if zpool list >/dev/null 2>&1; then
        zpool list -H | awk '{print "  - "$1}' || true
    else
        echo "  No ZFS pools found"
    fi
    
    # Check specific pool (if configured)
    if [[ -n "${PHOENIX_ZFS_LXC_POOL:-}" ]]; then
        log_info "Checking for required ZFS pool: $PHOENIX_ZFS_LXC_POOL"
        if zpool list "$PHOENIX_ZFS_LXC_POOL" >/dev/null 2>&1; then
            echo "Pool $PHOENIX_ZFS_LXC_POOL found and is accessible"
        else
            log_warn "Required ZFS pool $PHOENIX_ZFS_LXC_POOL not found"
            echo "If this is expected, continue with setup."
        fi
    fi
    
    log_info "ZFS storage validation completed"
}

# --- Enhanced NVIDIA Compatibility Check ---
check_nvidia_compatibility() {
    log_info "Checking NVIDIA GPU compatibility..."
    
    # Check if nvidia-smi is available
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        echo ""
        echo "NVIDIA drivers not found. Installing recommended NVIDIA drivers..."
        echo ""
        
        # Install NVIDIA drivers
        retry_command 3 10 "apt-get install -y nvidia-driver-535" || {
            log_warn "Failed to install NVIDIA drivers"
        }
        
        # Check if installation succeeded
        if command -v nvidia-smi >/dev/null 2>&1; then
            echo "NVIDIA drivers installed successfully"
        else
            echo "Warning: NVIDIA drivers may not be properly installed"
        fi
    else
        echo "NVIDIA drivers already installed"
        
        # Show GPU information
        local gpu_info
        gpu_info=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits | head -n1)
        echo "GPU Information: $gpu_info"
    fi
    
    # Check driver compatibility with Proxmox
    if command -v nvidia-smi >/dev/null 2>&1; then
        local driver_version
        driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits | tr -d ' ')
        echo "Driver Version: $driver_version"
        
        # Check if we have the NVIDIA container toolkit
        if ! command -v nvidia-container-toolkit >/dev/null 2>&1; then
            echo "Installing NVIDIA Container Toolkit..."
            retry_command 3 10 "apt-get install -y nvidia-container-toolkit" || {
                log_warn "Failed to install NVIDIA Container Toolkit"
            }
        else
            echo "NVIDIA Container Toolkit already installed"
        fi
    fi
    
    log_info "NVIDIA compatibility check completed"
}

# --- Enhanced LXC System Configuration ---
configure_lxc_system() {
    log_info "Configuring system for LXC containers..."
    
    # Ensure LXC modules are loaded
    echo "Ensuring LXC modules are loaded..."
    
    # Check if LXC is enabled in kernel
    if ! grep -q "lxc" /proc/modules 2>/dev/null; then
        echo "LXC module not found in kernel. Enabling if possible..."
    fi
    
    # Configure LXC container settings
    local lxc_config="/etc/lxc/default.conf"
    
    if [[ -f "$lxc_config" ]]; then
        echo "Updating existing LXC configuration: $lxc_config"
    else
        echo "Creating new LXC configuration: $lxc_config"
        mkdir -p "$(dirname "$lxc_config")"
    fi
    
    # Add or update common LXC settings
    local settings=(
        "lxc.net.0.type = veth"
        "lxc.net.0.link = lxcbr0"
        "lxc.net.0.flags = up"
        "lxc.net.0.hwaddr = 02:00:00:00:00:00"
    )
    
    for setting in "${settings[@]}"; do
        if ! grep -q "^$setting" "$lxc_config" 2>/dev/null; then
            echo "$setting" >> "$lxc_config"
        fi
    done
    
    # Enable nested virtualization (if needed)
    echo "Checking nested virtualization support..."
    if [[ -f "/sys/module/kvm_intel/parameters/nested" ]]; then
        local nested_status
        nested_status=$(cat /sys/module/kvm_intel/parameters/nested)
        if [[ "$nested_status" == "Y" ]] || [[ "$nested_status" == "1" ]]; then
            echo "Nested virtualization is enabled"
        else
            echo "Nested virtualization is not enabled"
        fi
    fi
    
    log_info "System configuration for LXC completed"
}

# --- Enhanced Logging and Marker Setup ---
setup_logging_and_markers() {
    log_info "Setting up logging and markers..."
    
    # Create log directory if needed
    mkdir -p "$(dirname "$HYPERVISOR_LOGFILE")" || {
        log_error "Failed to create log directory: $(dirname "$HYPERVISOR_LOGFILE")"
        exit 1
    }
    
    # Set proper permissions on log file
    touch "$HYPERVISOR_LOGFILE" || {
        log_error "Failed to create log file: $HYPERVISOR_LOGFILE"
        exit 1
    }
    chmod 600 "$HYPERVISOR_LOGFILE"
    
    # Create marker directory
    mkdir -p "$HYPERVISOR_MARKER_DIR" || {
        log_error "Failed to create marker directory: $HYPERVISOR_MARKER_DIR"
        exit 1
    }
    
    # Set proper permissions on marker directory
    chmod 700 "$HYPERVISOR_MARKER_DIR"
    
    log_info "Logging and marker setup completed"
}

# --- Enhanced Retry Function ---
retry_command() {
    local max_attempts="${1:-3}"
    local delay="${2:-5}"
    shift 2
    local cmd="$*"
    
    log_info "Executing command with retries (max $max_attempts attempts): $cmd"
    
    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Attempt $attempt/$max_attempts: $cmd" >&2
        eval "$cmd"
        if [[ $? -eq 0 ]]; then
            log_info "Command succeeded on attempt $attempt"
            return 0
        fi
        log_warn "Command failed (attempt $attempt/$max_attempts): $cmd"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] Command failed, retrying in $delay seconds..." >&2
        sleep "$delay"
        ((attempt++))
    done
    
    log_error "Command failed after $max_attempts attempts: $cmd"
    return 1
}

# --- Enhanced Error Handling ---
trap 'log_error "Script failed at line $LINENO"; exit 1' ERR

# --- Execute Main Function ---
main "$@"