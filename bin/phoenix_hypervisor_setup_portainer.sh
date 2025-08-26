```bash
#!/usr/bin/env bash

# phoenix_hypervisor_setup_portainer.sh
#
# Script to set up Portainer server or agent in LXC containers for Phoenix Hypervisor.
# Configures Portainer server in container 999 and agents in GPU-enabled containers (e.g., 900, 901, 902).
# Version: 2.0.1 (Added install_portainer_agent, QUIET_MODE, config.sh, token permissions, JSON retries)
# Requires: pct, jq, bash, phoenix_hypervisor_common.sh
# Assumes: /usr/local/etc/phoenix_hypervisor_config.sh and /usr/local/etc/phoenix_lxc_configs.json exist

set -euo pipefail

# --- Argument Parsing ---
if [[ $# -ne 1 ]]; then
    log_error "Usage: $0 <container_id>"
    exit 1
fi
container_id="$1"

# Validate container ID is numeric
if ! [[ "$container_id" =~ ^[0-9]+$ ]]; then
    log_error "Invalid container ID: $container_id. Must be numeric."
    exit 1
fi

# --- Quiet Mode Check ---
QUIET_MODE="${QUIET_MODE:-false}"
log_debug "Starting Portainer setup for container $container_id. QUIET_MODE=$QUIET_MODE"

# --- Logging Setup ---
PHOENIX_PORTAINER_LOG_DIR="/var/log/phoenix_hypervisor"
PHOENIX_PORTAINER_LOG_FILE="$PHOENIX_PORTAINER_LOG_DIR/phoenix_hypervisor_setup_portainer.log"

mkdir -p "$PHOENIX_PORTAINER_LOG_DIR" 2>>"$PHOENIX_PORTAINER_LOG_FILE" || {
    PHOENIX_PORTAINER_LOG_DIR="/tmp"
    PHOENIX_PORTAINER_LOG_FILE="$PHOENIX_PORTAINER_LOG_DIR/phoenix_hypervisor_setup_portainer.log"
}
touch "$PHOENIX_PORTAINER_LOG_FILE" 2>/dev/null || true
chmod 640 "$PHOENIX_PORTAINER_LOG_FILE" 2>/dev/null || true

# --- Sourcing Configuration ---
if [[ -f "/usr/local/etc/phoenix_hypervisor_config.sh" ]]; then
    source /usr/local/etc/phoenix_hypervisor_config.sh
    log_info "Sourced configuration from /usr/local/etc/phoenix_hypervisor_config.sh"
elif [[ -f "./phoenix_hypervisor_config.sh" ]]; then
    source ./phoenix_hypervisor_config.sh
    log_warn "Sourced configuration from current directory. Prefer /usr/local/etc/phoenix_hypervisor_config.sh."
else
    log_error "Configuration file not found: /usr/local/etc/phoenix_hypervisor_config.sh"
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

# --- Terminal Handling ---
trap '
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script terminated unexpectedly with exit code $exit_code. Check logs at $PHOENIX_PORTAINER_LOG_FILE"
    fi
    stty sane 2>/dev/null || true
    if [[ "$QUIET_MODE" != "true" ]]; then
        echo "Terminal reset (phoenix_hypervisor_setup_portainer.sh)" >&2
    fi
    exit $exit_code
' EXIT

# --- Validate Container ---
log_info "Validating container $container_id..."
if ! validate_container_status "$container_id"; then
    log_error "Container $container_id is not running or does not exist."
fi

# --- Check Portainer Role and Configuration ---
config_file="${PHOENIX_LXC_CONFIG_FILE:-/usr/local/etc/phoenix_lxc_configs.json}"
if [[ ! -f "$config_file" ]]; then
    log_error "Configuration file $config_file not found."
fi

if ! retry_command 3 5 jq -r ".lxc_configs.\"$container_id\".portainer_role // \"none\"" "$config_file"; then
    log_error "Failed to read portainer_role from $config_file for container $container_id."
fi
portainer_role=$(jq -r ".lxc_configs.\"$container_id\".portainer_role // \"none\"" "$config_file")
if [[ "$portainer_role" == "none" ]]; then
    log_error "Container $container_id has no Portainer role defined (portainer_role: none)."
fi

container_ip=$(jq -r ".lxc_configs.\"$container_id\".network_config.ip" "$config_file" | cut -d'/' -f1)
if [[ -z "$container_ip" || "$container_ip" == "null" ]]; then
    log_error "Failed to retrieve IP address for container $container_id from $config_file."
fi

# --- Install Docker ---
log_info "Checking Docker installation in container $container_id..."
if declare -F install_docker_ce_in_container >/dev/null 2>&1; then
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
authenticate_registry() {
    local lxc_id="$1"
    log_info "Authenticating with Docker Hub for container $lxc_id..."
    if [[ ! -f "$PHOENIX_DOCKER_TOKEN_FILE" ]]; then
        log_error "Docker token file missing: $PHOENIX_DOCKER_TOKEN_FILE"
    fi
    if [[ ! -r "$PHOENIX_DOCKER_TOKEN_FILE" ]]; then
        log_error "Docker token file not readable: $PHOENIX_DOCKER_TOKEN_FILE"
    fi
    local permissions
    permissions=$(stat -c "%a" "$PHOENIX_DOCKER_TOKEN_FILE")
    if [[ "$permissions" != "600" ]]; then
        log_warn "Insecure permissions on $PHOENIX_DOCKER_TOKEN_FILE ($permissions). Setting to 600."
        chmod 600 "$PHOENIX_DOCKER_TOKEN_FILE" || log_error "Failed to set permissions on $PHOENIX_DOCKER_TOKEN_FILE"
    fi
    local docker_token
    docker_token=$(cat "$PHOENIX_DOCKER_TOKEN_FILE")
    if ! retry_command 3 5 pct exec "$lxc_id" -- bash -c "echo \"$docker_token\" | docker login -u phoenix --password-stdin"; then
        log_error "Failed to authenticate with Docker Hub for container $lxc_id."
    fi
    log_info "Successfully authenticated with Docker Hub."
}

log_info "Authenticating with Docker Hub for container $container_id..."
if ! authenticate_registry "$container_id"; then
    log_error "Failed to authenticate with Docker Hub for container $container_id."
fi

# --- Install Portainer Agent ---
install_portainer_agent() {
    local lxc_id="$1"
    log_info "Setting up Portainer agent in container $lxc_id..."
    local portainer_agent_port portainer_image portainer_name portainer_server_ip

    portainer_agent_port=$(jq -r ".lxc_configs.\"$lxc_id\".portainer_agent_port // \"9001\"" "$config_file")
    if [[ -z "$portainer_agent_port" || "$portainer_agent_port" == "null" ]]; then
        log_info "No portainer_agent_port defined for container $lxc_id. Defaulting to 9001."
        portainer_agent_port="9001"
    fi
    portainer_image=$(jq -r ".lxc_configs.\"$lxc_id\".portainer_image // \"portainer/agent:latest\"" "$config_file")
    portainer_name="portainer_agent"
    portainer_server_ip=$(jq -r '.lxc_configs."999".network_config.ip' "$config_file" | cut -d'/' -f1)
    if [[ -z "$portainer_server_ip" || "$portainer_server_ip" == "null" ]]; then
        log_error "Failed to retrieve Portainer server IP from $config_file for container 999."
    fi

    if declare -F start_systemd_service_in_container >/dev/null 2>&1; then
        if ! start_systemd_service_in_container "$lxc_id" docker; then
            log_error "Failed to start Docker service in container $lxc_id."
        fi
    else
        log_error "Required function 'start_systemd_service_in_container' not found."
    fi

    if ! retry_command 3 10 pct exec "$lxc_id" -- bash -c "export LC_ALL=C.UTF-8 LANG=C.UTF-8; docker pull $portainer_image && docker run -d -p $portainer_agent_port:9001 --name $portainer_name --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v /:/host --env AGENT_CLUSTER_ADDR=$container_ip --env AGENT_PORT=$portainer_agent_port $portainer_image"; then
        log_error "Failed to pull or run Portainer agent in container $lxc_id."
    fi
    log_info "Portainer agent container started successfully."

    max_attempts=5
    attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Verifying Portainer agent in container $lxc_id (attempt $attempt/$max_attempts)..."
        if pct exec "$lxc_id" -- bash -c "export LC_ALL=C.UTF-8 LANG=C.UTF-8; docker ps -q -f name=$portainer_name | grep -q ."; then
            log_info "Portainer agent is running in container $lxc_id."
            break
        else
            log_warn "Portainer agent not yet running in container $lxc_id. Retrying in 5 seconds..."
            sleep 5
            ((attempt++))
        fi
    done
    if [[ $attempt -gt $max_attempts ]]; then
        log_error "Portainer agent failed to start in container $lxc_id after $max_attempts attempts."
    fi

    if command -v nc >/dev/null 2>&1; then
        if ! nc -z "$container_ip" "$portainer_agent_port" 2>/dev/null; then
            log_warn "Portainer agent port $portainer_agent_port on $container_ip is not reachable. Ensure firewall rules allow access."
        else
            log_info "Portainer agent port $portainer_agent_port on $container_ip is reachable."
        fi
    else
        log_warn "netcat not installed, skipping Portainer agent port accessibility check."
    fi

    log_info "Portainer agent setup completed successfully in container $lxc_id."
    if [[ "$QUIET_MODE" != "true" ]]; then
        echo "Agent should connect to Portainer server at https://$portainer_server_ip:9443" >&2
    fi
}

# --- Configure Portainer ---
if [[ "$portainer_role" == "server" ]]; then
    log_info "Setting up Portainer server in container $container_id..."
    local portainer_port portainer_image portainer_name
    portainer_port=$(jq -r ".lxc_configs.\"$container_id\".portainer_port // \"9443\"" "$config_file")
    if [[ -z "$portainer_port" || "$portainer_port" == "null" ]]; then
        log_info "No portainer_port defined for container $container_id. Defaulting to 9443."
        portainer_port="9443"
    fi
    portainer_image=$(jq -r ".lxc_configs.\"$container_id\".portainer_image // \"portainer/portainer-ce:latest\"" "$config_file")
    portainer_name="portainer_server"

    if ! retry_command 3 10 pct exec "$container_id" -- bash -c "export LC_ALL=C.UTF-8 LANG=C.UTF-8; docker pull $portainer_image && docker run -d -p $portainer_port:9443 --name $portainer_name --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data $portainer_image"; then
        log_error "Failed to pull or run Portainer server in container $container_id."
    fi
    log_info "Portainer server container started successfully."

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

    if ! validate_portainer_network_in_container "$container_id"; then
        log_error "Portainer server network validation failed for container $container_id."
    fi

    if [[ "$QUIET_MODE" != "true" ]]; then
        echo "Portainer server setup completed successfully in container $container_id." >&2
        echo "Access Portainer at: https://$container_ip:$portainer_port" >&2
    fi

elif [[ "$portainer_role" == "agent" ]]; then
    install_portainer_agent "$container_id"
else
    log_error "Invalid portainer_role '$portainer_role' for container $container_id. Expected 'server' or 'agent'."
fi

# --- Finalize ---
log_info "Portainer setup completed successfully for container $container_id."
if [[ "$QUIET_MODE" != "true" ]]; then
    echo "Portainer setup completed successfully for container $container_id." >&2
fi
exit 0
```