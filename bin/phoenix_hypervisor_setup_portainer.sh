#!/usr/bin/env bash

# phoenix_hypervisor_setup_portainer.sh
#
# Script to set up Portainer server or agent in LXC containers for Phoenix Hypervisor.
# Configures Portainer server in container 999 and agents in GPU-enabled containers (e.g., 900, 901, 902).
# Version: 2.0.0 (Updated for Ubuntu 24.04, portainer_role, unprivileged containers)
# Requires: pct, jq, bash, phoenix_hypervisor_common.sh
# Assumes: /usr/local/etc/phoenix_hypervisor_config.txt and /usr/local/etc/phoenix_lxc_configs.json exist

set -euo pipefail

# --- Argument Parsing ---
if [[ $# -ne 1 ]]; then
    echo "[ERROR] Usage: $0 <container_id>" >&2
    exit 1
fi
container_id="$1"

# Validate container ID is numeric
if ! [[ "$container_id" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] Invalid container ID: $container_id. Must be numeric." >&2
    exit 1
fi

# --- Logging Setup ---
PHOENIX_PORTAINER_LOG_DIR="/var/log/phoenix_hypervisor"
PHOENIX_PORTAINER_LOG_FILE="$PHOENIX_PORTAINER_LOG_DIR/phoenix_hypervisor_setup_portainer.log"

mkdir -p "$PHOENIX_PORTAINER_LOG_DIR" 2>/dev/null || {
    PHOENIX_PORTAINER_LOG_DIR="/tmp"
    PHOENIX_PORTAINER_LOG_FILE="$PHOENIX_PORTAINER_LOG_DIR/phoenix_hypervisor_setup_portainer.log"
}
touch "$PHOENIX_PORTAINER_LOG_FILE" 2>/dev/null || true
chmod 644 "$PHOENIX_PORTAINER_LOG_FILE" 2>/dev/null || true

# Use logging functions from phoenix_hypervisor_common.sh or fallbacks
if declare -F log_info >/dev/null 2>&1; then
    : # Logging functions already sourced
else
    log_info() {
        local message="$1"
        local timestamp
        timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
        echo "[$timestamp] [INFO] $message" | tee -a "$PHOENIX_PORTAINER_LOG_FILE" >&2
    }
    log_warn() {
        local message="$1"
        local timestamp
        timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
        echo "[$timestamp] [WARN] $message" | tee -a "$PHOENIX_PORTAINER_LOG_FILE" >&2
    }
    log_error() {
        local message="$1"
        local timestamp
        timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
        echo "[$timestamp] [ERROR] $message" | tee -a "$PHOENIX_PORTAINER_LOG_FILE" >&2
        exit 1
    }
fi

# --- Terminal Handling ---
trap '
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script terminated unexpectedly with exit code $exit_code. Check logs at $PHOENIX_PORTAINER_LOG_FILE"
    fi
    stty sane 2>/dev/null || true
    echo "Terminal reset (phoenix_hypervisor_setup_portainer.sh)" >&2
    exit $exit_code
' EXIT

# --- Sourcing Configuration ---
if [[ -f "/usr/local/etc/phoenix_hypervisor_config.txt" ]]; then
    source /usr/local/etc/phoenix_hypervisor_config.txt
    log_info "Sourced configuration from /usr/local/etc/phoenix_hypervisor_config.txt"
else
    log_error "Configuration file not found: /usr/local/etc/phoenix_hypervisor_config.txt"
fi

# Source common functions
if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh
elif [[ -f "./phoenix_hypervisor_common.sh" ]]; then
    source ./phoenix_hypervisor_common.sh
    log_warn "Sourced common functions from current directory. Prefer /usr/local/lib/phoenix_hypervisor/."
else
    log_error "Common functions file not found: /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh"
fi

# --- Validate Container ---
log_info "Validating container $container_id..."
if ! pct status "$container_id" >/dev/null 2>&1; then
    log_error "Container $container_id does not exist or is not running."
fi
status=$(pct status "$container_id" 2>/dev/null)
if [[ "$status" != "status: running" ]]; then
    log_error "Container $container_id is not running (status: $status)."
fi

# --- Check Portainer Role ---
config_file="${PHOENIX_LXC_CONFIG_FILE:-/usr/local/etc/phoenix_lxc_configs.json}"
if [[ ! -f "$config_file" ]]; then
    log_error "Configuration file $config_file not found."
fi

portainer_role=$(jq -r ".lxc_configs.\"$container_id\".portainer_role // \"none\"" "$config_file")
if [[ "$portainer_role" == "none" ]]; then
    log_error "Container $container_id has no Portainer role defined (portainer_role: none)."
fi

# Get container IP for accessibility check
container_ip=$(jq -r ".lxc_configs.\"$container_id\".network_config.ip" "$config_file" | cut -d'/' -f1)
if [[ -z "$container_ip" || "$container_ip" == "null" ]]; then
    log_error "Failed to retrieve IP address for container $container_id from $config_file."
fi

# --- Install Docker ---
log_info "Checking Docker installation in container $container_id..."
if declare -F install_docker_ce_in_container >/dev/null 2>&1; then
    # Check if Docker is already installed
    if pct exec "$container_id" -- bash -c "command -v docker >/dev/null 2>&1"; then
        log_info "Docker already installed in container $container_id."
    else
        if ! install_docker_ce_in_container "$container_id"; then
            log_error "Failed to install Docker in container $container_id."
        fi
        log_info "Docker installed successfully in container $container_id."
    fi
else
    log_error "Required function 'install_docker_ce_in_container' not found."
fi

# --- Authenticate with Docker Hub ---
log_info "Authenticating with Docker Hub for container $container_id..."
if declare -F authenticate_registry >/dev/null 2>&1; then
    if ! authenticate_registry "$container_id"; then
        log_error "Failed to authenticate with Docker Hub for container $container_id."
    fi
else
    log_error "Required function 'authenticate_registry' not found."
fi
log_info "Successfully authenticated with Docker Hub."

# --- Configure Portainer ---
if [[ "$portainer_role" == "server" ]]; then
    # Portainer server setup for container 999
    log_info "Setting up Portainer server in container $container_id..."
    portainer_port=${PORTAINER_SERVER_PORT:-9443}
    portainer_image="portainer/portainer-ce:latest"
    portainer_name="portainer_server"

    # Pull and run Portainer server
    if ! retry_command 3 10 pct exec "$container_id" -- bash -c "export LC_ALL=C.UTF-8 LANG=C.UTF-8; docker pull $portainer_image && docker run -d -p $portainer_port:9443 --name $portainer_name --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data $portainer_image"; then
        log_error "Failed to pull or run Portainer server in container $container_id."
    fi
    log_info "Portainer server container started successfully."

    # Verify Portainer server
    max_attempts=5
    attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Verifying Portainer server in container $container_id (attempt $attempt/$max_attempts)..."
        if pct exec "$container_id" -- bash -c "export LC_ALL=C.UTF-8 LANG=C.UTF-8; docker ps -q -f name=$portainer_name | grep -q ."; then
            log_info "Portainer server is running in container $container_id."
            break
        else
            log_warn "Portainer server not yet running in container $container_id. Retrying in 5 seconds..."
            sleep 5
            ((attempt++))
        fi
    done
    if [[ $attempt -gt $max_attempts ]]; then
        log_error "Portainer server failed to start in container $container_id after $max_attempts attempts."
    fi

    # Verify Portainer accessibility
    if command -v nc >/dev/null 2>&1; then
        if ! nc -z "$container_ip" "$portainer_port" 2>/dev/null; then
            log_warn "Portainer server port $portainer_port on $container_ip is not reachable. Ensure firewall rules allow access."
        else
            log_info "Portainer server port $portainer_port on $container_ip is reachable."
        fi
    else
        log_warn "netcat not installed, skipping Portainer port accessibility check."
    fi

    log_info "Portainer server setup completed successfully in container $container_id."
    log_info "Access Portainer at: https://$container_ip:$portainer_port"

elif [[ "$portainer_role" == "agent" ]]; then
    # Portainer agent setup for GPU containers (e.g., 900, 901, 902)
    log_info "Setting up Portainer agent in container $container_id..."
    portainer_agent_port=${PORTAINER_AGENT_PORT:-9001}
    portainer_image="portainer/agent:latest"
    portainer_name="portainer_agent"
    portainer_server_ip=$(jq -r '.lxc_configs."999".network_config.ip' "$config_file" | cut -d'/' -f1)
    if [[ -z "$portainer_server_ip" || "$portainer_server_ip" == "null" ]]; then
        log_error "Failed to retrieve Portainer server IP from $config_file for container 999."
    fi

    # Ensure Docker service is running
    if declare -F start_systemd_service_in_container >/dev/null 2>&1; then
        if ! start_systemd_service_in_container "$container_id" docker; then
            log_error "Failed to start Docker service in container $container_id."
        fi
    else
        log_error "Required function 'start_systemd_service_in_container' not found."
    fi

    # Pull and run Portainer agent
    if ! retry_command 3 10 pct exec "$container_id" -- bash -c "export LC_ALL=C.UTF-8 LANG=C.UTF-8; docker pull $portainer_image && docker run -d -p $portainer_agent_port:9001 --name $portainer_name --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v /:/host --env AGENT_CLUSTER_ADDR=$container_ip --env AGENT_PORT=$portainer_agent_port $portainer_image"; then
        log_error "Failed to pull or run Portainer agent in container $container_id."
    fi
    log_info "Portainer agent container started successfully."

    # Verify Portainer agent
    max_attempts=5
    attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Verifying Portainer agent in container $container_id (attempt $attempt/$max_attempts)..."
        if pct exec "$container_id" -- bash -c "export LC_ALL=C.UTF-8 LANG=C.UTF-8; docker ps -q -f name=$portainer_name | grep -q ."; then
            log_info "Portainer agent is running in container $container_id."
            break
        else
            log_warn "Portainer agent not yet running in container $container_id. Retrying in 5 seconds..."
            sleep 5
            ((attempt++))
        fi
    done
    if [[ $attempt -gt $max_attempts ]]; then
        log_error "Portainer agent failed to start in container $container_id after $max_attempts attempts."
    fi

    # Verify agent connectivity to server
    if command -v nc >/dev/null 2>&1; then
        if ! nc -z "$container_ip" "$portainer_agent_port" 2>/dev/null; then
            log_warn "Portainer agent port $portainer_agent_port on $container_ip is not reachable. Ensure firewall rules allow access."
        else
            log_info "Portainer agent port $portainer_agent_port on $container_ip is reachable."
        fi
    else
        log_warn "netcat not installed, skipping Portainer agent port accessibility check."
    fi

    log_info "Portainer agent setup completed successfully in container $container_id."
    log_info "Agent should connect to Portainer server at https://$portainer_server_ip:9443"
else
    log_error "Invalid portainer_role '$portainer_role' for container $container_id. Expected 'server' or 'agent'."
fi

# --- Finalize ---
log_info "Portainer setup completed successfully for container $container_id."
exit 0