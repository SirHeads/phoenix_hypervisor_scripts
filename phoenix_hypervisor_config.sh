#!/bin/bash
# phoenix_hypervisor_config.sh
# Configuration variables for the Phoenix Hypervisor project.
# Loads LXC configurations from JSON and validates storage and tools.
# Version: 1.6.9 (Removed applied defaults, kept for reference)
# Author: Assistant

set -euo pipefail

# Source common functions
source /usr/local/bin/phoenix_hypervisor_common.sh || { echo "Error: Failed to source phoenix_hypervisor_common.sh" >&2; exit 1; }

# Check root privileges early
check_root

# --- Core Paths ---
export HYPERVISOR_MARKER_DIR="/var/log/phoenix_hypervisor_markers"
export HYPERVISOR_LOGFILE="/var/log/phoenix_hypervisor/phoenix_hypervisor.log"
export PHOENIX_LXC_CONFIG_FILE="/usr/local/etc/phoenix_lxc_configs.json"

# --- Configuration Reference (Not Applied) ---
# Storage pool for LXC containers (must be specified in JSON)
REFERENCE_LXC_STORAGE_POOL="lxc-disks"
REFERENCE_LXC_STORAGE_SIZE_GB="32"
REFERENCE_LXC_TEMPLATE="/fastData/shared-iso/template/cache/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
REFERENCE_LXC_CORES="2"
REFERENCE_LXC_MEMORY_MB="2048"
REFERENCE_LXC_NETWORK_CONFIG="10.0.0.110/24,10.0.0.1,8.8.8.8"
REFERENCE_LXC_FEATURES="nesting=1"
REFERENCE_VLLM_MODEL="mistralai/Devstral-Small-2507"
REFERENCE_VLLM_TENSOR_PARALLEL_SIZE="2"
REFERENCE_VLLM_MAX_MODEL_LEN="128000"
REFERENCE_VLLM_KV_CACHE_DTYPE="fp8"
REFERENCE_VLLM_SHM_SIZE="10.24gb"
REFERENCE_VLLM_GPU_COUNT="all"
REFERENCE_VLLM_QUANTIZATION="bitsandbytes"
REFERENCE_VLLM_QUANTIZATION_CONFIG_TYPE="int8"

# --- Function: check_required_tools ---
check_required_tools() {
    local required_tools=("jq" "pct" "pveversion")
    local missing_tools=()

    log "DEBUG" "$0: Checking required tools: ${required_tools[*]}"
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log "ERROR" "$0: Required tools missing: ${missing_tools[*]}"
        log "INFO" "$0: Please install them (e.g., 'apt-get install jq')."
        exit 1
    fi
    log "INFO" "$0: All required tools are installed"
}

# --- Function: validate_storage_pool ---
validate_storage_pool() {
    local storage_pool="$1"
    log "DEBUG" "$0: Validating storage pool: $storage_pool"

    if ! pvesm status | grep -q "^$storage_pool.*active.*1"; then
        log "ERROR" "$0: Storage pool $storage_pool is not active or does not exist"
        pvesm status | while read -r line; do log "DEBUG" "$0: pvesm: $line"; done
        exit 1
    fi

    if [[ "$storage_pool" == "lxc-disks" ]]; then
        if ! validate_zfs_pool "quickOS/lxc-disks"; then
            log "ERROR" "$0: ZFS pool validation failed for quickOS/lxc-disks"
            exit 1
        fi
    fi
    log "INFO" "$0: Storage pool $storage_pool validated"
}

# --- Function: load_hypervisor_config ---
load_hypervisor_config() {
    check_required_tools
    validate_json_config "$PHOENIX_LXC_CONFIG_FILE"
    prompt_for_hf_token

    declare -gA LXC_CONFIGS
    declare -gA LXC_SETUP_SCRIPTS

    LXC_SETUP_SCRIPTS[901]="/usr/local/bin/phoenix_hypervisor_setup_drdevstral.sh"

    log "DEBUG" "$0: Validating setup scripts"
    for lxc_id in "${!LXC_SETUP_SCRIPTS[@]}"; do
        local script="${LXC_SETUP_SCRIPTS[$lxc_id]}"
        if [[ ! -x "$script" ]]; then
            log "ERROR" "$0: Setup script for LXC $lxc_id is not executable: $script"
            exit 1
        fi
        log "DEBUG" "$0: Valid setup script for LXC $lxc_id: $script"
    done

    log "INFO" "$0: Loading LXC configurations from $PHOENIX_LXC_CONFIG_FILE"
    while IFS='|' read -r id name memory_mb cores template storage_pool storage_size_gb nvidia_pci_ids network_config features gpu_assignment vllm_model vllm_tensor_parallel_size vllm_max_model_len vllm_kv_cache_dtype vllm_shm_size vllm_gpu_count vllm_quantization vllm_quantization_config_type; do
        if [[ -n "$storage_pool" ]]; then
            validate_storage_pool "$storage_pool"
        fi
        LXC_CONFIGS["$id"]="$name|$memory_mb|$cores|$template|$storage_pool|$storage_size_gb|$nvidia_pci_ids|$network_config|$features|$gpu_assignment|$vllm_model|$vllm_tensor_parallel_size|$vllm_max_model_len|$vllm_kv_cache_dtype|$vllm_shm_size|$vllm_gpu_count|$vllm_quantization|$vllm_quantization_config_type"
        log "DEBUG" "$0: Loaded LXC $id: $name, storage_pool=$storage_pool, gpu_assignment=$gpu_assignment, vllm_model=$vllm_model"
    done < <(jq -r '.lxc_configs | to_entries[] |
        "\(.key)|\(.value.name // "")|\(.value.memory_mb // "")|\(.value.cores // "")|\(.value.template // "")|\(.value.storage_pool // "")|\(.value.storage_size_gb // "")|\(.value.nvidia_pci_ids // "")|\(.value.network_config // "")|\(.value.features // "")|\(.value.gpu_assignment // "")|\(.value.vllm_model // "")|\(.value.vllm_tensor_parallel_size // "")|\(.value.vllm_max_model_len // "")|\(.value.vllm_kv_cache_dtype // "")|\(.value.vllm_shm_size // "")|\(.value.vllm_gpu_count // "")|\(.value.vllm_quantization // "")|\(.value.vllm_quantization_config_type // "")"' "$PHOENIX_LXC_CONFIG_FILE")

    if [[ ${#LXC_CONFIGS[@]} -eq 0 ]]; then
        log "WARN" "$0: No LXC configurations found in $PHOENIX_LXC_CONFIG_FILE"
    fi

    export LXC_CONFIGS
    export LXC_SETUP_SCRIPTS
    log "INFO" "$0: Phoenix Hypervisor configuration variables loaded and validated"
}