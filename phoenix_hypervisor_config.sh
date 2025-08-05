#!/bin/bash
# phoenix_hypervisor_config.sh
# Configuration variables for the Phoenix Hypervisor scripts.
# Version: 1.7.3
# Author: Assistant

# --- Core Paths ---
# Directory for storing marker files to track script completion
export HYPERVISOR_MARKER_DIR="${PHOENIX_MARKER_DIR:-/var/log/phoenix_hypervisor_markers}"
# Marker file for tracking overall hypervisor setup completion
export PHOENIX_HYPERVISOR_COMPLETED_MARKER="${HYPERVISOR_MARKER_DIR}/hypervisor_setup_completed.marker"
# Log file for hypervisor setup and management scripts
export HYPERVISOR_LOGFILE="${PHOENIX_LOGFILE:-/var/log/phoenix_hypervisor/phoenix_hypervisor.log}"
# Path to the JSON configuration file for LXC containers
export PHOENIX_LXC_CONFIG_FILE="${PHOENIX_LXC_CONFIG_FILE:-/usr/local/etc/phoenix_lxc_configs.json}"
# Secret key path for encryption
export PHOENIX_SECRET_KEY_FILE="${PHOENIX_SECRET_KEY_FILE:-/etc/phoenix/secret.key}"
# Path to Hugging Face token file
export PHOENIX_HF_TOKEN_FILE="${PHOENIX_HF_TOKEN_FILE:-/usr/local/etc/phoenix_hf_token.conf}"
# Path to LXC password file
export PHOENIX_LXC_PASSWORD_FILE="${PHOENIX_LXC_PASSWORD_FILE:-/usr/local/etc/phoenix_lxc_password.conf}"

# --- Proxmox Settings ---
# Storage pool for LXC containers (must exist in Proxmox)
export DEFAULT_LXC_STORAGE_POOL="lxc-disks"
# Default storage size for LXC containers if not specified in config
export DEFAULT_LXC_STORAGE_SIZE_GB="32"
# Default LXC template path
export DEFAULT_LXC_TEMPLATE="/fastData/shared-iso/template/cache/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
# ZFS pool for LXC storage
export PHOENIX_ZFS_LXC_POOL="quickOS/lxc-disks"

# --- LXC Defaults ---
# Default CPU cores for LXC containers
export DEFAULT_LXC_CORES="2"
# Default memory (RAM) in MB for LXC containers
export DEFAULT_LXC_MEMORY_MB="2048"
# Default network configuration (CIDR, Gateway, DNS)
export DEFAULT_LXC_NETWORK_CONFIG="10.0.0.110/24,10.0.0.1,8.8.8.8"
# Default LXC features (e.g., nesting=1,keyctl=1)
export DEFAULT_LXC_FEATURES="nesting=1"

# --- vLLM Defaults ---
# Default vLLM model to load
export DEFAULT_VLLM_MODEL="NousResearch/Hermes-3-Llama-3.1-8B"
# Default tensor parallel size for vLLM
export DEFAULT_VLLM_TENSOR_PARALLEL_SIZE="1"
# Default maximum model length for vLLM
export DEFAULT_VLLM_MAX_MODEL_LEN="20000"
# Default KV cache data type for vLLM
export DEFAULT_VLLM_KV_CACHE_DTYPE="fp8"
# Default shared memory size for vLLM Docker container
export DEFAULT_VLLM_SHM_SIZE="10.24gb"
# Default GPU count for vLLM Docker container
export DEFAULT_VLLM_GPU_COUNT="1"
# Default vLLM API port
export DEFAULT_VLLM_API_PORT="8000"
# Default vLLM quantization
export DEFAULT_VLLM_QUANTIZATION="none"
# Default vLLM quantization config type
export DEFAULT_VLLM_QUANTIZATION_CONFIG_TYPE="none"

# --- GPU Passthrough Configuration ---
# Associative array defining GPU assignments for LXCs
# Key: LXC ID, Value: Comma-separated GPU indices (e.g., "0", "1", "0,1")
# Example:
# declare -gA PHOENIX_GPU_ASSIGNMENTS=( ["901"]="0" ["902"]="1" )
# Use declare -gA to ensure it's a global associative array accessible by other scripts
declare -gA PHOENIX_GPU_ASSIGNMENTS

# Initialize with the assignment for LXC 901
# This should be customized for your specific setup
PHOENIX_GPU_ASSIGNMENTS["901"]="0"

# Rollback on failure flag
export ROLLBACK_ON_FAILURE=true