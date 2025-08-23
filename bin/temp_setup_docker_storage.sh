#!/usr/bin/env bash

# temp_setup_docker_storage.sh
#
# Sets up the shared directory structure for Phoenix Hypervisor Docker image builds.
# Intended to be run on the Proxmox host.
#
# Version: 1.0.0

set -euo pipefail

# --- Configuration ---
# Base shared data directory on Proxmox (adjust if your path is different)
SHARED_BULK_BASE="/mnt/pve/shared-bulk-data"
# Main directory for Docker image related files
PHOENIX_DOCKER_DIR="$SHARED_BULK_BASE/phoenix_docker_images"
# Subdirectories for specific image builds
VLLM_IMAGE_DIR="$PHOENIX_DOCKER_DIR/vllm-vllm-base"
LLAMACPP_IMAGE_DIR="$PHOENIX_DOCKER_DIR/llamacpp-base"

# Desired ownership (user:group)
OWNER_USER="root"
OWNER_GROUP="root"
# Desired permissions (octal)
DIR_PERMISSIONS="755"

# --- Functions ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_info() {
    log "[INFO] $*"
}

log_warn() {
    log "[WARN] $*" >&2
}

log_error() {
    log "[ERROR] $*" >&2
    exit 1
}

# Function to check and set directory ownership and permissions
check_and_set_perms() {
    local dir_path="$1"
    local expected_user="$2"
    local expected_group="$3"
    local expected_perms="$4" # Octal string e.g., "755"

    # Check if directory exists
    if [[ ! -d "$dir_path" ]]; then
        log_info "Directory '$dir_path' does not exist. Creating..."
        mkdir -p "$dir_path" || log_error "Failed to create directory '$dir_path'."
    fi

    # Get current ownership and permissions
    # stat -c '%U:%G' for user:group, stat -c '%a' for octal permissions
    local current_user
    local current_group
    local current_perms
    current_user=$(stat -c '%U' "$dir_path")
    current_group=$(stat -c '%G' "$dir_path")
    current_perms=$(stat -c '%a' "$dir_path")

    local needs_change=0

    # Check ownership
    if [[ "$current_user" != "$expected_user" ]] || [[ "$current_group" != "$expected_group" ]]; then
        log_info "Ownership for '$dir_path' is $current_user:$current_group, expected $expected_user:$expected_group. Changing..."
        chown "$expected_user:$expected_group" "$dir_path" || log_error "Failed to change ownership of '$dir_path' to $expected_user:$expected_group."
        needs_change=1
    fi

    # Check permissions
    if [[ "$current_perms" != "$expected_perms" ]]; then
        log_info "Permissions for '$dir_path' are $current_perms, expected $expected_perms. Changing..."
        chmod "$expected_perms" "$dir_path" || log_error "Failed to change permissions of '$dir_path' to $expected_perms."
        needs_change=1
    fi

    if [[ $needs_change -eq 0 ]]; then
        log_info "Directory '$dir_path' exists with correct ownership ($expected_user:$expected_group) and permissions ($expected_perms)."
    else
        log_info "Directory '$dir_path' ownership/permissions updated."
    fi
}

# --- Main Execution ---
main() {
    log_info "Starting Phoenix Hypervisor Docker Storage Setup..."

    # Validate base shared directory exists
    if [[ ! -d "$SHARED_BULK_BASE" ]]; then
        log_error "Base shared directory '$SHARED_BULK_BASE' does not exist. Please check your Proxmox storage configuration."
    fi

    # Check and set permissions for the main Docker directory
    check_and_set_perms "$PHOENIX_DOCKER_DIR" "$OWNER_USER" "$OWNER_GROUP" "$DIR_PERMISSIONS"

    # Check and set permissions for vLLM image directory
    check_and_set_perms "$VLLM_IMAGE_DIR" "$OWNER_USER" "$OWNER_GROUP" "$DIR_PERMISSIONS"

    # Check and set permissions for Llama.cpp image directory
    check_and_set_perms "$LLAMACPP_IMAGE_DIR" "$OWNER_USER" "$OWNER_GROUP" "$DIR_PERMISSIONS"

    log_info "Phoenix Hypervisor Docker Storage Setup completed successfully."
    log_info "Directories:"
    log_info "  - Main: $PHOENIX_DOCKER_DIR"
    log_info "  - vLLM Base Image: $VLLM_IMAGE_DIR"
    log_info "  - Llama.cpp Base Image: $LLAMACPP_IMAGE_DIR"
}

# Run the main function
main "$@"
