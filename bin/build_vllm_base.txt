#!/usr/bin/env bash

# build_vllm_base.sh
#
# Builds the vllm-vllm-base Docker image and pushes it to the local DrSwarm registry.
# Intended to be run on the Proxmox host.
#
# Version: 1.0.0

set -euo pipefail

# --- Configuration ---
# Image names and tags
IMAGE_NAME="vllm-vllm-base"
LOCAL_TAG="latest"
REGISTRY_ADDRESS="10.0.0.99:5000"
REGISTRY_TAG="$REGISTRY_ADDRESS/$IMAGE_NAME:$LOCAL_TAG"

# Temporary build directory (relative to script location)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_BUILD_DIR="$SCRIPT_DIR/_temp_build"

# Dockerfile content (as a variable)
read -r -d '' DOCKERFILE_CONTENT <<'EOF_DOCKERFILE'
# Use an official NVIDIA CUDA runtime base image
# Ensure this matches the CUDA version used in your LXC containers (e.g., 12.8)
FROM nvidia/cuda:12.8.0-runtime-ubuntu24.04

# Avoid prompts from apt
ENV DEBIAN_FRONTEND=noninteractive

# Install Python and pip
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        # vLLM often needs build deps for some packages, especially on first install
        build-essential \
        # Git might be needed if installing from source or private repos
        git \
        # Curl for downloading models or other assets if needed
        curl && \
    rm -rf /var/lib/apt/lists/*

# Upgrade pip
RUN pip3 install --no-cache-dir --upgrade pip

# Install vLLM
# Using the latest version compatible with CUDA 12.8.
# Check https://docs.vllm.ai/en/latest/getting_started/installation.html
# and https://pypi.org/project/vllm/#files for compatibility.
# Installing with CUDA 12.4 support, which is often compatible with 12.8.
RUN pip3 install --no-cache-dir vllm

# Create a non-root user for better security (optional but recommended)
# RUN useradd --create-home --shell /bin/bash appuser
# USER appuser
# WORKDIR /home/appuser

# Expose the default vLLM API port
EXPOSE 8000

# Define a default command (this will likely be overridden when running the container)
# This just shows the help for the vLLM OpenAI API server as a placeholder.
CMD ["python3", "-m", "vllm.entrypoints.openai.api_server", "--help"]

EOF_DOCKERFILE

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

# --- Main Execution ---
main() {
    log_info "Starting build for $IMAGE_NAME:$LOCAL_TAG..."

    # 1. Create temporary build directory
    log_info "Creating temporary build directory: $TEMP_BUILD_DIR"
    mkdir -p "$TEMP_BUILD_DIR"

    # 2. Write Dockerfile content to the temporary directory
    log_info "Writing Dockerfile to $TEMP_BUILD_DIR/Dockerfile"
    echo "$DOCKERFILE_CONTENT" > "$TEMP_BUILD_DIR/Dockerfile"

    # 3. Build the Docker image locally
    log_info "Building Docker image $IMAGE_NAME:$LOCAL_TAG..."
    if ! docker build -t "$IMAGE_NAME:$LOCAL_TAG" "$TEMP_BUILD_DIR"; then
        log_error "Docker build failed."
    fi

    # 4. Tag the image for the local registry
    log_info "Tagging image as $REGISTRY_TAG..."
    if ! docker tag "$IMAGE_NAME:$LOCAL_TAG" "$REGISTRY_TAG"; then
        log_error "Failed to tag image."
    fi

    # 5. Push the image to the local registry
    log_info "Pushing image $REGISTRY_TAG to registry at $REGISTRY_ADDRESS..."
    if ! docker push "$REGISTRY_TAG"; then
        log_error "Failed to push image to registry."
    fi

    # 6. Cleanup temporary build directory
    log_info "Cleaning up temporary build directory: $TEMP_BUILD_DIR"
    rm -rf "$TEMP_BUILD_DIR"

    log_info "Successfully built and pushed $REGISTRY_TAG"
    log_info "You can now pull this image in your LXC containers using:"
    log_info "  pull_from_swarm_registry <lxc_id> $IMAGE_NAME:$LOCAL_TAG"
}

# Run the main function
main "$@"
