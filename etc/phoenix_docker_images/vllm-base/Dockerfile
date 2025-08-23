# Use an official NVIDIA CUDA runtime base image
# Ensure this matches the CUDA version used in your LXC containers (e.g., 12.8)
FROM nvidia/cuda:12.8.0-runtime-ubuntu24.04

# Avoid prompts from apt
ENV DEBIAN_FRONTEND=noninteractive

# Install Python, pip, and build essentials (for potential pip package builds)
# Also install git (useful for cloning models/repositories if needed)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    build-essential \
    git \
    curl && \
    rm -rf /var/lib/apt/lists/*

# Upgrade pip to the latest version
RUN pip3 install --no-cache-dir --upgrade pip

# Install vLLM
# Check https://docs.vllm.ai/en/latest/getting_started/installation.html for the latest compatible version.
# The vLLM package on PyPI usually supports CUDA 12.4, which is often compatible with 12.8.
# If you encounter issues, you might need to build from source or use a specific wheel.
# As of late August 2025, installing the latest version is common.
RUN pip3 install --no-cache-dir vllm

# (Optional) Create a non-root user for better security practices
# RUN useradd --create-home --shell /bin/bash appuser
# USER appuser
# WORKDIR /home/appuser

# Expose the default vLLM API server port
EXPOSE 8000

# Define a default command
# This example just shows the help for the vLLM OpenAI API server.
# In practice, you would likely override this when running the container
# to specify a model and other options.
# Example run command (not part of Dockerfile):
# docker run --gpus all -p 8000:8000 YOUR_REGISTRY/vllm-base:latest \
#   --model YourHuggingFaceModelName --host 0.0.0.0 --port 8000
CMD ["python3", "-m", "vllm.entrypoints.openai.api_server", "--help"]
