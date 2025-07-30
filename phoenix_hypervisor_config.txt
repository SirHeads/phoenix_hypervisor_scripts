#!/bin/bash

# phoenix_hypervisor_config.sh
# Configuration variables for the Hypervisor Prep Scripts project.
# Version: 1.4.0 (Updated to download JSON config from Git repository)
# Author: Assistant

# --- Function to load configuration variables ---
load_hypervisor_config() {
    # --- General Hypervisor Settings ---
    # Log file for the hypervisor prep scripts
    HYPERVISOR_LOGFILE="${HYPERVISOR_LOGFILE:-/var/log/hypervisor_prep.log}"
    export HYPERVISOR_LOGFILE

    # Ensure LOGFILE is set for any potential early logging within this function
# This is crucial because common functions might be sourced and expect LOGFILE.
# Set it locally first, then the main script will export it globally.
    if [[ -z "${LOGFILE:-}" ]]; then
        LOGFILE="$HYPERVISOR_LOGFILE"
        export LOGFILE
    fi

    # Marker file directory
    HYPERVISOR_MARKER_DIR="${HYPERVISOR_MARKER_DIR:-/var/log/hypervisor_prep_markers}"
    export HYPERVISOR_MARKER_DIR

    # --- LXC Container Definitions ---
    # Associative array to hold LXC configurations, loaded from JSON file
    # JSON file format (stored in /etc/phoenix_lxc_configs.json):
    # {
    #   "lxc_configs": {
    #     "<lxc_id>": {
    #       "name": "<container_name>",
    #       "memory_mb": <integer>,
    #       "balloon_min_mb": <integer>,
    #       "cores": <integer>,
    #       "template": "<template_file>",
    #       "storage_pool": "<proxmox_storage_id>",
    #       "storage_size_gb": <integer>,
    #       "nvidia_pci_ids": "<space-separated PCI IDs or empty>",
    #       "network_config": "<ip_address_cidr,gateway,dns_server or dhcp>",
    #       "vllm_model": "<vLLM model name>",
    #       "vllm_tensor_parallel_size": <integer>,
    #       "vllm_max_model_len": <integer>,
    #       "vllm_quantization": "<quantization type>",
    #       "vllm_kv_cache_dtype": "<dtype>",
    #       "vllm_shm_size": "<size>",
    #       "vllm_gpu_count": "<count or all>"
    #     }
    #   }
    # }
    # Example: {"901": {"name": "DrDevstral", "memory_mb": 32768, ...}}
    # Constraints:
    # - lxc_id: Unique integer
    # - name: Alphanumeric string
    # - memory_mb, balloon_min_mb, cores, storage_size_gb: Positive integers
    # - template: Valid file in /var/lib/vz/template/cache/
    # - storage_pool: Valid Proxmox storage ID
    # - nvidia_pci_ids: Space-separated PCI IDs (e.g., "0000:01:00.0 0000:02:00.0") or empty
    # - network_config: "ip/cidr,gw,dns" (e.g., "10.0.0.100/24,10.0.0.1,8.8.8.8") or "dhcp"
    # - vllm_model: Valid Hugging Face model name (e.g., "stabilityai/devstral-small-8bit")
    # - vllm_tensor_parallel_size, vllm_max_model_len: Positive integers
    # - vllm_quantization: Valid vLLM quantization type (e.g., "awq")
    # - vllm_kv_cache_dtype: Valid dtype (e.g., "fp8")
    # - vllm_shm_size: Docker shared memory size (e.g., "10.24gb")
    # - vllm_gpu_count: Number of GPUs or "all"
    declare -gA LXC_CONFIGS

    # Path to JSON configuration file
    local config_file="/etc/phoenix_lxc_configs.json"
    local git_repo_url="${GIT_REPO_URL:-https://github.com/your-org/phoenix-hypervisor.git}"
    local git_repo_dir="/usr/local/bin/phoenix-hypervisor"
    local json_source_path="$git_repo_dir/config/phoenix_lxc_configs.json"

    # Check if git is installed
    if ! command -v git >/dev/null 2>&1; then
        echo "Installing git for repository access..."
        apt-get update && apt-get install -y git || { echo "Error: Failed to install git" >&2; exit 1; }
    fi

    # Download JSON config from Git repository if it doesn't exist
    if [[ ! -f "$config_file" ]]; then
        log "INFO" "JSON config $config_file not found, downloading from Git repository..."
        mkdir -p "$git_repo_dir"
        if [[ -d "$git_repo_dir/.git" ]]; then
            log "INFO" "Updating existing Git repository in $git_repo_dir..."
            cd "$git_repo_dir" && git pull origin main || { log "ERROR" "Failed to update Git repository"; exit 1; }
        else
            log "INFO" "Cloning Git repository to $git_repo_dir..."
            git clone "$git_repo_url" "$git_repo_dir" || { log "ERROR" "Failed to clone Git repository"; exit 1; }
        fi

        # Copy JSON file to /etc/
        if [[ -f "$json_source_path" ]]; then
            mkdir -p "$(dirname "$config_file")"
            cp "$json_source_path" "$config_file" || { log "ERROR" "Failed to copy $json_source_path to $config_file"; exit 1; }
            chmod 644 "$config_file"
            log "INFO" "JSON config copied to $config_file"
        else
            log "ERROR" "JSON config not found in Git repository at $json_source_path"
            exit 1
        fi
    fi

    # Check if jq is installed
    if ! command -v jq >/dev/null 2>&1; then
        echo "Installing jq for JSON parsing..."
        apt-get update && apt-get install -y jq || { echo "Error: Failed to install jq" >&2; exit 1; }
    fi

    # Load LXC configurations from JSON
    local lxc_ids
    lxc_ids=$(jq -r '.lxc_configs | keys[]' "$config_file")
    for lxc_id in $lxc_ids; do
        config_string=$(jq -r ".lxc_configs.\"$lxc_id\" | [.name, .memory_mb, .balloon_min_mb, .cores, .template, .storage_pool, .storage_size_gb, .nvidia_pci_ids, .network_config] | join(\",\")" "$config_file")
        LXC_CONFIGS[$lxc_id]="$config_string"
    done
    export LXC_CONFIGS

    # --- LXC Setup Scripts ---
    # Associative array mapping LXC ID to its specific setup script
    # Format: [lxc_id]="script_path"
    # Example: [901]="/usr/local/bin/phoenix_lxc_setup_drdevstral.sh"
    # Constraints:
    # - lxc_id: Must match a key in LXC_CONFIGS
    # - script_path: Valid, executable script file
    declare -gA LXC_SETUP_SCRIPTS
    LXC_SETUP_SCRIPTS[901]="/usr/local/bin/phoenix_lxc_setup_drdevstral.sh"
    # Add mappings for other LXCs:
    # LXC_SETUP_SCRIPTS[902]="/usr/local/bin/phoenix_lxc_setup_anothercontainer.sh"
    export LXC_SETUP_SCRIPTS

    # --- LXC Internal Settings (used by setup scripts) ---
    # DrDevstral specific settings
    DRTOOLBOX_NVIDIA_DRIVER_VERSION="open-575.57.08"  # Should match the host driver version
    DRTOOLBOX_NVIDIA_DRIVER_PKG="nvidia-${DRTOOLBOX_NVIDIA_DRIVER_VERSION}"
    export DRTOOLBOX_NVIDIA_DRIVER_VERSION DRTOOLBOX_NVIDIA_DRIVER_PKG

    # --- Common LXC Setup Options ---
    # Default password for LXC root user (prompt if not set)
    if [[ -z "$LXC_DEFAULT_ROOT_PASSWORD" ]]; then
        # Check for a password file
        if [[ -f "/etc/phoenix_lxc_root_password" ]]; then
            LXC_DEFAULT_ROOT_PASSWORD=$(cat "/etc/phoenix_lxc_root_password")
        else
            read -sp "Enter default LXC root password: " LXC_DEFAULT_ROOT_PASSWORD
            echo
            if [[ -z "$LXC_DEFAULT_ROOT_PASSWORD" ]]; then
                echo "Error: LXC_DEFAULT_ROOT_PASSWORD cannot be empty" >&2
                exit 1
            fi
        fi
    fi
    export LXC_DEFAULT_ROOT_PASSWORD

    # Default SSH public key to add to LXC root user (optional)
    LXC_DEFAULT_ROOT_SSH_KEY="${LXC_DEFAULT_ROOT_SSH_KEY:-}"
    export LXC_DEFAULT_ROOT_SSH_KEY

    log "INFO" "Hypervisor configuration variables loaded and validated"
}

# Ensure this script is sourced, not executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This script is intended to be sourced, not executed directly."
    exit 1
fi