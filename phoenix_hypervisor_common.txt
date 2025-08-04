```bash
#!/bin/bash
# Phoenix Hypervisor Common Functions
# Provides reusable functions for logging, error handling, script execution, LXC management, and Hugging Face token handling.
# Version: 1.6.8 (Added Hugging Face token prompt, enhanced GPU debugging, JSON validation)
# Author: Assistant

set -euo pipefail

# --- Check for root privileges ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "$0: This script must be run as root."
        exit 1
    fi
}

# --- Logging Function ---
setup_logging() {
    local log_dir=$(dirname "$LOGFILE")
    mkdir -p "$log_dir" || { log "ERROR" "$0: Failed to create log directory: $log_dir"; exit 1; }
    touch "$LOGFILE" || { log "ERROR" "$0: Failed to create or access log file: $LOGFILE"; exit 1; }
    exec 1>>"$LOGFILE" 2>&1
    log "INFO" "Logging initialized for $0"
}

log() {
    local level="$1"
    shift
    local message="$*"
    if [[ -z "$LOGFILE" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $0: LOGFILE variable not set" >&2
        exit 1
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [$level] $message" | tee -a "$LOGFILE"
}

# --- Validate ZFS pool ---
validate_zfs_pool() {
    local pool_name="$1"
    log "DEBUG" "$0: Validating ZFS pool: $pool_name"
    if ! zfs list "$pool_name" >/dev/null 2>&1; then
        log "ERROR" "$0: ZFS dataset $pool_name does not exist"
        zpool list | while read -r line; do log "DEBUG" "$0: zpool: $line"; done
        return 1
    fi
    if ! zfs get -H -o value mounted "$pool_name" | grep -q "yes"; then
        log "INFO" "$0: ZFS dataset $pool_name not mounted, attempting to mount"
        zfs mount "$pool_name" || { log "ERROR" "$0: Failed to mount $pool_name"; return 1; }
    fi
    log "INFO" "$0: ZFS pool $pool_name is available and mounted"
    return 0
}

# --- Validate JSON config file ---
validate_json_config() {
    local config_file="$1"
    log "DEBUG" "$0: Validating JSON config file: $config_file"
    if [[ ! -f "$config_file" ]]; then
        log "ERROR" "$0: JSON config file not found: $config_file"
        return 1
    fi
    if ! jq . "$config_file" >/dev/null 2>&1; then
        log "ERROR" "$0: JSON config file is invalid or unreadable: $config_file"
        return 1
    fi
    log "INFO" "$0: JSON config file validated: $config_file"
    return 0
}

# --- Prompt for Hugging Face token ---
prompt_for_hf_token() {
    local token_file="/usr/local/etc/phoenix_hf_token.conf"
    local token_input
    local token_confirm
    local attempts=0
    local max_attempts=3

    log "DEBUG" "$0: Checking for HUGGING_FACE_HUB_TOKEN"
    if [[ -n "${HUGGING_FACE_HUB_TOKEN:-}" ]]; then
        log "INFO" "$0: HUGGING_FACE_HUB_TOKEN found in environment"
        return 0
    fi

    if [[ -f "$token_file" ]]; then
        log "DEBUG" "$0: Loading HUGGING_FACE_HUB_TOKEN from $token_file"
        HUGGING_FACE_HUB_TOKEN=$(cat "$token_file" | base64 -d 2>/dev/null)
        if [[ -n "$HUGGING_FACE_HUB_TOKEN" ]]; then
            export HUGGING_FACE_HUB_TOKEN
            log "INFO" "$0: HUGGING_FACE_HUB_TOKEN loaded from $token_file"
            return 0
        fi
    fi

    log "INFO" "$0: HUGGING_FACE_HUB_TOKEN not found. Prompting user..."
    while [[ $attempts -lt $max_attempts ]]; do
        read -s -p "Enter Hugging Face Hub token: " token_input
        echo # Newline
        if [[ -z "$token_input" ]]; then
            ((attempts++))
            log "WARN" "$0: Token cannot be empty. Attempt $attempts/$max_attempts."
            continue
        fi

        read -s -p "Confirm token: " token_confirm
        echo # Newline
        if [[ "$token_input" != "$token_confirm" ]]; then
            ((attempts++))
            log "WARN" "$0: Tokens do not match. Attempt $attempts/$max_attempts."
            continue
        fi

        log "INFO" "$0: Token confirmed"
        export HUGGING_FACE_HUB_TOKEN="$token_input"
        mkdir -p "$(dirname "$token_file")"
        echo -n "$token_input" | base64 > "$token_file" || { log "ERROR" "$0: Failed to save token to $token_file"; exit 1; }
        chmod 600 "$token_file" || { log "WARN" "$0: Failed to set permissions on $token_file"; }
        log "INFO" "$0: HUGGING_FACE_HUB_TOKEN saved to $token_file"
        return 0
    done

    log "ERROR" "$0: Maximum token attempts ($max_attempts) reached"
    exit 1
}

# --- Retry a command ---
retry_command() {
    local command="$1"
    local retries="${2:-3}"
    local delay="${3:-5}"
    local attempt=0
    local output

    until [[ $attempt -ge $retries ]]; do
        attempt=$((attempt + 1))
        log "INFO" "$0: Executing (attempt $attempt/$retries): $command"
        if output=$(eval "$command" 2>&1); then
            log "INFO" "$0: Command succeeded: $command"
            return 0
        else
            local exit_code=$?
            log "WARN" "$0: Command failed (attempt $attempt/$retries, exit code: $exit_code): $command"
            log "DEBUG" "$0: Command output: $output"
            if [[ $attempt -lt $retries ]]; then
                log "INFO" "$0: Waiting $delay seconds before retrying..."
                sleep "$delay"
            fi
        fi
    done
    log "ERROR" "$0: Command failed after $retries attempts: $command"
    return $exit_code
}

# --- Execute command in LXC ---
execute_in_lxc() {
    local lxc_id="$1"
    local command="$2"
    local output
    if [[ -z "$lxc_id" ]] || [[ -z "$command" ]]; then
        log "ERROR" "$0: execute_in_lxc requires lxc_id and command arguments"
        return 1
    fi
    log "DEBUG" "$0: Executing in LXC $lxc_id: $command"
    if output=$(pct exec "$lxc_id" -- bash -c "$command" 2>&1); then
        log "DEBUG" "$0: Command in LXC $lxc_id succeeded: $command"
        echo "$output"
        return 0
    else
        local exit_code=$?
        log "ERROR" "$0: Command in LXC $lxc_id failed (exit code: $exit_code): $command"
        log "DEBUG" "$0: Command output: $output"
        return $exit_code
    fi
}

# --- Check if a script has already been completed ---
is_script_completed() {
    local marker_file="$1"
    if [[ -f "$marker_file" ]]; then
        log "DEBUG" "$0: Marker file found: $marker_file"
        return 0
    else
        log "DEBUG" "$0: Marker file not found: $marker_file"
        return 1
    fi
}

# --- Mark a script as completed ---
mark_script_completed() {
    local marker_file="$1"
    local marker_dir=$(dirname "$marker_file")
    mkdir -p "$marker_dir" || { log "ERROR" "$0: Failed to create marker directory: $marker_dir"; exit 1; }
    touch "$marker_file" || { log "ERROR" "$0: Failed to create marker file: $marker_file"; exit 1; }
    log "INFO" "$0: Marked script completed: $marker_file"
}

# --- Wait for LXC container to be running ---
wait_for_lxc_running() {
    local lxc_id="$1"
    local max_attempts=30
    local attempt=1

    log "INFO" "$0: Ensuring LXC $lxc_id is running..."
    while [[ $attempt -le $max_attempts ]]; do
        if pct status "$lxc_id" | grep -q "status: running"; then
            log "INFO" "$0: LXC $lxc_id is running."
            return 0
        fi
        log "DEBUG" "$0: LXC $lxc_id not running yet (attempt $attempt/$max_attempts). Waiting 2 seconds..."
        sleep 2
        ((attempt++))
    done
    log "ERROR" "$0: LXC $lxc_id failed to start after $max_attempts attempts."
    return 1
}

# --- Wait for networking to be available in LXC ---
wait_for_lxc_network() {
    local lxc_id="$1"
    local max_attempts=30
    local attempt=1

    log "INFO" "$0: Ensuring networking is available in LXC $lxc_id..."
    while [[ $attempt -le $max_attempts ]]; do
        if execute_in_lxc "$lxc_id" "ping -c 1 8.8.8.8" >/dev/null 2>&1; then
            log "INFO" "$0: Networking is ready in LXC $lxc_id."
            return 0
        fi
        log "DEBUG" "$0: Networking not ready in LXC $lxc_id (attempt $attempt/$max_attempts). Waiting 2 seconds..."
        sleep 2
        ((attempt++))
    done
    log "ERROR" "$0: Networking failed to become available in LXC $lxc_id after $max_attempts attempts."
    return 1
}

# --- Get GPU device details for passthrough ---
detect_gpu_details() {
    local gpu_indices="$1"
    declare -gA GPU_DETAILS
    declare -g GPU_MAJOR_NUMBERS=""
    local major_numbers=()

    log "INFO" "$0: Detecting GPU details for indices: $gpu_indices"

    if [[ -z "$gpu_indices" ]]; then
        log "INFO" "$0: No GPU indices provided. Skipping GPU detection."
        return 0
    fi

    if ! command -v nvidia-smi >/dev/null 2>&1; then
        log "ERROR" "$0: nvidia-smi not found. Cannot detect GPUs."
        return 0
    fi

    local all_gpu_info
    all_gpu_info=$(nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader,nounits 2>/dev/null)
    if [[ $? -ne 0 ]] || [[ -z "$all_gpu_info" ]]; then
        log "ERROR" "$0: Failed to query NVIDIA GPU information with nvidia-smi."
        return 0
    fi

    log "DEBUG" "$0: nvidia-smi output: $all_gpu_info"

    for index in $gpu_indices; do
        if ! [[ "$index" =~ ^[0-9]+$ ]]; then
            log "ERROR" "$0: Invalid GPU index format: '$index'. Skipping."
            continue
        fi

        local gpu_line
        gpu_line=$(echo "$all_gpu_info" | grep "^$index,")
        if [[ -z "$gpu_line" ]]; then
            log "WARN" "$0: GPU index $index not found by nvidia-smi. Skipping."
            continue
        fi

        local pci_bus_id_full
        pci_bus_id_full=$(echo "$gpu_line" | cut -d',' -f2)
        local pci_bus_id
        pci_bus_id=$(echo "$pci_bus_id_full" | sed 's/^00000000:/0000:/')

        log "DEBUG" "$0: Found GPU $index with PCI Bus ID: $pci_bus_id"

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
                        log "DEBUG" "$0: Detected major number $dec_major for device $device"
                    fi
                fi
            else
                log "DEBUG" "$0: Device file $device for GPU $index does not exist, skipping."
            fi
        done

        if [[ ${#existing_device_files[@]} -gt 0 ]]; then
            GPU_DETAILS["$index"]="$pci_bus_id,$(IFS=','; echo "${existing_device_files[*]}")"
            log "INFO" "$0: Detected GPU $index (PCI: $pci_bus_id) with devices: $(IFS=','; echo "${existing_device_files[*]}")"
        else
            log "WARN" "$0: No device files found for GPU $index (PCI: $pci_bus_id)."
            GPU_DETAILS["$index"]="$pci_bus_id,"
        fi
    done

    GPU_MAJOR_NUMBERS=$(IFS=','; echo "${major_numbers[*]}")
    log "INFO" "$0: Detected GPU major device numbers for cgroup rules: $GPU_MAJOR_NUMBERS"
    return 0
}

# --- Configure GPU passthrough for LXC ---
configure_lxc_gpu_passthrough() {
    local lxc_id="$1"
    local gpu_indices="$2"
    local config_file="/etc/pve/lxc/$lxc_id.conf"
    local marker_file="${HYPERVISOR_MARKER_DIR}/lxc_${lxc_id}_gpu_configured.marker"

    if is_script_completed "$marker_file"; then
        log "INFO" "$0: GPU passthrough for LXC $lxc_id already configured. Skipping."
        return 0
    fi

    if [[ -z "$lxc_id" ]] || [[ -z "$gpu_indices" ]]; then
        log "INFO" "$0: No LXC ID or GPU indices provided for $lxc_id. Skipping GPU passthrough."
        mark_script_completed "$marker_file"
        return 0
    fi

    if [[ ! -f "$config_file" ]]; then
        log "ERROR" "$0: LXC config file not found: $config_file"
        return 0
    fi

    log "INFO" "$0: Configuring GPU passthrough for LXC $lxc_id using indices: '$gpu_indices'"

    if ! detect_gpu_details "$gpu_indices"; then
        log "WARN" "$0: GPU detection failed for LXC $lxc_id. Skipping GPU passthrough."
        mark_script_completed "$marker_file"
        return 0
    fi

    if [[ ${#GPU_DETAILS[@]} -eq 0 ]]; then
        log "INFO" "$0: No valid GPU details detected for LXC $lxc_id. Skipping GPU passthrough."
        mark_script_completed "$marker_file"
        return 0
    fi

    local tmpfile
    tmpfile=$(mktemp) || { log "ERROR" "$0: Failed to create temporary file for LXC config"; return 0; }
    cp "$config_file" "${config_file}.backup-$(date +%Y%m%d%H%M%S)" || { log "ERROR" "$0: Failed to backup $config_file"; return 0; }
    grep -v -E "^(lxc\.cgroup2\.devices\.allow.*c (195|510|226):|lxc\.mount\.entry.*(nvidia|dri))" "$config_file" > "$tmpfile"

    if [[ -n "$GPU_MAJOR_NUMBERS" ]]; then
        IFS=',' read -ra major_nums <<< "$GPU_MAJOR_NUMBERS"
        for major in "${major_nums[@]}"; do
            echo "lxc.cgroup2.devices.allow: c $major:* rwm" >> "$tmpfile"
            log "DEBUG" "$0: Added cgroup rule for major $major to $config_file"
        done
    else
        log "WARN" "$0: No GPU major numbers detected. Adding NVIDIA defaults (195, 510)."
        echo "lxc.cgroup2.devices.allow: c 195:* rwm" >> "$tmpfile"
        echo "lxc.cgroup2.devices.allow: c 510:* rwm" >> "$tmpfile"
    fi

    local device_files=("/dev/nvidia0" "/dev/nvidia1" "/dev/nvidia-ctl" "/dev/nvidia-modeset" "/dev/nvidia-uvm" "/dev/nvidia-uvm-tools" "/dev/nvidia-caps/nvidia-cap1" "/dev/nvidia-caps/nvidia-cap2")
    device_files+=("/dev/dri/card0" "/dev/dri/card1" "/dev/dri/renderD128" "/dev/dri/renderD129")

    for dev in "${device_files[@]}"; do
        if [[ -e "$dev" ]] && ! grep -q "lxc.mount.entry: $dev" "$config_file"; then
            echo "lxc.mount.entry: $dev ${dev#/dev/} none bind,optional,create=file" >> "$tmpfile"
            log "DEBUG" "$0: Added mount entry for $dev to $config_file"
        fi
    done

    mv "$tmpfile" "$config_file" || { log "ERROR" "$0: Failed to update $config_file"; return 0; }
    chmod 600 "$config_file" || { log "WARN" "$0: Failed to set permissions on $config_file"; }
    log "INFO" "$0: GPU passthrough configured for LXC $lxc_id."
    mark_script_completed "$marker_file"
}
```