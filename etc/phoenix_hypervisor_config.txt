#!/bin/bash
# Configuration file for Phoenix Hypervisor
# Defines essential file paths and default settings for LXC creation on Proxmox
# Version: 1.8.6 (Enhanced validation, added ZFS checks, improved security)
# Author: Assistant

# --- Core Paths ---
# Path to the main LXC configuration JSON file
# Note: Contains per-container settings (e.g., memory, GPU, Portainer role). Must exist and be valid JSON.
export PHOENIX_LXC_CONFIG_FILE="${PHOENIX_LXC_CONFIG_FILE:-/usr/local/etc/phoenix_lxc_configs.json}"

# Path to the JSON schema for validating the LXC configuration
# Note: Used to ensure config JSON adheres to schema. Must exist and be valid JSON schema.
export PHOENIX_LXC_CONFIG_SCHEMA_FILE="${PHOENIX_LXC_CONFIG_SCHEMA_FILE:-/usr/local/etc/phoenix_lxc_configs.schema.json}"

# Path to the Hugging Face token file
# Note: Contains API token for downloading AI models (e.g., Qwen2.5-Coder-7B). Must be readable and secure (chmod 600 or 640).
export PHOENIX_HF_TOKEN_FILE="${PHOENIX_HF_TOKEN_FILE:-/usr/local/etc/phoenix_hf_token.conf}"

# Path to the Docker Hub token file
# Note: Contains credentials for Docker Hub image pulls (e.g., Portainer images). Must be readable and secure (chmod 600 or 640).
export PHOENIX_DOCKER_TOKEN_FILE="${PHOENIX_DOCKER_TOKEN_FILE:-/usr/local/etc/phoenix_docker_token.conf}"

# --- Docker Images Path ---
# Path to the shared directory containing Docker images/contexts (e.g., Modelfiles)
# Note: Should be accessible from the Proxmox host and mounted appropriately.
export PHOENIX_DOCKER_IMAGES_PATH="${PHOENIX_DOCKER_IMAGES_PATH:-/fastData/shared-bulk-data/proxmox_docker_images}"

# Directory for Phoenix Hypervisor marker files
# Used to track setup status and potentially other states.
export HYPERVISOR_MARKER_DIR="${HYPERVISOR_MARKER_DIR:-/var/lib/phoenix_hypervisor}"
export HYPERVISOR_MARKER="${HYPERVISOR_MARKER:-$HYPERVISOR_MARKER_DIR/.phoenix_hypervisor_initialized}"

# --- External Docker Registry Configuration ---
# URL for the external Docker registry (Docker Hub with username SirHeads)
# Note: Used for authenticated pulls/pushes, critical for Portainer (container 999) to manage Docker images.
export EXTERNAL_REGISTRY_URL="${EXTERNAL_REGISTRY_URL:-docker.io/SirHeads}"

# --- Storage Configuration ---
# ZFS pool for LXC container storage
# Note: Must be an existing ZFS pool with sufficient space for AI workloads (e.g., 64-216 GB per container).
export PHOENIX_ZFS_LXC_POOL="${PHOENIX_ZFS_LXC_POOL:-quickOS/lxc-disks}"

# Fallback storage pool for non-ZFS setups
# Note: Used if ZFS pool is unavailable or not configured. Common Proxmox default is 'local-lvm'.
export PHOENIX_FALLBACK_STORAGE="${PHOENIX_FALLBACK_STORAGE:-local-lvm}"

# --- Default LXC Container Settings ---
# Default CPU cores for LXC containers
# Note: For AI workloads, 2-8 cores recommended; overridden by JSON config for specific containers.
export DEFAULT_LXC_CORES="${DEFAULT_LXC_CORES:-2}"

# Default memory (RAM) in MB for LXC containers
# Note: For AI workloads, 2048-32768 MB recommended; JSON config overrides for larger models (e.g., 32-90 GB).
export DEFAULT_LXC_MEMORY_MB="${DEFAULT_LXC_MEMORY_MB:-2048}"

# Default network configuration (CIDR, Gateway, DNS)
# Note: Format compatible with Proxmox 'pct' commands. JSON config provides per-container overrides.
export DEFAULT_LXC_NETWORK_CONFIG="${DEFAULT_LXC_NETWORK_CONFIG:-10.0.0.110/24,10.0.0.1,8.8.8.8}"

# Default LXC features (e.g., nesting=1,keyctl=1)
# Note: Nesting required for Docker-in-LXC (e.g., Portainer); keyctl optional for advanced capabilities.
export DEFAULT_LXC_FEATURES="${DEFAULT_LXC_FEATURES:-nesting=1}"

# --- Portainer Configuration ---
# IP address of the Portainer Server container
# Note: Must match container 999's IP (Portainer server) in JSON config for agent connections.
export PORTAINER_SERVER_IP="${PORTAINER_SERVER_IP:-10.0.0.99}"

# Port for accessing the Portainer web UI
# Note: Port 9443 recommended for secure HTTPS access to Portainer UI (https://10.0.0.99:9443).
export PORTAINER_SERVER_PORT="${PORTAINER_SERVER_PORT:-9443}"

# Port for Portainer Agent communication
# Note: Must be accessible from other containers (e.g., 900, 901, 902) for cluster management.
export PORTAINER_AGENT_PORT="${PORTAINER_AGENT_PORT:-9001}"

# --- Security and Debugging Flags ---
# Rollback on failure flag
# Note: If 'true', scripts attempt to rollback failed LXC creations (e.g., delete partial containers).
export ROLLBACK_ON_FAILURE="${ROLLBACK_ON_FAILURE:-false}"

# Default container security settings
# Note: 'unconfined' allows GPU/Docker access but reduces security; 'default' recommended for production.
# Warning: Conflicts with JSON 'unprivileged'; ensure alignment in scripts.
export DEFAULT_CONTAINER_SECURITY="${DEFAULT_CONTAINER_SECURITY:-unconfined}"

# Enable LXC nesting
# Note: Required for Docker-in-LXC (e.g., Portainer, optional AI containers). Redundant with DEFAULT_LXC_FEATURES.
export DEFAULT_CONTAINER_NESTING="${DEFAULT_CONTAINER_NESTING:-1}"

# Enable verbose logging for development/debugging
# Note: If 'true', skips validation and logs detailed output for troubleshooting.
export DEBUG_MODE="${DEBUG_MODE:-false}"

# --- Validation Section ---
# Validate critical configuration values
validate_config() {
    errors=0
    
    # Validate file existence for critical paths
    for file in "$PHOENIX_LXC_CONFIG_FILE" "$PHOENIX_LXC_CONFIG_SCHEMA_FILE" "$PHOENIX_HF_TOKEN_FILE" "$PHOENIX_DOCKER_TOKEN_FILE"; do
        if [[ ! -f "$file" ]]; then
            echo "[ERROR] File does not exist: $file" >&2
            ((errors++))
        fi
    done
    
    # Validate token file permissions (should be 600 or 640 for security)
    for token_file in "$PHOENIX_HF_TOKEN_FILE" "$PHOENIX_DOCKER_TOKEN_FILE"; do
        if [[ -f "$token_file" ]]; then
            perms=$(stat -c "%a" "$token_file")
            if [[ "$perms" != "600" && "$perms" != "640" ]]; then
                echo "[ERROR] Insecure permissions on $token_file: $perms. Must be 600 or 640." >&2
                ((errors++))
            fi
        fi
    done
    
    # Validate ZFS pool existence
    if ! zfs list "$PHOENIX_ZFS_LXC_POOL" >/dev/null 2>&1; then
        echo "[ERROR] ZFS pool does not exist: $PHOENIX_ZFS_LXC_POOL" >&2
        ((errors++))
    fi
    
    # Validate Portainer server IP address format
    if [[ ! "$PORTAINER_SERVER_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "[ERROR] Invalid PORTAINER_SERVER_IP format: $PORTAINER_SERVER_IP" >&2
        ((errors++))
    fi
    
    # Validate Portainer server port range
    if [[ ! "$PORTAINER_SERVER_PORT" =~ ^[0-9]+$ ]] || [[ "$PORTAINER_SERVER_PORT" -lt 1 ]] || [[ "$PORTAINER_SERVER_PORT" -gt 65535 ]]; then
        echo "[ERROR] Invalid PORTAINER_SERVER_PORT: $PORTAINER_SERVER_PORT. Must be between 1 and 65535." >&2
        ((errors++))
    fi
    
    # Validate Portainer agent port range
    if [[ ! "$PORTAINER_AGENT_PORT" =~ ^[0-9]+$ ]] || [[ "$PORTAINER_AGENT_PORT" -lt 1 ]] || [[ "$PORTAINER_AGENT_PORT" -gt 65535 ]]; then
        echo "[ERROR] Invalid PORTAINER_AGENT_PORT: $PORTAINER_AGENT_PORT. Must be between 1 and 65535." >&2
        ((errors++))
    fi
    
    # Validate default LXC cores
    if [[ ! "$DEFAULT_LXC_CORES" =~ ^[1-9][0-9]*$ ]]; then
        echo "[ERROR] Invalid DEFAULT_LXC_CORES value: $DEFAULT_LXC_CORES. Must be a positive integer." >&2
        ((errors++))
    fi
    
    # Validate default LXC memory
    if [[ ! "$DEFAULT_LXC_MEMORY_MB" =~ ^[0-9]+$ ]] || [[ "$DEFAULT_LXC_MEMORY_MB" -lt 1 ]]; then
        echo "[ERROR] Invalid DEFAULT_LXC_MEMORY_MB value: $DEFAULT_LXC_MEMORY_MB. Must be a positive integer." >&2
        ((errors++))
    fi
    
    # Validate rollback flag
    if [[ "$ROLLBACK_ON_FAILURE" != "true" && "$ROLLBACK_ON_FAILURE" != "false" ]]; then
        echo "[ERROR] Invalid ROLLBACK_ON_FAILURE value: $ROLLBACK_ON_FAILURE. Must be 'true' or 'false'." >&2
        ((errors++))
    fi
    
    # Validate debug mode flag
    if [[ "$DEBUG_MODE" != "true" && "$DEBUG_MODE" != "false" ]]; then
        echo "[ERROR] Invalid DEBUG_MODE value: $DEBUG_MODE. Must be 'true' or 'false'." >&2
        ((errors++))
    fi
    
    # If validation errors found, exit with error code
    if [[ $errors -gt 0 ]]; then
        echo "[ERROR] Configuration validation failed with $errors error(s). Please check the settings above." >&2
        exit 1
    fi
    
    # Log successful validation
    echo "[INFO] Configuration validation passed successfully"
}

# Run validation if not in debug mode
if [[ "$DEBUG_MODE" == "true" ]]; then
    echo "[DEBUG] Skipping configuration validation in debug mode"
else
    validate_config
fi

# Signal that this configuration file has been loaded
export PHOENIX_HYPERVISOR_CONFIG_LOADED=1

# Note: For advanced automation, consider integrating with Proxmox VE API (pveum/pvesh) to validate resources (e.g., storage, network) dynamically.