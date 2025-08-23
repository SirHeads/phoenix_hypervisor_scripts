# Use an official NVIDIA CUDA runtime base image
# Ensure this matches the CUDA version used in your LXC containers (e.g., 12.8)
# Using devel for potential build dependencies within the container context if needed later,
# though runtime might suffice if binaries are built externally and copied. Let's start with runtime.
FROM nvidia/cuda:12.8.0-runtime-ubuntu24.04

# Avoid prompts from apt
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies and tools
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    python3 \
    python3-pip \
    wget \
    curl \
    vim \
    htop \
    # For potential Python bindings or scripts
    pkg-config && \
    rm -rf /var/lib/apt/lists/*

# Upgrade pip
RUN pip3 install --no-cache-dir --upgrade pip

# Set working directory
WORKDIR /opt/ai

# Clone the llama.cpp repository
# It's good practice to pin a specific commit or tag for reproducibility
# As of late August 2025, a recent stable-ish commit is used.
# Check https://github.com/ggerganov/llama.cpp for the latest recommended stable tag/commit.
RUN git clone https://github.com/ggerganov/llama.cpp.git && \
    cd llama.cpp && \
    # Example: Pinning to a specific commit (replace with a relevant recent one)
    # git checkout b43a... (actual commit hash)
    git checkout master && \
    # Optionally, if you want to be very specific about the version at build time:
    # echo "Cloned llama.cpp at commit: $(git rev-parse HEAD)" > /opt/ai/llama.cpp.version.info

    # Build llama.cpp binaries with CUDA support
    # Navigate into the cloned directory and run make
    # LLAMA_CUDA=1 enables CUDA acceleration during the build
    RUN cd /opt/ai/llama.cpp && \
    make clean && \
    LLAMA_CUDA=1 make -j$(nproc) && \
    # Verify key binaries are built
    ls -l bin/

# (Optional) Install Python bindings for llama-cpp-python (if needed)
# This requires building from source to enable CUDA support typically.
# Uncomment the following lines if you plan to use Python bindings extensively.
# Note: This can significantly increase build time and image size.
# ENV LLVM_VERSION=16
# RUN apt-get update && \
#     apt-get install -y --no-install-recommends \
#         llvm-$LLVM_VERSION-dev \
#         clang-$LLVM_VERSION && \
#     rm -rf /var/lib/apt/lists/* && \
#     ln -s /usr/bin/llvm-config-$LLVM_VERSION /usr/bin/llvm-config
#
# # Install Rust if required by newer versions of llama-cpp-python
# RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
# ENV PATH="/root/.cargo/bin:${PATH}"
#
# # Install llama-cpp-python with CUDA support
# RUN cd /opt/ai/llama.cpp && \
#     CMAKE_ARGS="-DLLAMA_CUDA=on" pip3 install --no-cache-dir -e .

# --- Standard Configuration for Serving ---
# Create a non-root user for better security (recommended)
RUN useradd --create-home --shell /bin/bash --uid 1000 aiuser && \
    chown -R aiuser:aiuser /opt/ai

# Switch to the non-root user
USER aiuser
WORKDIR /home/aiuser

# Expose the default port that llama-server might use
EXPOSE 8080

# Define a default command
# This example just shows the help for llama-server.
# In practice, you would override this when running the container
# to specify a model file and other serving options.
# Example run command (not part of Dockerfile):
# docker run --gpus all -p 8080:8080 YOUR_REGISTRY/llamacpp-base:latest \
#   --model /path/to/model.gguf --host 0.0.0.0 --port 8080
CMD ["/opt/ai/llama.cpp/bin/llama-server", "--help"]
