#!/usr/bin/env bash

# phoenix_hypervisor_lxc_common_swarmpull.sh
#
# Common functions for integrating LXC containers with the DrSwarm (Docker Swarm Manager & Registry).
# This script is intended to be sourced by other Phoenix Hypervisor scripts, specifically
# the setup scripts for GPU containers (e.g., phoenix_hypervisor_setup_drcuda.sh).
#
# Requires: pct, bash, standard Unix tools
# Assumes: phoenix_hypervisor_common.sh is sourced for logging (fallbacks included)
# Assumes: phoenix_hypervisor_lxc_common_base.sh is sourced for pct_exec_with_retry
# Version: 1.0.0 (Initial for Project Requirements)
# Author: Assistant

# --- Registry Integration ---

# Configure the Docker daemon inside an LXC container to trust the local DrSwarm registry.
# This modifies /etc/docker/daemon.json inside the container.
# Usage: configure_local_registry_trust <container_id> <registry_address>
# Example: configure_local_registry_trust 900 10.0.0.99:5000
configure_local_registry_trust() {
    local lxc_id="$1"
    local registry_address="$2" # Expected format: IP:PORT or HOSTNAME:PORT

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    fi

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    # Use log_warn if available, otherwise fallback
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" >&2; }
    fi

    if [[ -z "$lxc_id" ]] || [[ -z "$registry_address" ]]; then
        "$error_func" "configure_local_registry_trust: Missing lxc_id or registry_address"
        return 1
    fi

    "$log_func" "configure_local_registry_trust: Configuring trust for registry $registry_address in container $lxc_id..."

    # Command to check/add registry trust
    local trust_cmd="set -e
    export LC_ALL=C
    echo '[INFO] Checking current Docker daemon configuration...'
    DAEMON_JSON='/etc/docker/daemon.json'
    # Ensure the directory exists
    mkdir -p \"\$(dirname \"\$DAEMON_JSON\")\"
    # Create empty JSON object if file doesn't exist or is empty
    if [[ ! -f \"\$DAEMON_JSON\" ]] || [[ ! -s \"\$DAEMON_JSON\" ]]; then
        echo '{}' > \"\$DAEMON_JSON\"
        echo '[INFO] Created empty \$DAEMON_JSON'
    fi
    # Check if jq is available
    if ! command -v jq >/dev/null 2>&1; then
        echo '[ERROR] jq is required to modify daemon.json but not found.'
        exit 1
    fi
    # Check if the registry is already in the insecure-registries list
    if jq -e --arg reg '$registry_address' '.[\"insecure-registries\"] | index(\$reg)' \"\$DAEMON_JSON\" >/dev/null 2>&1; then
        echo '[INFO] Registry $registry_address already trusted in \$DAEMON_JSON.'
        exit 0
    fi
    echo '[INFO] Adding $registry_address to insecure-registries list...'
    # Read existing array or create a new one, then append the new registry
    jq --arg reg '$registry_address' '
        if has(\"insecure-registries\") and (.\"insecure-registries\" | type == \"array\") then
            .\"insecure-registries\" = (.\"insecure-registries\" + [\$reg])
        elif has(\"insecure-registries\") then
            .\"insecure-registries\" = [.\"insecure-registries\", \$reg]
        else
            .\"insecure-registries\" = [\$reg]
        end
    ' \"\$DAEMON_JSON\" > \"\${DAEMON_JSON}.tmp\" && mv \"\${DAEMON_JSON}.tmp\" \"\$DAEMON_JSON\"
    echo '[INFO] Current daemon.json contents:'
    cat \"\$DAEMON_JSON\"
    echo '[SUCCESS] Registry $registry_address added to \$DAEMON_JSON.'
    "

    # Use pct_exec_with_retry if available, otherwise direct exec
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    if "$exec_func" "$lxc_id" -- bash -c "$trust_cmd"; then
        "$log_func" "configure_local_registry_trust: Trust configured for registry $registry_address in container $lxc_id."
        # Restart Docker to apply changes
        "$log_func" "configure_local_registry_trust: Restarting Docker service in container $lxc_id to apply changes..."
        # Simple restart command, assuming systemd
        local restart_cmd="set -e
        export LC_ALL=C
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet docker; then
            systemctl restart docker > /tmp/docker-restart-trust.log 2>&1 || { echo '[ERROR] Failed to restart Docker'; cat /tmp/docker-restart-trust.log; exit 1; }
            echo '[SUCCESS] Docker service restarted.'
        elif command -v service >/dev/null 2>&1 && service docker status > /dev/null 2>&1; then
            service docker restart > /tmp/docker-restart-trust.log 2>&1 || { echo '[ERROR] Failed to restart Docker'; cat /tmp/docker-restart-trust.log; exit 1; }
            echo '[SUCCESS] Docker service restarted (via service).'
        else
            echo '[WARN] Could not determine how to restart Docker. Please restart Docker manually in the container.'
            exit 0 # Don't fail the whole function, just warn
        fi
        "
        if "$exec_func" "$lxc_id" -- bash -c "$restart_cmd"; then
            "$log_func" "configure_local_registry_trust: Docker restarted successfully in container $lxc_id."
        else
            "$warn_func" "configure_local_registry_trust: Failed to restart Docker in container $lxc_id. Changes might not take effect until Docker is restarted."
        fi
        return 0
    else
        "$error_func" "configure_local_registry_trust: Failed to configure trust for registry $registry_address in container $lxc_id."
        return 1
    fi
}

# Pull a Docker image from the local DrSwarm registry into an LXC container.
# Usage: pull_from_swarm_registry <container_id> <image_name_with_tag>
# Example: pull_from_swarm_registry 900 my-gpu-app:v1.0
pull_from_swarm_registry() {
    local lxc_id="$1"
    local image_name_tag="$2" # e.g., my-app:latest or my-app:v1.0

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    fi

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    # Use log_warn if available, otherwise fallback
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" >&2; }
    fi

    if [[ -z "$lxc_id" ]] || [[ -z "$image_name_tag" ]]; then
        "$error_func" "pull_from_swarm_registry: Missing lxc_id or image_name_tag"
        return 1
    fi

    # Determine the registry address (hardcoded based on DrSwarm config)
    # TODO: Make this configurable or discoverable if needed in the future.
    local registry_ip="10.0.0.99"
    local registry_port="5000"
    local registry_address="${registry_ip}:${registry_port}"

    "$log_func" "pull_from_swarm_registry: Pulling image $image_name_tag from registry $registry_address into container $lxc_id..."

    # Construct the full image name with registry prefix
    local full_image_name="${registry_address}/${image_name_tag}"

    # Command to pull the image
    local pull_cmd="set -e
    export LC_ALL=C
    echo '[INFO] Pulling image: $full_image_name'
    # Check if Docker is installed and running
    if ! command -v docker >/dev/null 2>&1; then
        echo '[ERROR] Docker not found in container.'
        exit 1
    fi
    # Perform the pull
    docker pull '$full_image_name' > /tmp/docker-pull.log 2>&1 || { echo '[ERROR] Failed to pull image $full_image_name'; cat /tmp/docker-pull.log; exit 1; }
    echo '[SUCCESS] Image $full_image_name pulled successfully.'
    "

    # Use pct_exec_with_retry if available, otherwise direct exec
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    if "$exec_func" "$lxc_id" -- bash -c "$pull_cmd"; then
        "$log_func" "pull_from_swarm_registry: Image $image_name_tag pulled successfully from $registry_address into container $lxc_id."
        return 0
    else
        "$error_func" "pull_from_swarm_registry: Failed to pull image $image_name_tag from $registry_address into container $lxc_id."
        return 1
    fi
}

# (Optional) Run a GPU-accelerated container using the image pulled from the registry,
# applying the necessary workarounds for LXC environments.
# Usage: run_gpu_container_via_swarm_integration <container_id> <image_name_with_tag> <container_name> [run_command]
# Example: run_gpu_container_via_swarm_integration 900 my-gpu-app:v1.0 my-job "python train.py"
run_gpu_container_via_swarm_integration() {
    local lxc_id="$1"
    local image_name_tag="$2" # e.g., my-app:latest or my-app:v1.0
    local container_name="$3" # Name for the new container instance
    local run_command="${4:-}" # Optional command to run inside the container

    # Use log_info if available, otherwise fallback
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*"; }
    fi

    # Use log_error if available, otherwise fallback
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" >&2; exit 1; }
    fi

    # Use log_warn if available, otherwise fallback
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" >&2; }
    fi

    if [[ -z "$lxc_id" ]] || [[ -z "$image_name_tag" ]] || [[ -z "$container_name" ]]; then
        "$error_func" "run_gpu_container_via_swarm_integration: Missing lxc_id, image_name_tag, or container_name"
        return 1
    fi

    # Determine the registry address (hardcoded based on DrSwarm config)
    local registry_ip="10.0.0.99"
    local registry_port="5000"
    local registry_address="${registry_ip}:${registry_port}"

    "$log_func" "run_gpu_container_via_swarm_integration: Running container '$container_name' from image $image_name_tag (registry $registry_address) in container $lxc_id..."

    # Construct the full image name with registry prefix
    local full_image_name="${registry_address}/${image_name_tag}"

    # Build the docker run command with LXC workarounds
    local docker_run_cmd="docker run -d --name '$container_name' --gpus all --security-opt apparmor=unconfined '$full_image_name'"
    if [[ -n "$run_command" ]]; then
        docker_run_cmd+=" $run_command"
    fi

    # Command to run the container
    local run_cmd="set -e
    export LC_ALL=C
    echo '[INFO] Running container with command: $docker_run_cmd'
    # Check if Docker is installed and running
    if ! command -v docker >/dev/null 2>&1; then
        echo '[ERROR] Docker not found in container.'
        exit 1
    fi
    # Perform the run
    $docker_run_cmd > /tmp/docker-run.log 2>&1 || { echo '[ERROR] Failed to run container'; cat /tmp/docker-run.log; exit 1; }
    echo '[SUCCESS] Container $container_name started successfully with command: $docker_run_cmd'
    "

    # Use pct_exec_with_retry if available, otherwise direct exec
    local exec_func="pct exec"
    if declare -F pct_exec_with_retry >/dev/null 2>&1; then
        exec_func="pct_exec_with_retry"
    fi

    if "$exec_func" "$lxc_id" -- bash -c "$run_cmd"; then
        "$log_func" "run_gpu_container_via_swarm_integration: Container '$container_name' started successfully from image $image_name_tag in container $lxc_id."
        return 0
    else
        "$error_func" "run_gpu_container_via_swarm_integration: Failed to run container '$container_name' from image $image_name_tag in container $lxc_id."
        return 1
    fi
}

echo "[INFO] phoenix_hypervisor_lxc_common_swarmpull.sh: Library loaded successfully."
