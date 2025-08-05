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

# Source common functions
source /usr/local/bin/phoenix_hypervisor_common.sh || { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $0: Failed to source phoenix_hypervisor_common.sh" >&2; exit 1; }
source /usr/local/bin/phoenix_hypervisor_config.sh || { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $0: Failed to source phoenix_hypervisor_config.sh" >&2; exit 1; }

# Check root privileges
echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Checking root privileges..." >&2
check_root
echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Root check passed." >&2

# Log start of script
log "INFO" "$0: Starting phoenix_hypervisor_initial_setup.sh"

# --- Validate required tools ---
check_required_tools() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Checking required tools..." >&2
    local required_tools=("jq" "pct" "pveversion" "zfs" "lspci")
    local missing_tools=()
    log "DEBUG" "$0: Checking required tools: ${required_tools[*]}"
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log "ERROR" "$0: Required tools missing: ${missing_tools[*]}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Required tools missing: ${missing_tools[*]}. Installing..." >&2
        if ! retry_command "apt-get update"; then
            log "ERROR" "$0: Failed to update package lists for tool installation"
            exit 1
        fi
        for tool in "${missing_tools[@]}"; do
            # lspci is in pciutils
            if [[ "$tool" == "lspci" ]]; then
                if ! retry_command "apt-get install -y pciutils"; then
                    log "ERROR" "$0: Failed to install pciutils for lspci"
                    exit 1
                fi
            else
                if ! retry_command "apt-get install -y $tool"; then
                    log "ERROR" "$0: Failed to install $tool"
                    exit 1
                fi
            fi
        done
    fi
    # Install check-jsonschema for JSON validation
    if ! command -v check-jsonschema &> /dev/null; then
        log "INFO" "$0: check-jsonschema not found, installing..."
        if ! retry_command "apt-get install -y python3-pip" || ! retry_command "pip3 install check-jsonschema"; then
            log "ERROR" "$0: Failed to install check-jsonschema"
            echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to install check-jsonschema." >&2
            exit 1
        fi
    fi
    log "INFO" "$0: All required tools (jq, pct, pveversion, zfs, lspci, check-jsonschema) are installed"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] All required tools are installed." >&2
}

# --- Validate Proxmox environment ---
validate_proxmox_environment() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Checking Proxmox version and kernel compatibility..." >&2
    log "INFO" "$0: Checking Proxmox version and kernel compatibility..."
    if ! pveversion --verbose | grep -q "pve-manager/8\."; then
        log "ERROR" "$0: Proxmox VE 8.x required (detected: $(pveversion))"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Proxmox VE 8.x required (detected: $(pveversion))." >&2
        exit 1
    fi
    local kernel_version
    kernel_version=$(uname -r)
    if [[ ! "$kernel_version" =~ ^[5-8]\. ]]; then
        log "ERROR" "$0: Kernel version 5.x-8.x required (detected: $kernel_version)"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Kernel version 5.x-8.x required (detected: $kernel_version)." >&2
        exit 1
    fi
    log "INFO" "$0: Proxmox version and kernel check passed"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Proxmox version and kernel check passed." >&2
}

# --- Validate NVIDIA GPUs ---
validate_nvidia_drivers() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Checking NVIDIA GPU presence..." >&2
    log "INFO" "$0: Checking NVIDIA GPU presence via lspci..."
    local gpu_output
    gpu_output=$(lspci -d 10de: 2>/dev/null) || { log "ERROR" "$0: Failed to run lspci"; echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to run lspci." >&2; exit 1; }
    if [[ -z "$gpu_output" ]]; then
        log "ERROR" "$0: No NVIDIA GPUs detected via lspci."
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] No NVIDIA GPUs detected via lspci." >&2
        exit 1
    fi
    log "DEBUG" "$0: lspci output: $gpu_output"
    local gpu_count
    gpu_count=$(echo "$gpu_output" | wc -l)
    log "INFO" "$0: Detected $gpu_count NVIDIA GPU(s)"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Detected $gpu_count NVIDIA GPU(s)." >&2
    # Validate GPU assignments if defined
    if [[ ${#PHOENIX_GPU_ASSIGNMENTS[@]} -gt 0 ]]; then
        for lxc_id in "${!PHOENIX_GPU_ASSIGNMENTS[@]}"; do
            local indices="${PHOENIX_GPU_ASSIGNMENTS[$lxc_id]}"
            # Attempt to detect GPU details for logging, but don't fail if nvidia-smi is unavailable
            if command -v nvidia-smi &> /dev/null; then
                if ! detect_gpu_details "$indices"; then
                    log "WARN" "$0: Failed to detect GPU details for indices: $indices (continuing without detailed GPU info)"
                else
                    log "INFO" "$0: GPU details detected for indices: $indices"
                fi
            else
                log "DEBUG" "$0: nvidia-smi not found, skipping detailed GPU detection"
            fi
            for index in $indices; do
                if [[ $index -ge $gpu_count ]]; then
                    log "ERROR" "$0: GPU index $index for LXC $lxc_id exceeds available GPUs ($gpu_count)"
                    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] GPU index $index for LXC $lxc_id exceeds available GPUs ($gpu_count)." >&2
                    exit 1
                fi
            done
        done
        log "INFO" "$0: GPU assignments validated successfully"
    else
        log "INFO" "$0: No GPU assignments defined in PHOENIX_GPU_ASSIGNMENTS"
    fi
    log "INFO" "$0: NVIDIA GPU validation completed successfully"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] NVIDIA GPU validation completed successfully." >&2
}

# --- Validate LXC template ---
validate_lxc_template() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Validating LXC template..." >&2
    log "INFO" "$0: Validating LXC template: $DEFAULT_LXC_TEMPLATE"
    if [[ ! -f "$DEFAULT_LXC_TEMPLATE" ]]; then
        log "ERROR" "$0: LXC template file not found: $DEFAULT_LXC_TEMPLATE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] LXC template file not found: $DEFAULT_LXC_TEMPLATE." >&2
        exit 1
    fi
    log "INFO" "$0: LXC template validated successfully"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] LXC template validated successfully." >&2
}

# --- Main execution ---
check_required_tools
validate_proxmox_environment

# Validate ZFS pool
echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Validating ZFS pool..." >&2
local zfs_pool_name_to_check="${PHOENIX_ZFS_LXC_POOL:-quickOS/lxc-disks}"
if ! validate_zfs_pool "$zfs_pool_name_to_check"; then
    log "ERROR" "$0: ZFS pool validation failed for $zfs_pool_name_to_check"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] ZFS pool validation failed for $zfs_pool_name_to_check." >&2
    exit 1
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] ZFS pool validation passed." >&2

# Validate NVIDIA GPUs and assignments
validate_nvidia_drivers

# Validate LXC template
validate_lxc_template

# Ensure the system is updated
echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Performing system update and upgrade..." >&2
log "INFO" "$0: Performing system update and upgrade..."
if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
    cp -r /var/lib/apt/lists /var/lib/apt/lists.bak || log "WARN" "$0: Failed to backup apt lists"
fi
if ! retry_command "apt-get update"; then
    if [[ "$ROLLBACK_ON_FAILURE" == "true" ]] && [[ -d /var/lib/apt/lists.bak ]]; then
        rm -rf /var/lib/apt/lists && mv /var/lib/apt/lists.bak /var/lib/apt/lists
        log "INFO" "$0: Restored apt lists due to update failure"
    fi
    log "ERROR" "$0: Failed to update package lists"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to update package lists." >&2
    exit 1
fi
if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
    rm -rf /var/lib/apt/lists.bak
    log "DEBUG" "$0: Cleaned up apt lists backup"
fi
if ! retry_command "apt-get dist-upgrade -y"; then
    log "ERROR" "$0: Failed to upgrade system"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to upgrade system." >&2
    exit 1
fi
log "INFO" "$0: System update and upgrade completed"
echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] System update and upgrade completed." >&2

# Refresh Proxmox boot tool if needed
if command -v proxmox-boot-tool >/dev/null 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Refreshing proxmox-boot-tool..." >&2
    log "DEBUG" "$0: Refreshing proxmox-boot-tool"
    if ! retry_command "proxmox-boot-tool refresh"; then
        if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
            log "WARN" "$0: Failed to refresh proxmox-boot-tool (rollback not applicable)"
        fi
        log "WARN" "$0: Failed to refresh proxmox-boot-tool (might not be critical)"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] Failed to refresh proxmox-boot-tool (might not be critical)." >&2
    fi
fi

# Update initramfs
echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Updating initramfs..." >&2
log "DEBUG" "$0: Updating initramfs"
if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
    cp -r /boot/initrd.img-$(uname -r) /boot/initrd.img-$(uname -r).bak || log "WARN" "$0: Failed to backup initramfs"
fi
if ! retry_command "update-initramfs -u"; then
    if [[ "$ROLLBACK_ON_FAILURE" == "true" ]] && [[ -f /boot/initrd.img-$(uname -r).bak ]]; then
        mv /boot/initrd.img-$(uname -r).bak /boot/initrd.img-$(uname -r)
        log "INFO" "$0: Restored initramfs due to update failure"
    fi
    log "ERROR" "$0: Failed to update initramfs"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to update initramfs." >&2
    exit 1
fi
if [[ "$ROLLBACK_ON_FAILURE" == "true" ]]; then
    rm -f /boot/initrd.img-$(uname -r).bak
    log "DEBUG" "$0: Cleaned up initramfs backup"
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] initramfs updated." >&2

# Install/Update LXC Tools
echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Installing/Updating LXC tools..." >&2
log "INFO" "$0: Installing/Updating LXC tools..."
if ! retry_command "apt-get install -y lxc-pve"; then
    log "ERROR" "$0: Failed to install/update LXC tools"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to install/update LXC tools." >&2
    exit 1
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] LXC tools installed/updated." >&2

# Mark the script as completed
echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Marking initial setup as complete..." >&2
mark_script_completed "$PHOENIX_HYPERVISOR_COMPLETED_MARKER"
log "INFO" "$0: Completed phoenix_hypervisor_initial_setup.sh successfully"
echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Phoenix Hypervisor initial setup completed successfully." >&2
exit 0