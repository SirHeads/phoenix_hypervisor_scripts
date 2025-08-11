#!/bin/bash
# Configuration file for Phoenix Hypervisor
# Defines essential file paths and default settings
# Version: 1.7.4
# Author: Assistant

# --- Core Paths ---
# Path to the main LXC configuration JSON file
export PHOENIX_LXC_CONFIG_FILE="${PHOENIX_LXC_CONFIG_FILE:-/usr/local/etc/phoenix_lxc_configs.json}"

# Path to the JSON schema for validating the LXC configuration
export PHOENIX_LXC_CONFIG_SCHEMA_FILE="${PHOENIX_LXC_CONFIG_SCHEMA_FILE:-/usr/local/etc/phoenix_lxc_configs.schema.json}"

# Path to the Hugging Face token file
export PHOENIX_HF_TOKEN_FILE="${PHOENIX_HF_TOKEN_FILE:-/usr/local/etc/phoenix_hf_token.conf}"

# Directory for Phoenix Hypervisor marker files (to track setup state)
export HYPERVISOR_MARKER_DIR="${HYPERVISOR_MARKER_DIR:-/var/lib/phoenix_hypervisor/markers}"

# Full path to the marker file indicating successful hypervisor setup
export HYPERVISOR_MARKER="${HYPERVISOR_MARKER:-$HYPERVISOR_MARKER_DIR/.phoenix_hypervisor_setup_complete}"

# Log file for the hypervisor process
export HYPERVISOR_LOGFILE="${HYPERVISOR_LOGFILE:-/var/log/phoenix_hypervisor/phoenix_hypervisor.log}"

# Library directory for Phoenix Hypervisor scripts and modules
export PHOENIX_HYPERVISOR_LIB_DIR="${PHOENIX_HYPERVISOR_LIB_DIR:-/usr/local/lib/phoenix_hypervisor}"

# --- ZFS Pool Configuration ---
# ZFS pool for LXC container storage (if used)
export PHOENIX_ZFS_LXC_POOL="${PHOENIX_ZFS_LXC_POOL:-quickOS/lxc-disks}"

# --- Default LXC Container Settings ---
# Default CPU cores for LXC containers
export DEFAULT_LXC_CORES="${DEFAULT_LXC_CORES:-2}"

# Default memory (RAM) in MB for LXC containers
export DEFAULT_LXC_MEMORY_MB="${DEFAULT_LXC_MEMORY_MB:-2048}"

# Default network configuration (CIDR, Gateway, DNS)
export DEFAULT_LXC_NETWORK_CONFIG="${DEFAULT_LXC_NETWORK_CONFIG:-10.0.0.110/24,10.0.0.1,8.8.8.8}"

# Default LXC features (e.g., nesting=1,keyctl=1)
export DEFAULT_LXC_FEATURES="${DEFAULT_LXC_FEATURES:-nesting=1}"

# --- Default NVIDIA Configuration ---
# NVIDIA driver version to use across all containers
export NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-580.65.06}"

# NVIDIA runfile URL for driver installation in containers
export NVIDIA_RUNFILE_URL="${NVIDIA_RUNFILE_URL:-http://us.download.nvidia.com/XFree86/Linux-x86_64/580.65.06/NVIDIA-Linux-x86_64-580.65.06.run}"

# Default GPU assignment for containers (empty = no GPUs, "0" = GPU 0, "0,1" = both GPUs)
# This is a fallback, specific assignments should be in the JSON config or PHOENIX_GPU_ASSIGNMENTS
export DEFAULT_GPU_ASSIGNMENT="${DEFAULT_GPU_ASSIGNMENT:-}"

# Associative array defining GPU assignments for LXCs
# Key: LXC ID, Value: Comma-separated GPU indices (e.g., "0", "1", "0,1")
# Declaring it here ensures it exists. Initialization can happen dynamically or from JSON.
declare -gA PHOENIX_GPU_ASSIGNMENTS

# --- Security and Debugging Flags ---
# Rollback on failure flag (set to "true" to enable)
export ROLLBACK_ON_FAILURE="${ROLLBACK_ON_FAILURE:-false}"

# Default container security settings
export DEFAULT_CONTAINER_SECURITY="${DEFAULT_CONTAINER_SECURITY:-unconfined}"

# Enable LXC nesting (required for Docker-in-LXC)
export DEFAULT_CONTAINER_NESTING="${DEFAULT_CONTAINER_NESTING:-1}"

# Enable verbose logging for development/debugging
export DEBUG_MODE="${DEBUG_MODE:-false}"

# Signal that this configuration file has been loaded
export PHOENIX_HYPERVISOR_CONFIG_LOADED=1
