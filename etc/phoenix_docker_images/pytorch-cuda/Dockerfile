# Use an official NVIDIA CUDA runtime base image
# Ensure this matches the CUDA version used in your LXC containers (e.g., 12.8)
# Using devel might be necessary if building complex extensions, but runtime is often sufficient.
FROM nvidia/cuda:12.8.0-runtime-ubuntu24.04

# Avoid prompts from apt
ENV DEBIAN_FRONTEND=noninteractive

# Install Python, pip, and essential build tools
# git can be useful for cloning repositories
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-dev \ # Often needed for building Python packages
build-essential \
    git \
    curl && \
    rm -rf /var/lib/apt/lists/*

# Upgrade pip to the latest version
RUN pip3 install --no-cache-dir --upgrade pip

# Install PyTorch, TorchVision, and Torchaudio for CUDA 12.8
# As of mid-2025, PyTorch wheels for CUDA 12.4 are commonly used and compatible with CUDA 12.8.
# Check https://pytorch.org/get-started/locally/ for the latest installation command.
# We will install the latest stable versions compatible with Python 3.x and CUDA 12.4/12.8.
# Example command from PyTorch website (as of July 2025):
# pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124
# Let's use the specific index for CUDA 12.4 which is generally compatible.
RUN pip3 install --no-cache-dir \
    torch \
    torchvision \
    torchaudio \
    --index-url https://download.pytorch.org/whl/cu124

# (Optional) Install Jupyter Notebook/Lab for interactive development/testing
# Uncomment the following lines if needed.
# RUN pip3 install --no-cache-dir jupyterlab # or jupyter notebook

# (Optional) Create a non-root user for better security
# RUN useradd --create-home --shell /bin/bash --uid 1000 ptuser && \
#     chown -R ptuser:ptuser /home/ptuser
# USER ptuser
# WORKDIR /home/ptuser

# Define a default command
# This example runs a simple Python script to check CUDA availability.
# You can override this when running the container.
# Example run command (not part of Dockerfile):
# docker run --gpus all YOUR_REGISTRY/pytorch-cuda:12.8 python3 -c "import torch; print('CUDA available:', torch.cuda.is_available()); print('Number of GPUs:', torch.cuda.device_count())"
CMD ["python3", "-c", "import torch; print('PyTorch Version:', torch.__version__); print('CUDA available:', torch.cuda.is_available()); print('Number of GPUs:', torch.cuda.device_count()); print('CUDA Version:', torch.version.cuda)"]
