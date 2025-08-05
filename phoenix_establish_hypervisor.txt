```bash
#!/bin/bash
# Main script to establish the Phoenix Hypervisor on Proxmox
# Orchestrates LXC creation and setup (e.g., drdevstral with vLLM) based on phoenix_lxc_configs.json
# Prerequisites:
# - Proxmox VE 8.x (tested with 8.4.6)
# - phoenix_hypervisor_common.sh and phoenix_hypervisor_config.sh sourced
# - NVIDIA drivers installed on host
# Usage: ./phoenix_establish_hypervisor.sh [--hf-token <token>]
# Version: 1.7.2
# Author: Assistant
set -euo pipefail

# Source common functions and configuration
source /usr/local/bin/phoenix_hypervisor_common.sh || { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $0: Failed to source phoenix_hypervisor_common.sh" >&2; exit 1; }
source /usr/local/bin/phoenix_hypervisor_config.sh || { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $0: Failed to source phoenix_hypervisor_config.sh" >&2; exit 1; }

# Default ROLLBACK_ON_FAILURE if not set
: "${ROLLBACK_ON_FAILURE:=true}"

# Function to check system requirements
check_requirements() {
    log "INFO" "$0: Checking system requirements..."
    local required_commands=("pct" "pvesm" "qm" "curl" "jq")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log "ERROR" "$0: Required command '$cmd' not found."
            echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Required command '$cmd' not found." >&2
            exit 1
        fi
    done
    if ! grep -q "pve" /etc/os-release; then
        log "ERROR" "$0: This script must run on a Proxmox VE system."
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] This script must run on a Proxmox VE system." >&2
        exit 1
    fi
    log "INFO" "$0: System requirements met."
}

# Function to validate GPU assignments
validate_gpu_assignments() {
    log "INFO" "$0: Validating GPU assignments..."
    declare -A available_gpus
    if command -v nvidia-smi >/dev/null 2>&1; then
        mapfile -t gpu_info < <(nvidia-smi --query-gpu=index --format=csv,noheader,nounits 2>/dev/null)
        for index in "${gpu_info[@]}"; do
            available_gpus["$index"]="available"
        done
    else
        mapfile -t gpu_info < <(lspci -d 10de: -n | awk '{print NR-1}')
        for index in "${gpu_info[@]}"; do
            available_gpus["$index"]="available"
        done
    fi
    if [[ ${#available_gpus[@]} -eq 0 ]]; then
        log "ERROR" "$0: No NVIDIA GPUs detected on the host"
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] No NVIDIA GPUs detected on the host." >&2
        exit 1
    fi
    log "DEBUG" "$0: Detected GPUs: ${!available_gpus[*]}"
    for lxc_id in "${!PHOENIX_GPU_ASSIGNMENTS[@]}"; do
        IFS=',' read -ra gpu_indices <<< "${PHOENIX_GPU_ASSIGNMENTS[$lxc_id]}"
        for index in "${gpu_indices[@]}"; do
            if [[ -z "${available_gpus[$index]:-}" ]]; then
                log "ERROR" "$0: GPU index $index assigned to LXC $lxc_id is not available"
                echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] GPU index $index for LXC $lxc_id is not available." >&2
                exit 1
            fi
            available_gpus["$index"]="assigned"
        done
    done
    log "INFO" "$0: GPU assignments validated successfully."
}

# Function to rollback changes
rollback() {
    local lxc_id="$1"
    log "WARN" "$0: Initiating rollback for LXC $lxc_id..."
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] Rolling back changes for LXC $lxc_id..." >&2
    if pct status "$lxc_id" >/dev/null 2>&1; then
        log "INFO" "$0: Destroying LXC $lxc_id..."
        pct destroy "$lxc_id" 2>&1 | while read -r line; do log "DEBUG" "$0: pct destroy: $line"; done || true
    fi
    rm -f "${PHOENIX_HYPERVISOR_LXC_MARKER/lxc_id/$lxc_id}" \
          "${PHOENIX_HYPERVISOR_LXC_GPU_MARKER/lxc_id/$lxc_id}" \
          "${PHOENIX_HYPERVISOR_LXC_DRDEVSTRAL_MARKER/lxc_id/$lxc_id}" 2>/dev/null || true
    log "INFO" "$0: Rollback completed for LXC $lxc_id."
}

main() {
    # Check for non-interactive environment
    if [[ ! -t 0 ]] && [[ -z "$HUGGING_FACE_HUB_TOKEN" ]] && [[ -z "$HF_TOKEN_OVERRIDE" ]]; then
        log "ERROR" "$0: Non-interactive environment detected and no HUGGING_FACE_HUB_TOKEN provided."
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Non-interactive environment detected and no HUGGING_FACE_HUB_TOKEN provided." >&2
        exit 1
    fi
    if [[ ! -t 0 ]] && [[ -z "${LXC_PASSWORD:-}" ]]; then
        log "ERROR" "$0: Non-interactive environment detected and no LXC_PASSWORD provided."
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Non-interactive environment detected and no LXC_PASSWORD provided." >&2
        exit 1
    fi

    log "INFO" "$0: Starting Phoenix Hypervisor setup..."
    check_root
    log "INFO" "$0: Root check passed."

    log "INFO" "$0: Loading hypervisor configuration..."
    load_hypervisor_config || { log "ERROR" "$0: Failed to load hypervisor configuration"; exit 1; }
    log "INFO" "$0: Configuration loaded."

    # Handle secrets
    if [[ -n "$HF_TOKEN_OVERRIDE" ]]; then
        export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN_OVERRIDE"
        log "INFO" "$0: HUGGING_FACE_HUB_TOKEN provided via --hf-token argument."
    elif [[ -n "$HUGGING_FACE_HUB_TOKEN" ]]; then
        log "INFO" "$0: HUGGING_FACE_HUB_TOKEN provided via environment variable."
    else
        log "INFO" "$0: Prompting for Hugging Face token..."
        prompt_for_hf_token
        log "INFO" "$0: Hugging Face token set."
    fi
    if [[ -n "${LXC_PASSWORD:-}" ]]; then
        log "INFO" "$0: LXC root password provided via environment variable."
    else
        log "INFO" "$0: Prompting for LXC root password..."
        prompt_for_lxc_password
        log "INFO" "$0: LXC root password set."
    fi

    # Check if setup is already completed
    if is_script_completed "$HYPERVISOR_MARKER"; then
        log "INFO" "$0: Hypervisor setup already completed. Exiting."
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Hypervisor setup already completed. Exiting." >&2
        exit 0
    fi

    # Validate GPU assignments
    validate_gpu_assignments

    # Run initial setup
    log "INFO" "$0: Running initial setup script..."
    if ! retry_command 5 10 "/usr/local/bin/phoenix_hypervisor_initial_setup.sh" 2>&1 | while read -r line; do log "DEBUG" "$0: phoenix_hypervisor_initial_setup.sh: $line"; done; then
        log "ERROR" "$0: Initial setup script failed."
        echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Initial setup failed." >&2
        if [[ "$ROLLBACK_ON_FAILURE" == true ]]; then
            log "WARN" "$0: No LXC-specific rollback needed for initial setup failure."
        fi
        exit 1
    fi
    log "INFO" "$0: Initial setup completed."

    # Iterate and create LXCs
    log "INFO" "$0: Starting LXC creation loop..."
    for lxc_id in "${!LXC_CONFIGS[@]}"; do
        log "INFO" "$0: Processing LXC $lxc_id..."
        local config="${LXC_CONFIGS[$lxc_id]}"
        local IFS=$'\t'
        read -r name memory_mb cores template storage_pool storage_size_gb nvidia_pci_ids network_config features gpu_assignment vllm_model vllm_tensor_parallel_size vllm_max_model_len vllm_kv_cache_dtype vllm_shm_size vllm_gpu_count vllm_quantization vllm_quantization_config_type vllm_api_port <<< "$config"
        if ! validate_lxc_id "$lxc_id"; then
            log "ERROR" "$0: Invalid LXC ID format: '$lxc_id'"
            echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Invalid LXC ID format: '$lxc_id'." >&2
            exit 1
        fi
        if is_script_completed "${PHOENIX_HYPERVISOR_LXC_MARKER/lxc_id/$lxc_id}"; then
            log "INFO" "$0: LXC $lxc_id already created. Skipping creation."
        else
            log "INFO" "$0: Creating LXC $lxc_id..."
            local gpu_enabled="false"
            [[ -n "$gpu_assignment" ]] && gpu_enabled="true"
            if ! retry_command 3 5 "/usr/local/bin/phoenix_hypervisor_create_lxc.sh $lxc_id \"$template\" \"$storage_pool\" \"$storage_size_gb\" \"$memory_mb\" \"$cores\" \"$name\" \"$network_config\" \"$gpu_enabled\"" 2>&1 | while read -r line; do log "DEBUG" "$0: phoenix_hypervisor_create_lxc.sh: $line"; done; then
                log "ERROR" "$0: Failed to create LXC $lxc_id."
                echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to create LXC $lxc_id." >&2
                if [[ "$ROLLBACK_ON_FAILURE" == true ]]; then
                    rollback "$lxc_id"
                fi
                exit 1
            fi
            log "INFO" "$0: LXC $lxc_id created successfully."
        fi

        # Setup drdevstral if GPU assigned
        if [[ -n "$gpu_assignment" ]]; then
            log "INFO" "$0: Setting up drdevstral in LXC $lxc_id..."
            if ! retry_command 3 10 "/usr/local/bin/phoenix_hypervisor_setup_drdevstral.sh $lxc_id \"$name\" \"$vllm_model\" \"$vllm_tensor_parallel_size\" \"$vllm_max_model_len\" \"$vllm_kv_cache_dtype\" \"$vllm_shm_size\" \"$vllm_gpu_count\" \"$vllm_quantization\" \"$vllm_quantization_config_type\" \"$vllm_api_port\"" 2>&1 | while read -r line; do log "DEBUG" "$0: phoenix_hypervisor_setup_drdevstral.sh: $line"; done; then
                log "ERROR" "$0: Failed to setup drdevstral in LXC $lxc_id."
                echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Failed to setup drdevstral in LXC $lxc_id." >&2
                if [[ "$ROLLBACK_ON_FAILURE" == true ]]; then
                    rollback "$lxc_id"
                fi
                exit 1
            fi
            log "INFO" "$0: drdevstral setup completed in LXC $lxc_id."
        fi
    done

    # Final validation
    log "INFO" "$0: Validating all LXC containers..."
    for lxc_id in "${!LXC_CONFIGS[@]}"; do
        if ! pct status "$lxc_id" | grep -q "status: running"; then
            log "ERROR" "$0: LXC $lxc_id is not running"
            echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] LXC $lxc_id is not running." >&2
            if [[ "$ROLLBACK_ON_FAILURE" == true ]]; then
                rollback "$lxc_id"
            fi
            exit 1
        fi
        local config="${LXC_CONFIGS[$lxc_id]}"
        local IFS=$'\t'
        read -r name _ _ _ _ _ _ _ _ gpu_assignment _ _ _ _ _ _ _ _ vllm_api_port <<< "$config"
        if [[ -n "$gpu_assignment" ]]; then
            local sanitized_name
            sanitized_name=$(sanitize_input "$name")
            if ! execute_in_lxc "$lxc_id" "systemctl is-active vllm-$sanitized_name.service" >/dev/null 2>&1; then
                log "ERROR" "$0: vLLM service for LXC $lxc_id is not active"
                echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] vLLM service for LXC $lxc_id is not active." >&2
                if [[ "$ROLLBACK_ON_FAILURE" == true ]]; then
                    rollback "$lxc_id"
                fi
                exit 1
            fi
            if ! execute_in_lxc "$lxc_id" "curl -f http://localhost:$vllm_api_port/v1/health" >/dev/null 2>&1; then
                log "ERROR" "$0: vLLM health check failed for LXC $lxc_id on port $vllm_api_port"
                echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] vLLM health check failed for LXC $lxc_id on port $vllm_api_port." >&2
                if [[ "$ROLLBACK_ON_FAILURE" == true ]]; then
                    rollback "$lxc_id"
                fi
                exit 1
            fi
            log "INFO" "$0: LXC $lxc_id validated: running with active vLLM service on port $vllm_api_port."
        fi
    done

    log "INFO" "$0: Phoenix Hypervisor setup completed successfully."
    mark_script_completed "$HYPERVISOR_MARKER"
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Phoenix Hypervisor setup completed successfully." >&2
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hf-token)
            HF_TOKEN_OVERRIDE="$2"
            shift 2
            ;;
        *)
            log "ERROR" "$0: Unknown option: $1"
            echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Execute main function
main
```