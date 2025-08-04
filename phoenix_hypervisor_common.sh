#!/bin/bash
# Phoenix Hypervisor Common Functions
# Provides reusable functions for logging, error handling, script execution, and LXC management.
# Version: 1.6.5 (Merged features for standardized GPU passthrough and full functionality)
# Author: Assistant

set -euo pipefail

# --- Check for root privileges ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "This script must be run as root."
        exit 1
    fi
}

# --- Logging Function ---
setup_logging() {
    local log_dir=$(dirname "$LOGFILE")
    mkdir -p "$log_dir" || { log "ERROR" "Failed to create log directory: $log_dir"; exit 1; }
    touch "$LOGFILE" || { log "ERROR" "Failed to create or access log file: $LOGFILE"; exit 1; }
    exec 1>>"$LOGFILE" 2>&1
    log "INFO" "Logging initialized for $0"
}

log() {
    local level="$1"
    shift
    local message="$*"
    if [[ -z "$LOGFILE" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] LOGFILE variable not set" >&2
        exit 1
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [$level] $message" | tee -a "$LOGFILE"
}

# --- Retry a command ---
retry_command() {
    local command="$1"
    local retries="${2:-3}"
    local delay="${3:-5}"
    local attempt=0

    until [[ $attempt -ge $retries ]]; do
        attempt=$((attempt + 1))
        log "INFO" "Executing (attempt $attempt/$retries): $command"
        if eval "$command"; then
            log "INFO" "Command succeeded: $command"
            return 0
        else
            local exit_code=$?
            log "WARN" "Command failed (attempt $attempt/$retries, exit code: $exit_code): $command"
            if [[ $attempt -lt $retries ]]; then
                log "INFO" "Waiting $delay seconds before retrying..."
                sleep "$delay"
            fi
        fi
    done
    log "ERROR" "Command failed after $retries attempts: $command"
    return $exit_code
}

# --- Execute command in LXC ---
execute_in_lxc() {
    local lxc_id="$1"
    local command="$2"
    if [[ -z "$lxc_id" ]] || [[ -z "$command" ]]; then
        log "ERROR" "execute_in_lxc requires lxc_id and command arguments"
        return 1
    fi
    log "DEBUG" "Executing in LXC $lxc_id: $command"
    pct exec "$lxc_id" -- bash -c "$command"
    local exit_code=$?
    log "DEBUG" "Command in LXC $lxc_id exited with code: $exit_code"
    return $exit_code
}

# --- Check if a script has already been completed ---
is_script_completed() {
    local marker_file="$1"
    if [[ -f "$marker_file" ]]; then
        return 0
    else
        return 1
    fi
}

# --- Mark a script as completed ---
mark_script_completed() {
    local marker_file="$1"
    local marker_dir=$(dirname "$marker_file")
    mkdir -p "$marker_dir"
    touch "$marker_file"
    log "INFO" "Marked script completed: $marker_file"
}

# --- Load hypervisor configuration ---
load_hypervisor_config() {
    source /usr/local/bin/phoenix_hypervisor_config.sh || { log "ERROR" "Failed to source phoenix_hypervisor_config.sh"; exit 1; }
}

# --- Wait for LXC container to be running ---
wait_for_lxc_running() {
    local lxc_id="$1"
    local max_attempts=30
    local attempt=1

    log "INFO" "Ensuring LXC $lxc_id is running..."
    while [[ $attempt -le $max_attempts ]]; do
        if pct status "$lxc_id" | grep -q "status: running"; then
            log "INFO" "LXC $lxc_id is running."
            return 0
        fi
        log "DEBUG" "LXC $lxc_id not running yet (attempt $attempt/$max_attempts). Waiting 2 seconds..."
        sleep 2
        ((attempt++))
    done
    log "ERROR" "LXC $lxc_id failed to start after $max_attempts attempts."
    return 1
}

# --- Wait for networking to be available in LXC ---
wait_for_lxc_network() {
    local lxc_id="$1"
    local max_attempts=30
    local attempt=1

    log "INFO" "Ensuring networking is available in LXC $lxc_id..."
    while [[ $attempt -le $max_attempts ]]; do
        if execute_in_lxc "$lxc_id" "ping -c 1 8.8.8.8" >/dev/null 2>&1; then
            log "INFO" "Networking is ready in LXC $lxc_id."
            return 0
        fi
        log "DEBUG" "Networking not ready in LXC $lxc_id (attempt $attempt/$max_attempts). Waiting 2 seconds..."
        sleep 2
        ((attempt++))
    done
    log "ERROR" "Networking failed to become available in LXC $lxc_id after $max_attempts attempts."
    return 1
}

# --- Get GPU device details for passthrough ---
detect_gpu_details() {
    local gpu_indices="$1"
    declare -gA GPU_DETAILS
    declare -g GPU_MAJOR_NUMBERS=""
    local major_numbers=()

    log "INFO" "Detecting GPU details for indices: $gpu_indices"

    if [[ -z "$gpu_indices" ]]; then
        log "INFO" "No GPU indices provided. Skipping GPU detection."
        return 0
    fi

    if ! command -v nvidia-smi >/dev/null 2>&1; then
        log "ERROR" "nvidia-smi not found. Cannot detect GPUs."
        return 0
    fi

    local all_gpu_info
    all_gpu_info=$(nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader,nounits 2>/dev/null)
    if [[ $? -ne 0 ]] || [[ -z "$all_gpu_info" ]]; then
        log "ERROR" "Failed to query NVIDIA GPU information with nvidia-smi."
        return 0
    fi

    for index in $gpu_indices; do
        if ! [[ "$index" =~ ^[0-9]+$ ]]; then
            log "ERROR" "Invalid GPU index format: '$index'. Skipping."
            continue
        fi

        local gpu_line
        gpu_line=$(echo "$all_gpu_info" | grep "^$index,")
        if [[ -z "$gpu_line" ]]; then
            log "WARN" "GPU index $index not found by nvidia-smi. Skipping."
            continue
        fi

        local pci_bus_id_full
        pci_bus_id_full=$(echo "$gpu_line" | cut -d',' -f2)
        local pci_bus_id
        pci_bus_id=$(echo "$pci_bus_id_full" | sed 's/^00000000:/0000:/')

        log "DEBUG" "Found GPU $index with PCI Bus ID: $pci_bus_id"

        local device_files=("/dev/nvidia${index}" "/dev/nvidia-ctl" "/dev/nvidia-modeset" "/dev/nvidia-uvm" "/dev/nvidia-uvm-tools" "/dev/nvidia-caps/nvidia-cap1" "/dev/nvidia-caps/nvidia-cap2")
        device_files+=("/dev/dri/card${index}" "/dev/dri/renderD$((128 + index))")

        local existing_device_files=()
        for device in "${device_files[@]}"; do
            if [[ -e "$device" ]]; then
                existing_device_files+=("$device")
                local major
                major=$(stat -c %t "$device" 2>/dev/null)
                if [[ -n "$major" ]]; then
                    local dec_major
                    dec_major=$((16#$major))
                    if [[ ! " ${major_numbers[*]} " =~ " ${dec_major} " ]]; then
                        major_numbers+=("$dec_major")
                    fi
                fi
            else
                log "DEBUG" "Device file $device for GPU $index does not exist, skipping."
            fi
        done

        if [[ ${#existing_device_files[@]} -gt 0 ]]; then
            GPU_DETAILS["$index"]="$pci_bus_id,$(IFS=','; echo "${existing_device_files[*]}")"
            log "INFO" "Detected GPU $index (PCI: $pci_bus_id) with devices: $(IFS=','; echo "${existing_device_files[*]}")"
        else
            log "WARN" "No device files found for GPU $index (PCI: $pci_bus_id)."
            GPU_DETAILS["$index"]="$pci_bus_id,"
        fi
    done

    GPU_MAJOR_NUMBERS=$(IFS=','; echo "${major_numbers[*]}")
    log "INFO" "Detected GPU major device numbers for cgroup rules: $GPU_MAJOR_NUMBERS"
    return 0
}

# --- Configure GPU passthrough for LXC ---
configure_lxc_gpu_passthrough() {
    local lxc_id="$1"
    local gpu_indices="$2"
    local config_file="/etc/pve/lxc/$lxc_id.conf"
    local marker_file="${HYPERVISOR_MARKER_DIR}/lxc_${lxc_id}_gpu_configured.marker"

    if is_script_completed "$marker_file"; then
        log "INFO" "GPU passthrough for LXC $lxc_id already configured. Skipping."
        return 0
    fi

    if [[ -z "$lxc_id" ]] || [[ -z "$gpu_indices" ]]; then
        log "INFO" "No LXC ID or GPU indices provided for $lxc_id. Skipping GPU passthrough."
        mark_script_completed "$marker_file"
        return 0
    fi

    if [[ ! -f "$config_file" ]]; then
        log "ERROR" "LXC config file not found: $config_file"
        return 0
    fi

    log "INFO" "Configuring GPU passthrough for LXC $lxc_id using indices: '$gpu_indices'"

    if ! detect_gpu_details "$gpu_indices"; then
        log "WARN" "GPU detection failed for LXC $lxc_id. Skipping GPU passthrough."
        mark_script_completed "$marker_file"
        return 0
    fi

    if [[ ${#GPU_DETAILS[@]} -eq 0 ]]; then
        log "INFO" "No valid GPU details detected for LXC $lxc_id. Skipping GPU passthrough."
        mark_script_completed "$marker_file"
        return 0
    fi

    local tmpfile
    tmpfile=$(mktemp) || { log "ERROR" "Failed to create temporary file for LXC config"; return 0; }
    grep -v -E "^(lxc\.cgroup2\.devices\.allow.*c (195|510|226):|lxc\.mount\.entry.*(nvidia|dri))" "$config_file" > "$tmpfile"

    if [[ -n "$GPU_MAJOR_NUMBERS" ]]; then
        IFS=',' read -ra major_nums <<< "$GPU_MAJOR_NUMBERS"
        for major in "${major_nums[@]}"; do
            echo "lxc.cgroup2.devices.allow: c $major:* rwm" >> "$tmpfile"
            log "INFO" "Added cgroup rule for major $major to $config_file"
        done
    else
        log "WARN" "No GPU major numbers detected. Adding NVIDIA defaults (195, 510)."
        echo "lxc.cgroup2.devices.allow: c 195:* rwm" >> "$tmpfile"
        echo "lxc.cgroup2.devices.allow: c 510:* rwm" >> "$tmpfile"
    fi

    local device_files=("/dev/nvidia0" "/dev/nvidia1" "/dev/nvidia-ctl" "/dev/nvidia-modeset" "/dev/nvidia-uvm" "/dev/nvidia-uvm-tools" "/dev/nvidia-caps/nvidia-cap1" "/dev/nvidia-caps/nvidia-cap2")
    device_files+=("/dev/dri/card0" "/dev/dri/card1" "/dev/dri/renderD128" "/dev/dri/renderD129")

    for dev in "${device_files[@]}"; do
        if [[ -e "$dev" ]] && ! grep -q "lxc.mount.entry: $dev" "$config_file"; then
            echo "lxc.mount.entry: $dev ${dev#/dev/} none bind,optional,create=file" >> "$tmpfile"
            log "INFO" "Added mount entry for $dev to $config_file"
        fi
    done

    mv "$tmpfile" "$config_file"
    log "INFO" "GPU passthrough configured for LXC $lxc_id."
    mark_script_completed "$marker_file"
}