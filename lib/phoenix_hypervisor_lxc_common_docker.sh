#!/usr/bin/env bash
# Common functions for Docker operations inside LXC containers.
# This script is intended to be sourced by other Phoenix Hypervisor scripts.
# Requires: pct, bash, jq, standard Unix tools
# Assumes: phoenix_hypervisor_common.sh is sourced for logging/retry functions
# Assumes: phoenix_hypervisor_lxc_common_systemd.sh is sourced for systemd operations
# Assumes: phoenix_hypervisor_lxc_common_base.sh is sourced for pct_exec_with_retry
# Version: 1.1.6 (Added QUIET_MODE, dynamic GPU image tag, prerequisites function, config backup, enhanced logging)
# Author: Assistant
# Integration: Supports Portainer containers (900-902, 999) with dynamic configuration

# --- Logging Setup ---
PHOENIX_DOCKER_LOG_DIR="/var/log/phoenix_hypervisor"
PHOENIX_DOCKER_LOG_FILE="$PHOENIX_DOCKER_LOG_DIR/phoenix_hypervisor_lxc_common_docker.log"

mkdir -p "$PHOENIX_DOCKER_LOG_DIR" 2>>"$PHOENIX_DOCKER_LOG_FILE" || {
    log_warn "Failed to create $PHOENIX_DOCKER_LOG_DIR, falling back to /tmp"
    PHOENIX_DOCKER_LOG_DIR="/tmp"
    PHOENIX_DOCKER_LOG_FILE="$PHOENIX_DOCKER_LOG_DIR/phoenix_hypervisor_lxc_common_docker.log"
}
touch "$PHOENIX_DOCKER_LOG_FILE" 2>>"$PHOENIX_DOCKER_LOG_FILE" || log_warn "Failed to create $PHOENIX_DOCKER_LOG_FILE"
chmod 644 "$PHOENIX_DOCKER_LOG_FILE" 2>>"$PHOENIX_DOCKER_LOG_FILE" || log_warn "Could not set permissions to 644 on $PHOENIX_DOCKER_LOG_FILE"

# --- Source Dependencies ---
if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_common.sh
    log_info "phoenix_hypervisor_lxc_common_docker.sh: Sourced common functions."
elif [[ -f "/usr/local/bin/phoenix_hypervisor_common.sh" ]]; then
    source /usr/local/bin/phoenix_hypervisor_common.sh
    log_info "phoenix_hypervisor_lxc_common_docker.sh: Sourced common functions from /usr/local/bin/."
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] phoenix_hypervisor_lxc_common_docker.sh: Cannot find phoenix_hypervisor_common.sh" | tee -a "$PHOENIX_DOCKER_LOG_FILE" >&2
    exit 1
fi

if [[ -z "$PHOENIX_HYPERVISOR_COMMON_LOADED" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] phoenix_hypervisor_lxc_common_docker.sh: Failed to load phoenix_hypervisor_common.sh" | tee -a "$PHOENIX_DOCKER_LOG_FILE" >&2
    exit 1
fi

if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_lxc_common_base.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_lxc_common_base.sh
    log_info "phoenix_hypervisor_lxc_common_docker.sh: Sourced base functions."
elif [[ -f "/usr/local/bin/phoenix_hypervisor_lxc_common_base.sh" ]]; then
    source /usr/local/bin/phoenix_hypervisor_lxc_common_base.sh
    log_info "phoenix_hypervisor_lxc_common_docker.sh: Sourced base functions from /usr/local/bin/."
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] phoenix_hypervisor_lxc_common_docker.sh: Cannot find phoenix_hypervisor_lxc_common_base.sh" | tee -a "$PHOENIX_DOCKER_LOG_FILE" >&2
    exit 1
fi

if [[ -z "$PHOENIX_HYPERVISOR_LXC_COMMON_BASE_LOADED" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] phoenix_hypervisor_lxc_common_docker.sh: Failed to load phoenix_hypervisor_lxc_common_base.sh" | tee -a "$PHOENIX_DOCKER_LOG_FILE" >&2
    exit 1
fi

if [[ -f "/usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_lxc_common_systemd.sh" ]]; then
    source /usr/local/lib/phoenix_hypervisor/phoenix_hypervisor_lxc_common_systemd.sh
    log_info "phoenix_hypervisor_lxc_common_docker.sh: Sourced systemd functions."
elif [[ -f "/usr/local/bin/phoenix_hypervisor_lxc_common_systemd.sh" ]]; then
    source /usr/local/bin/phoenix_hypervisor_lxc_common_systemd.sh
    log_info "phoenix_hypervisor_lxc_common_docker.sh: Sourced systemd functions from /usr/local/bin/."
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] phoenix_hypervisor_lxc_common_docker.sh: Cannot find phoenix_hypervisor_lxc_common_systemd.sh" | tee -a "$PHOENIX_DOCKER_LOG_FILE" >&2
    exit 1
fi

# --- Get Configuration Value ---
get_config_value() {
    local lxc_id="$1"
    local key="$2"
    local config_file="${PHOENIX_LXC_CONFIG_FILE:-/usr/local/etc/phoenix_lxc_configs.json}"
    if [[ ! -f "$config_file" ]]; then
        log_error "get_config_value: Configuration file $config_file not found"
        return 1
    fi
    local value
    if ! value=$(retry_command 3 5 jq -r ".lxc_configs.\"$lxc_id\".\"$key\" // null" "$config_file" 2>>"$PHOENIX_DOCKER_LOG_FILE"); then
        log_error "get_config_value: Failed to parse $key for container $lxc_id"
        return 1
    fi
    if [[ "$value" == "null" ]]; then
        log_warn "get_config_value: Key $key not found for container $lxc_id"
        return 1
    fi
    echo "$value"
}

# --- Install Docker Prerequisites ---
install_docker_prerequisites() {
    local lxc_id="$1"
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*" | tee -a "$PHOENIX_DOCKER_LOG_FILE"; }
    fi
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" | tee -a "$PHOENIX_DOCKER_LOG_FILE" >&2; return 1; }
    fi
    if [[ -z "$lxc_id" ]]; then
        "$error_func" "install_docker_prerequisites: Container ID is required"
        return 1
    fi
    "$log_func" "install_docker_prerequisites: Installing prerequisites in container $lxc_id..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Installing Docker prerequisites in container $lxc_id..." >&2
    fi
    local prereq_cmd="set -e
    export DEBIAN_FRONTEND=noninteractive
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    touch /tmp/docker-prereq.log || { echo '[ERROR] Cannot create /tmp/docker-prereq.log'; exit 1; }
    echo '[INFO] Installing Docker prerequisites...' >/tmp/docker-prereq.log
    apt-get update -y --fix-missing >>/tmp/docker-prereq-update.log 2>&1 || { echo '[ERROR] Failed to update package lists'; cat /tmp/docker-prereq-update.log; exit 1; }
    apt-get install -y ca-certificates curl gnupg lsb-release jq >>/tmp/docker-prereq-install.log 2>&1 || { echo '[ERROR] Failed to install prerequisites'; cat /tmp/docker-prereq-install.log; exit 1; }
    echo '[SUCCESS] Docker prerequisites installed.' >>/tmp/docker-prereq.log
    "
    if pct_exec_with_retry "$lxc_id" bash -c "$prereq_cmd"; then
        "$log_func" "install_docker_prerequisites: Prerequisites installed successfully in container $lxc_id."
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Docker prerequisites installed successfully in container $lxc_id." >&2
        fi
        return 0
    else
        "$error_func" "install_docker_prerequisites: Failed to install prerequisites in container $lxc_id. Check /tmp/docker-prereq.log."
        return 1
    fi
}

# --- Docker Installation ---
install_docker_ce_in_container() {
    local lxc_id="$1"
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*" | tee -a "$PHOENIX_DOCKER_LOG_FILE"; }
    fi
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" | tee -a "$PHOENIX_DOCKER_LOG_FILE" >&2; return 1; }
    fi
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" | tee -a "$PHOENIX_DOCKER_LOG_FILE" >&2; }
    fi
    if [[ -z "$lxc_id" ]]; then
        "$error_func" "install_docker_ce_in_container: Container ID is required"
        return 1
    fi
    "$log_func" "install_docker_ce_in_container: Installing Docker-ce in container $lxc_id..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Installing Docker-ce in container $lxc_id... This may take a few minutes." >&2
    fi
    local check_cmd="set -e
    export DEBIAN_FRONTEND=noninteractive
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    if command -v docker >/dev/null 2>&1 && dpkg -l | grep -q docker-ce; then
        echo '[SUCCESS] Docker-ce already installed in container $lxc_id.'
        exit 0
    fi
    exit 1"
    if pct_exec_with_retry "$lxc_id" bash -c "$check_cmd"; then
        "$log_func" "install_docker_ce_in_container: Docker-ce already installed in container $lxc_id."
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Docker-ce already installed in container $lxc_id." >&2
        fi
        return 0
    fi
    if ! install_docker_prerequisites "$lxc_id"; then
        "$error_func" "install_docker_ce_in_container: Failed to install prerequisites in container $lxc_id"
        return 1
    fi
    local codename
    codename=$(pct_exec_with_retry "$lxc_id" bash -c "lsb_release -cs" 2>>"$PHOENIX_DOCKER_LOG_FILE")
    if [[ $? -ne 0 || -z "$codename" ]]; then
        "$error_func" "install_docker_ce_in_container: Failed to retrieve codename for container $lxc_id."
        return 1
    fi
    "$log_func" "install_docker_ce_in_container: Detected container codename: $codename"
    if [[ "$codename" == "plucky" ]]; then
        "$warn_func" "install_docker_ce_in_container: Ubuntu 25.04 (plucky) detected. Using noble repository for compatibility."
        codename="noble"
    fi
    local install_cmd="set -e
    export DEBIAN_FRONTEND=noninteractive
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    touch /tmp/docker-install.log || { echo '[ERROR] Cannot create /tmp/docker-install.log'; exit 1; }
    echo '[INFO] Removing potentially conflicting old Docker packages...' >>/tmp/docker-install.log
    apt-get remove -y docker docker-engine docker.io containerd runc >>/tmp/docker-install.log 2>&1 || true
    echo '[INFO] Adding/updating Docker GPG key...' >>/tmp/docker-install.log
    mkdir -p /etc/apt/keyrings
    rm -f /etc/apt/keyrings/docker.gpg
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    if [ ! -s /etc/apt/keyrings/docker.gpg ]; then
        echo '[ERROR] Failed to download or create Docker GPG key file.' >>/tmp/docker-install.log
        exit 1
    fi
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo '[INFO] Docker GPG key added successfully.' >>/tmp/docker-install.log
    echo '[INFO] Adding/updating Docker APT repository...' >>/tmp/docker-install.log
    mkdir -p /etc/apt/sources.list.d
    REPO_ARCH=\$(dpkg --print-architecture)
    echo \"deb [arch=\${REPO_ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $codename stable\" | tee /etc/apt/sources.list.d/docker.list >/dev/null
    if ! test -f /etc/apt/sources.list.d/docker.list || ! grep -q \"$codename stable\" /etc/apt/sources.list.d/docker.list; then
        echo '[ERROR] Failed to create or validate Docker repository file.' >>/tmp/docker-install.log
        echo '[DEBUG] Contents of /etc/apt/sources.list.d/docker.list:' >>/tmp/docker-install.log
        cat /etc/apt/sources.list.d/docker.list >>/tmp/docker-install.log
        exit 1
    fi
    echo '[INFO] Docker APT repository added successfully.' >>/tmp/docker-install.log
    echo '[INFO] Updating package lists...' >>/tmp/docker-install.log
    apt-get update -y --fix-missing >>/tmp/docker-apt-update.log 2>&1 || { echo '[ERROR] Failed to update package lists'; cat /tmp/docker-apt-update.log; exit 1; }
    echo '[INFO] Installing Docker-ce packages...' >>/tmp/docker-install.log
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >>/tmp/docker-apt-install.log 2>&1 || { echo '[ERROR] Failed to install Docker-ce packages'; cat /tmp/docker-apt-install.log; exit 1; }
    echo '[INFO] Verifying Docker-ce package installation...' >>/tmp/docker-install.log
    if ! dpkg -l | grep -q docker-ce || ! test -f /usr/bin/docker; then
        echo '[ERROR] Docker-ce package or binary not found.' >>/tmp/docker-install.log
        exit 1
    fi
    echo '[INFO] Performing basic Docker daemon verification...' >>/tmp/docker-install.log
    if timeout 30s bash -c 'while ! docker version >/dev/null 2>&1; do sleep 2; done'; then
        echo '[SUCCESS] Docker command and version check successful.' >>/tmp/docker-install.log
    else
        echo '[WARN] Initial Docker version check timed out or failed.' >>/tmp/docker-install.log
    fi
    echo '[SUCCESS] Docker-ce packages installed successfully.' >>/tmp/docker-install.log
    "
    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "install_docker_ce_in_container: Attempting Docker-ce installation (attempt $attempt/$max_attempts)..."
        if pct_exec_with_retry "$lxc_id" bash -c "$install_cmd"; then
            if ! declare -F enable_systemd_service_in_container >/dev/null 2>&1 || ! declare -F start_systemd_service_in_container >/dev/null 2>&1; then
                "$error_func" "install_docker_ce_in_container: Systemd functions not available. Ensure phoenix_hypervisor_lxc_common_systemd.sh is sourced."
                return 1
            fi
            "$log_func" "install_docker_ce_in_container: Docker packages installed. Ensuring Docker service state..."
            local is_enabled_check="
            if systemctl is-enabled --quiet docker 2>/dev/null; then
                echo '[INFO] Docker service is already enabled.'
                exit 0
            else
                echo '[INFO] Docker service is not enabled.'
                exit 1
            fi
            "
            if pct_exec_with_retry "$lxc_id" bash -c "$is_enabled_check"; then
                : # Already enabled
            else
                "$log_func" "install_docker_ce_in_container: Enabling Docker service..."
                if enable_systemd_service_in_container "$lxc_id" "docker"; then
                    "$log_func" "install_docker_ce_in_container: Docker service enabled successfully."
                else
                    "$warn_func" "install_docker_ce_in_container: Failed to enable Docker service."
                fi
            fi
            local is_active_check="
            if systemctl is-active --quiet docker 2>/dev/null; then
                echo '[INFO] Docker service is already active.'
                exit 0
            else
                echo '[INFO] Docker service is not active.'
                exit 1
            fi
            "
            if pct_exec_with_retry "$lxc_id" bash -c "$is_active_check"; then
                : # Already active
            else
                "$log_func" "install_docker_ce_in_container: Starting Docker service..."
                if retry_command 3 5 start_systemd_service_in_container "$lxc_id" "docker"; then
                    "$log_func" "install_docker_ce_in_container: Docker service started successfully."
                else
                    "$error_func" "install_docker_ce_in_container: Failed to start Docker service after retries."
                    return 1
                fi
            fi
            "$log_func" "install_docker_ce_in_container: Docker-ce installed and service managed successfully in container $lxc_id."
            if [[ "${QUIET_MODE:-false}" != "true" ]]; then
                echo "Docker-ce installation completed for container $lxc_id." >&2
            fi
            return 0
        else
            "$warn_func" "install_docker_ce_in_container: Installation failed on attempt $attempt. Retrying in 10 seconds..."
            sleep 10
            ((attempt++))
        fi
    done
    "$error_func" "install_docker_ce_in_container: Failed to install Docker-ce in container $lxc_id after $max_attempts attempts."
    return 1
}

# --- Docker Hub Authentication ---
authenticate_dockerhub() {
    local lxc_id="$1"
    local username="$2"
    local access_token="$3"
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*" | tee -a "$PHOENIX_DOCKER_LOG_FILE"; }
    fi
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" | tee -a "$PHOENIX_DOCKER_LOG_FILE" >&2; return 1; }
    fi
    if [[ -z "$lxc_id" || -z "$username" || -z "$access_token" ]]; then
        "$error_func" "authenticate_dockerhub: Missing lxc_id, username, or access_token"
        return 1
    fi
    if [[ ${#username} -lt 4 || ! "$username" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        "$error_func" "authenticate_dockerhub: Invalid username format (min 4 chars, alphanumeric, underscore, hyphen only)"
        return 1
    fi
    if [[ ${#access_token} -lt 8 ]]; then
        "$error_func" "authenticate_dockerhub: Access token too short (min 8 chars)"
        return 1
    fi
    "$log_func" "authenticate_dockerhub: Authenticating to Docker Hub in container $lxc_id as $username..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Authenticating to Docker Hub in container $lxc_id..." >&2
    fi
    local auth_cmd="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    mkdir -p /root/.docker
    echo '{\"auths\":{\"https://index.docker.io/v1/\":{\"auth\":\"'\$(echo -n \"$username:$access_token\" | base64)'\"}}}' > /root/.docker/config.json
    chmod 600 /root/.docker/config.json
    if docker login -u \"$username\" --password-stdin <<< \"$access_token\" >/tmp/docker-login.log 2>&1; then
        echo '[SUCCESS] Docker Hub authentication successful.'
    else
        echo '[ERROR] Docker Hub authentication failed.' >>/tmp/docker-login.log
        cat /tmp/docker-login.log
        exit 1
    fi
    "
    if pct_exec_with_retry "$lxc_id" bash -c "$auth_cmd"; then
        "$log_func" "authenticate_dockerhub: Successfully authenticated to Docker Hub in container $lxc_id."
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Docker Hub authentication successful for container $lxc_id." >&2
        fi
        return 0
    else
        "$error_func" "authenticate_dockerhub: Failed to authenticate to Docker Hub in container $lxc_id. Check /tmp/docker-login.log."
        return 1
    fi
}

# --- Docker Image Management ---
build_docker_image_in_container() {
    local lxc_id="$1"
    local dockerfile_path="$2"
    local image_tag="$3"
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*" | tee -a "$PHOENIX_DOCKER_LOG_FILE"; }
    fi
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" | tee -a "$PHOENIX_DOCKER_LOG_FILE" >&2; return 1; }
    fi
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" | tee -a "$PHOENIX_DOCKER_LOG_FILE" >&2; }
    fi
    if [[ -z "$lxc_id" || -z "$dockerfile_path" || -z "$image_tag" ]]; then
        "$error_func" "build_docker_image_in_container: Missing lxc_id, dockerfile_path, or image_tag"
        return 1
    fi
    "$log_func" "build_docker_image_in_container: Building Docker image $image_tag in container $lxc_id from $dockerfile_path..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Building Docker image $image_tag in container $lxc_id... This may take a few minutes." >&2
    fi
    local check_cmd="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    DOCKERFILE_PATH_ENV=\$1
    IMAGE_TAG_ENV=\$2
    if ! command -v docker >/dev/null 2>&1; then
        echo '[ERROR] Docker not installed in container.'
        exit 1
    fi
    if ! test -f \"\$DOCKERFILE_PATH_ENV\"; then
        echo '[ERROR] Dockerfile not found at \$DOCKERFILE_PATH_ENV.'
        exit 1
    fi
    if ! test -r \"\$DOCKERFILE_PATH_ENV\"; then
        echo '[ERROR] Dockerfile at \$DOCKERFILE_PATH_ENV is not readable.'
        exit 1
    fi
    if ! grep -q '^FROM ' \"\$DOCKERFILE_PATH_ENV\"; then
        echo '[ERROR] Dockerfile at \$DOCKERFILE_PATH_ENV lacks a valid FROM instruction.'
        exit 1
    fi
    if ! test -d \"\$(dirname \"\$DOCKERFILE_PATH_ENV\")\"; then
        echo '[ERROR] Build context directory \$(dirname \"\$DOCKERFILE_PATH_ENV\") does not exist.'
        exit 1
    fi
    if docker images -q \"\$IMAGE_TAG_ENV\" | grep -q .; then
        echo '[SUCCESS] Docker image \$IMAGE_TAG_ENV already exists locally.'
        exit 0
    fi
    exit 1
    "
    if pct_exec_with_retry "$lxc_id" bash -c "$check_cmd" "$dockerfile_path" "$image_tag"; then
        "$log_func" "build_docker_image_in_container: Docker image $image_tag already exists in container $lxc_id."
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Docker image $image_tag already exists in container $lxc_id." >&2
        fi
        return 0
    fi
    local build_cmd="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    DOCKERFILE_PATH_ENV=\$1
    IMAGE_TAG_ENV=\$2
    echo '[INFO] Building Docker image \$IMAGE_TAG_ENV...' >/tmp/docker-build-\"\$(echo \"\$IMAGE_TAG_ENV\" | sed 's/[^a-zA-Z0-9_.-]/_/g')\".log
    cd \"\$(dirname \"\$DOCKERFILE_PATH_ENV\")\" || { echo '[ERROR] Failed to change directory to \$(dirname \"\$DOCKERFILE_PATH_ENV\")'; exit 1; }
    docker build -t \"\$IMAGE_TAG_ENV\" -f \"\$(basename \"\$DOCKERFILE_PATH_ENV\")\" . >>/tmp/docker-build-\"\$(echo \"\$IMAGE_TAG_ENV\" | sed 's/[^a-zA-Z0-9_.-]/_/g')\".log 2>&1 || { echo '[ERROR] Failed to build Docker image \$IMAGE_TAG_ENV'; cat /tmp/docker-build-\"\$(echo \"\$IMAGE_TAG_ENV\" | sed 's/[^a-zA-Z0-9_.-]/_/g')\".log; exit 1; }
    if docker images -q \"\$IMAGE_TAG_ENV\" | grep -q .; then
        echo '[SUCCESS] Docker image \$IMAGE_TAG_ENV built successfully.' >>/tmp/docker-build-\"\$(echo \"\$IMAGE_TAG_ENV\" | sed 's/[^a-zA-Z0-9_.-]/_/g')\".log
    else
        echo '[ERROR] Docker image \$IMAGE_TAG_ENV verification failed.' >>/tmp/docker-build-\"\$(echo \"\$IMAGE_TAG_ENV\" | sed 's/[^a-zA-Z0-9_.-]/_/g')\".log
        exit 1
    fi
    "
    local attempt=1
    local max_attempts=3
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "build_docker_image_in_container: Attempting Docker image build (attempt $attempt/$max_attempts)..."
        if pct_exec_with_retry "$lxc_id" bash -c "$build_cmd" "$dockerfile_path" "$image_tag"; then
            "$log_func" "build_docker_image_in_container: Docker image $image_tag built successfully in container $lxc_id."
            if [[ "${QUIET_MODE:-false}" != "true" ]]; then
                echo "Docker image build completed for $image_tag in container $lxc_id." >&2
            fi
            return 0
        else
            "$warn_func" "build_docker_image_in_container: Build failed on attempt $attempt. Retrying in 10 seconds..."
            sleep 10
            ((attempt++))
        fi
    done
    "$error_func" "build_docker_image_in_container: Failed to build Docker image $image_tag in container $lxc_id after $max_attempts attempts."
    return 1
}

# --- Docker Runtime Configuration ---
configure_docker_nvidia_runtime() {
    local lxc_id="$1"
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*" | tee -a "$PHOENIX_DOCKER_LOG_FILE"; }
    fi
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" | tee -a "$PHOENIX_DOCKER_LOG_FILE" >&2; return 1; }
    fi
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" | tee -a "$PHOENIX_DOCKER_LOG_FILE" >&2; }
    fi
    if [[ -z "$lxc_id" ]]; then
        "$error_func" "configure_docker_nvidia_runtime: Container ID is required"
        return 1
    fi
    if [[ "$lxc_id" == "999" ]]; then
        "$log_func" "configure_docker_nvidia_runtime: Container $lxc_id (Portainer server) does not require NVIDIA runtime. Skipping."
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Skipping NVIDIA runtime configuration for container $lxc_id (Portainer server)." >&2
        fi
        return 0
    fi
    "$log_func" "configure_docker_nvidia_runtime: Configuring NVIDIA runtime for Docker in container $lxc_id..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Configuring NVIDIA runtime for Docker in container $lxc_id..." >&2
    fi
    if [[ "$lxc_id" -ge 900 && "$lxc_id" -le 902 ]]; then
        "$warn_func" "configure_docker_nvidia_runtime: Container $lxc_id (Portainer agent) may require GPU access for vLLM. Ensure GPU passthrough is configured."
    fi
    local config_file="/etc/pve/lxc/$lxc_id.conf"
    "$log_func" "configure_docker_nvidia_runtime: Checking cgroup settings in $config_file..."
    if ! grep -q "lxc.cgroup2.devices.allow: a" "$config_file" 2>>"$PHOENIX_DOCKER_LOG_FILE"; then
        "$error_func" "configure_docker_nvidia_runtime: Missing lxc.cgroup2.devices.allow: a in $config_file."
        return 1
    fi
    if grep -q "no-cgroups = true" "$config_file" 2>>"$PHOENIX_DOCKER_LOG_FILE"; then
        "$error_func" "configure_docker_nvidia_runtime: Invalid no-cgroups = true found in $config_file. Remove it."
        return 1
    fi
    if ! grep -q "features:.*nesting=1" "$config_file" 2>>"$PHOENIX_DOCKER_LOG_FILE"; then
        "$warn_func" "configure_docker_nvidia_runtime: Missing 'features: nesting=1' in $config_file."
    fi
    if ! grep -q "lxc.init_cmd: /sbin/init" "$config_file" 2>>"$PHOENIX_DOCKER_LOG_FILE"; then
        "$warn_func" "configure_docker_nvidia_runtime: Missing 'lxc.init_cmd: /sbin/init' in $config_file."
    fi
    if grep -q "unprivileged: 1" "$config_file" 2>>"$PHOENIX_DOCKER_LOG_FILE"; then
        "$warn_func" "configure_docker_nvidia_runtime: Container $lxc_id is unprivileged. NVIDIA runtime may require privileged container."
    fi
    "$log_func" "configure_docker_nvidia_runtime: Backing up /etc/docker/daemon.json in container $lxc_id..."
    local backup_cmd="set -e
    if [ -f /etc/docker/daemon.json ]; then
        cp /etc/docker/daemon.json /etc/docker/daemon.json.bak || echo '[WARN] Failed to backup /etc/docker/daemon.json' >>/tmp/docker-config-backup.log
    fi
    echo '[INFO] Backup attempt completed.' >>/tmp/docker-config-backup.log
    "
    pct_exec_with_retry "$lxc_id" bash -c "$backup_cmd" 2>>"$PHOENIX_DOCKER_LOG_FILE" || "$warn_func" "configure_docker_nvidia_runtime: Failed to backup /etc/docker/daemon.json"
    local tmp_check_cmd="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    touch /tmp/tmp-check.log || { echo '[ERROR] Cannot create /tmp/tmp-check.log'; exit 1; }
    echo '[SUCCESS] /tmp is writable.' >>/tmp/tmp-check.log
    "
    if ! pct_exec_with_retry "$lxc_id" bash -c "$tmp_check_cmd"; then
        "$error_func" "configure_docker_nvidia_runtime: /tmp is not writable in container $lxc_id."
        return 1
    fi
    local in_lxc=false
    if pct_exec_with_retry "$lxc_id" bash -c "[[ -f /run/systemd/container && \"\$(cat /run/systemd/container 2>/dev/null)\" == \"lxc\" ]]"; then
        in_lxc=true
    fi
    local storage_driver="overlay2"
    if [[ "$in_lxc" == true ]]; then
        "$log_func" "configure_docker_nvidia_runtime: Detected LXC environment for container $lxc_id. Using overlay2 storage driver."
        if ! pct_exec_with_retry "$lxc_id" bash -c "echo '$storage_driver' > /tmp/docker-storage-driver"; then
            "$error_func" "configure_docker_nvidia_runtime: Failed to write storage driver to /tmp/docker-storage-driver in container $lxc_id."
            return 1
        fi
    else
        "$log_func" "configure_docker_nvidia_runtime: Non-LXC environment detected. Checking ZFS..."
        local zfs_install_cmd="set -e
        export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
        touch /tmp/zfs-install.log || { echo '[ERROR] Cannot create /tmp/zfs-install.log'; exit 1; }
        echo '[INFO] Checking zfsutils-linux...' >/tmp/zfs-install.log
        if ! command -v zfs >/dev/null 2>&1; then
            modprobe zfs >>/tmp/zfs-install.log 2>&1 || echo '[WARN] Failed to load ZFS module' >>/tmp/zfs-install.log
            udevadm trigger >>/tmp/zfs-install.log 2>&1 || echo '[WARN] udevadm trigger failed' >>/tmp/zfs-install.log
            mount -t proc proc /proc >>/tmp/zfs-install.log 2>&1 || echo '[WARN] Failed to mount /proc' >>/tmp/zfs-install.log
            apt-get update >>/tmp/zfs-install.log 2>&1 || { echo '[ERROR] Failed to update apt'; cat /tmp/zfs-install.log; exit 1; }
            apt-get install -y zfsutils-linux >>/tmp/zfs-install.log 2>&1 || { echo '[ERROR] Failed to install zfsutils-linux'; cat /tmp/zfs-install.log; exit 1; }
        fi
        if ! zfs list >/dev/null 2>&1; then
            echo '[WARN] ZFS list failed, falling back to vfs storage driver' >>/tmp/zfs-install.log
            echo 'vfs' > /tmp/docker-storage-driver
        else
            echo '[INFO] ZFS available, using zfs storage driver' >>/tmp/zfs-install.log
            echo 'zfs' > /tmp/docker-storage-driver
        fi
        "
        if ! pct_exec_with_retry "$lxc_id" bash -c "$zfs_install_cmd"; then
            "$warn_func" "configure_docker_nvidia_runtime: Failed to configure zfsutils-linux. Falling back to vfs storage driver."
            storage_driver="vfs"
            if ! pct_exec_with_retry "$lxc_id" bash -c "echo 'vfs' > /tmp/docker-storage-driver"; then
                "$error_func" "configure_docker_nvidia_runtime: Failed to write fallback storage driver in container $lxc_id."
                return 1
            fi
        else
            storage_driver=$(pct_exec_with_retry "$lxc_id" bash -c "cat /tmp/docker-storage-driver" 2>>"$PHOENIX_DOCKER_LOG_FILE" || echo "overlay2")
        fi
    fi
    local nvidia_config_cmd="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    NVIDIA_CONFIG_FILE='/etc/nvidia-container-runtime/config.toml'
    mkdir -p \"\$(dirname \"\$NVIDIA_CONFIG_FILE\")\" || { echo '[ERROR] Failed to create directory for \$NVIDIA_CONFIG_FILE'; exit 1; }
    cat > \"\$NVIDIA_CONFIG_FILE\" << 'EOF'
disable-require = false
supported-driver-capabilities = \"compat32,compute,display,graphics,ngx,utility,video\"

[nvidia-container-cli]
environment = []
ldconfig = \"@/sbin/ldconfig.real\"
load-kmods = true
no-cgroups = true

[nvidia-container-runtime]
log-level = \"info\"
mode = \"auto\"
runtimes = [\"docker-runc\", \"runc\", \"crun\"]

[nvidia-container-runtime.modes]

[nvidia-container-runtime.modes.cdi]
annotation-prefixes = [\"cdi.k8s.io/\"]
default-kind = \"nvidia.com/gpu\"
spec-dirs = [\"/etc/cdi\", \"/var/run/cdi\"]

[nvidia-container-runtime.modes.csv]
mount-spec-path = \"/etc/nvidia-container-runtime/host-files-for-container.d\"

[nvidia-container-runtime.modes.legacy]
cuda-compat-mode = \"ldconfig\"

[nvidia-container-runtime-hook]
path = \"nvidia-container-runtime-hook\"
skip-mode-detection = false

[nvidia-ctk]
path = \"nvidia-ctk\"
EOF
    echo '[SUCCESS] NVIDIA Container Runtime config updated.' >/tmp/nvidia-config.log
    "
    if ! pct_exec_with_retry "$lxc_id" bash -c "$nvidia_config_cmd"; then
        "$error_func" "configure_docker_nvidia_runtime: Failed to configure NVIDIA Container Runtime in container $lxc_id."
        return 1
    fi
    if ! install_docker_prerequisites "$lxc_id"; then
        "$error_func" "configure_docker_nvidia_runtime: Failed to install prerequisites in container $lxc_id."
        return 1
    fi
    local prereq_cmd="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    touch /tmp/prereq-check.log || { echo '[ERROR] Cannot create /tmp/prereq-check.log'; exit 1; }
    if ! command -v nvidia-smi >/dev/null 2>&1 || ! command -v nvidia-ctk >/dev/null 2>&1 || ! command -v docker >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        echo '[ERROR] Missing required tools (nvidia-smi, nvidia-ctk, docker, or jq)' >>/tmp/prereq-check.log
        exit 1
    fi
    if ! ls /dev/dri/card0 /dev/dri/renderD128 >/dev/null 2>&1 || ! ls /dev/nvidia* >/dev/null 2>&1; then
        echo '[ERROR] GPU devices not accessible' >>/tmp/prereq-check.log
        exit 1
    fi
    if ! nvidia-smi >/dev/null 2>&1; then
        echo '[ERROR] nvidia-smi failed to detect GPUs' >>/tmp/prereq-check.log
        exit 1
    fi
    echo '[SUCCESS] Prerequisites checked.' >>/tmp/prereq-check.log
    "
    if ! pct_exec_with_retry "$lxc_id" bash -c "$prereq_cmd"; then
        "$error_func" "configure_docker_nvidia_runtime: Prerequisites check failed in container $lxc_id. Check /tmp/prereq-check.log."
        return 1
    fi
    local config_cmd="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    touch /tmp/nvidia-ctk.log || { echo '[ERROR] Cannot create /tmp/nvidia-ctk.log'; exit 1; }
    echo '[INFO] Configuring Docker runtime with $storage_driver storage driver...' >>/tmp/nvidia-ctk.log
    if ! nvidia-ctk runtime configure --runtime=docker --set-as-default --storage-driver=$storage_driver >>/tmp/nvidia-ctk.log 2>&1; then
        echo '[WARN] nvidia-ctk failed to configure Docker runtime. Creating fallback daemon.json...' >>/tmp/nvidia-ctk.log
        mkdir -p /etc/docker
        cat << 'EOF' > /etc/docker/daemon.json
{
  \"storage-driver\": \"'$storage_driver'\",
  \"default-runtime\": \"nvidia\",
  \"runtimes\": {
    \"nvidia\": {
      \"path\": \"/usr/bin/nvidia-container-runtime\",
      \"runtimeArgs\": []
    }
  }
}
EOF
        echo '[INFO] Fallback /etc/docker/daemon.json created.' >>/tmp/nvidia-ctk.log
    fi
    echo '[INFO] Current /etc/docker/daemon.json contents:' >>/tmp/nvidia-ctk.log
    cat /etc/docker/daemon.json >>/tmp/nvidia-ctk.log 2>/dev/null || echo '[WARN] /etc/docker/daemon.json not found' >>/tmp/nvidia-ctk.log
    "
    if ! pct_exec_with_retry "$lxc_id" bash -c "storage_driver=$storage_driver; $config_cmd"; then
        "$error_func" "configure_docker_nvidia_runtime: Failed to configure NVIDIA runtime in container $lxc_id. Check /tmp/nvidia-ctk.log."
        return 1
    fi
    local apparmor_cmd="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    touch /tmp/docker-override.log || { echo '[ERROR] Cannot create /tmp/docker-override.log'; exit 1; }
    if [ -f /etc/systemd/system/docker.service.d/override.conf ]; then
        echo '[INFO] Systemd override for Docker already exists.' >>/tmp/docker-override.log
    else
        mkdir -p /etc/systemd/system/docker.service.d
        cat << 'EOF' > /etc/systemd/system/docker.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock
EOF
        systemctl daemon-reload >>/tmp/docker-daemon-reload.log 2>&1 || { echo '[ERROR] Failed to reload systemd daemon'; cat /tmp/docker-daemon-reload.log; exit 1; }
    fi
    "
    if ! pct_exec_with_retry "$lxc_id" bash -c "$apparmor_cmd"; then
        "$warn_func" "configure_docker_nvidia_runtime: Failed to configure systemd override. Check /tmp/docker-override.log."
    fi
    local json_validation_cmd="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    touch /tmp/docker-json-validation.log || { echo '[ERROR] Cannot create /tmp/docker-json-validation.log'; exit 1; }
    if [ ! -f /etc/docker/daemon.json ] || [ ! -s /etc/docker/daemon.json ]; then
        echo '[ERROR] /etc/docker/daemon.json does not exist or is empty' >>/tmp/docker-json-validation.log
        exit 1
    fi
    if ! jq . /etc/docker/daemon.json >>/tmp/docker-json-validation.log 2>&1; then
        echo '[ERROR] Invalid JSON syntax in /etc/docker/daemon.json.' >>/tmp/docker-json-validation.log
        cat /etc/docker/daemon.json >>/tmp/docker-json-validation.log
        exit 1
    fi
    echo '[SUCCESS] /etc/docker/daemon.json syntax is valid.' >>/tmp/docker-json-validation.log
    "
    if ! pct_exec_with_retry "$lxc_id" bash -c "$json_validation_cmd"; then
        "$error_func" "configure_docker_nvidia_runtime: JSON validation failed in container $lxc_id. Check /tmp/docker-json-validation.log."
        return 1
    fi
    local systemd_check_cmd="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    touch /tmp/systemd-check.log || { echo '[ERROR] Cannot create /tmp/systemd-check.log'; exit 1; }
    if ! [ -f /sbin/init ]; then
        echo '[ERROR] /sbin/init not found' >>/tmp/systemd-check.log
        exit 1
    fi
    if ! systemctl is-system-running >/dev/null 2>&1; then
        echo '[WARN] Systemd not running, attempting to initialize...' >>/tmp/systemd-check.log
        /sbin/init >>/tmp/systemd-check.log 2>&1 || { echo '[ERROR] Failed to initialize systemd'; cat /tmp/systemd-check.log; exit 1; }
    fi
    if ! systemctl is-active containerd >/dev/null 2>&1; then
        systemctl start containerd >>/tmp/systemd-check.log 2>&1 || { echo '[ERROR] Failed to start containerd'; cat /tmp/systemd-check.log; exit 1; }
    fi
    echo '[SUCCESS] Systemd and containerd services are ready.' >>/tmp/systemd-check.log
    "
    if ! pct_exec_with_retry "$lxc_id" bash -c "$systemd_check_cmd"; then
        "$error_func" "configure_docker_nvidia_runtime: Systemd or containerd check failed in container $lxc_id. Check /tmp/systemd-check.log."
        return 1
    fi
    local attempt=1
    local max_attempts=3
    local retry_delay=15
    local timeout_seconds=120
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "configure_docker_nvidia_runtime: Attempting to restart Docker (attempt $attempt/$max_attempts)..."
        local restart_cmd="set -e
        export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
        touch /tmp/docker-restart.log || { echo '[ERROR] Cannot create /tmp/docker-restart.log'; exit 1; }
        timeout $timeout_seconds systemctl restart docker >/tmp/docker-restart.log 2>&1 || {
            echo '[ERROR] Failed to restart Docker service' >>/tmp/docker-restart.log
            journalctl -u docker.service --since '5 minutes ago' --no-pager >>/tmp/docker-restart.log
            systemctl status docker.service >>/tmp/docker-restart.log
            exit 1
        }
        echo '[SUCCESS] Docker service restarted successfully.' >>/tmp/docker-restart.log
        "
        if pct_exec_with_retry "$lxc_id" bash -c "$restart_cmd"; then
            local storage_check_cmd="set -e
            export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
            touch /tmp/docker-storage-check.log || { echo '[ERROR] Cannot create /tmp/docker-storage-check.log'; exit 1; }
            docker info --format '{{.Driver}}' >/tmp/docker-info.log 2>&1 || { echo '[ERROR] Failed to run docker info'; cat /tmp/docker-info.log; exit 1; }
            if docker info --format '{{.Driver}}' | grep -q \"$storage_driver\"; then
                echo '[SUCCESS] Storage driver is $(docker info --format '{{.Driver}}').' >>/tmp/docker-storage-check.log
            else
                echo '[ERROR] Invalid storage driver: $(docker info --format '{{.Driver}}')' >>/tmp/docker-storage-check.log
                exit 1
            fi
            "
            if pct_exec_with_retry "$lxc_id" bash -c "storage_driver=$storage_driver; $storage_check_cmd"; then
                "$log_func" "configure_docker_nvidia_runtime: Docker service restarted successfully with $storage_driver storage driver in container $lxc_id."
                if [[ "${QUIET_MODE:-false}" != "true" ]]; then
                    echo "Docker NVIDIA runtime configured with $storage_driver storage driver in container $lxc_id." >&2
                fi
                return 0
            else
                "$warn_func" "configure_docker_nvidia_runtime: Invalid storage driver after restart in container $lxc_id."
            fi
        fi
        "$warn_func" "configure_docker_nvidia_runtime: Failed on attempt $attempt. Retrying in $retry_delay seconds..."
        sleep "$retry_delay"
        ((attempt++))
    done
    local manual_restart_cmd="set -e
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    touch /tmp/docker-start.log || { echo '[ERROR] Cannot create /tmp/docker-start.log'; exit 1; }
    if systemctl is-active docker >/dev/null 2>&1; then
        systemctl stop docker >/tmp/docker-stop.log 2>&1 || { echo '[ERROR] Failed to stop Docker'; cat /tmp/docker-stop.log; exit 1; }
    fi
    systemctl start docker >/tmp/docker-start.log 2>&1 || { echo '[ERROR] Failed to start Docker'; cat /tmp/docker-start.log; exit 1; }
    echo '[SUCCESS] Docker service manually restarted.' >>/tmp/docker-start.log
    "
    if pct_exec_with_retry "$lxc_id" bash -c "$manual_restart_cmd"; then
        "$log_func" "configure_docker_nvidia_runtime: Manual Docker stop/start succeeded in container $lxc_id."
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Manual Docker restart succeeded in container $lxc_id." >&2
        fi
        return 0
    else
        "$error_func" "configure_docker_nvidia_runtime: Failed to restart Docker in container $lxc_id after $max_attempts attempts and manual fallback."
        return 1
    fi
}

# --- Docker Validation ---
verify_docker_gpu_access_in_container() {
    local lxc_id="$1"
    local test_image="${2:-$(get_config_value "$lxc_id" "cuda_image_tag" || echo "nvidia/cuda:12.8.0-base-ubuntu24.04")}"
    local max_attempts=3
    local attempt=1
    local log_func="log_info"
    if ! declare -F log_info >/dev/null 2>&1; then
        log_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] $*" | tee -a "$PHOENIX_DOCKER_LOG_FILE"; }
    fi
    local warn_func="log_warn"
    if ! declare -F log_warn >/dev/null 2>&1; then
        warn_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [WARN] $*" | tee -a "$PHOENIX_DOCKER_LOG_FILE" >&2; }
    fi
    local error_func="log_error"
    if ! declare -F log_error >/dev/null 2>&1; then
        error_func() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [ERROR] $*" | tee -a "$PHOENIX_DOCKER_LOG_FILE" >&2; return 1; }
    fi
    if [[ -z "$lxc_id" ]]; then
        "$error_func" "verify_docker_gpu_access_in_container: Container ID is required"
        return 2
    fi
    if [[ "$lxc_id" == "999" ]]; then
        "$log_func" "verify_docker_gpu_access_in_container: Container $lxc_id (Portainer server) does not require GPU access. Skipping."
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Skipping GPU access verification for container $lxc_id (Portainer server)." >&2
        fi
        return 0
    fi
    if [[ "$lxc_id" -ge 900 && "$lxc_id" -le 902 ]]; then
        "$warn_func" "verify_docker_gpu_access_in_container: Container $lxc_id (Portainer agent) may require GPU access for vLLM."
    fi
    "$log_func" "verify_docker_gpu_access_in_container: Checking Docker GPU access in container $lxc_id using image $test_image..."
    if [[ "${QUIET_MODE:-false}" != "true" ]]; then
        echo "Verifying Docker GPU access in container $lxc_id with image $test_image..." >&2
    fi
    local docker_run_base_cmd="docker run --rm --gpus all --security-opt apparmor=unconfined"
    local success=false
    while [[ $attempt -le $max_attempts ]]; do
        "$log_func" "verify_docker_gpu_access_in_container: Attempting GPU test (attempt $attempt/$max_attempts)..."
        if pct_exec_with_retry "$lxc_id" bash -c "$docker_run_base_cmd \"$test_image\" nvidia-smi" 2>>"$PHOENIX_DOCKER_LOG_FILE"; then
            "$log_func" "verify_docker_gpu_access_in_container: Docker GPU test with AppArmor bypass succeeded."
            success=true
            break
        fi
        if pct_exec_with_retry "$lxc_id" bash -c "docker run --rm --gpus all \"$test_image\" nvidia-smi" 2>>"$PHOENIX_DOCKER_LOG_FILE"; then
            "$log_func" "verify_docker_gpu_access_in_container: Standard Docker GPU test succeeded."
            success=true
            break
        fi
        if pct_exec_with_retry "$lxc_id" bash -c "docker run --rm --gpus all --privileged \"$test_image\" nvidia-smi" 2>>"$PHOENIX_DOCKER_LOG_FILE"; then
            "$log_func" "verify_docker_gpu_access_in_container: Docker GPU test with privileged mode succeeded."
            success=true
            break
        fi
        "$warn_func" "verify_docker_gpu_access_in_container: GPU test failed on attempt $attempt."
        sleep 10
        ((attempt++))
    done
    if [[ "$success" == true ]]; then
        "$log_func" "verify_docker_gpu_access_in_container: Docker GPU access verified successfully in container $lxc_id."
        if [[ "${QUIET_MODE:-false}" != "true" ]]; then
            echo "Docker GPU access verified successfully in container $lxc_id." >&2
        fi
        return 0
    else
        "$error_func" "verify_docker_gpu_access_in_container: Failed to verify Docker GPU access in container $lxc_id after $max_attempts attempts."
        return 1
    fi
}

# --- Initialize Logging ---
if declare -F setup_logging >/dev/null 2>&1; then
    setup_logging
fi

# --- Signal Successful Loading ---
if declare -F log_info >/dev/null 2>&1; then
    log_info "phoenix_hypervisor_lxc_common_docker.sh: Library loaded successfully."
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] phoenix_hypervisor_lxc_common_docker.sh: Library loaded successfully." | tee -a "$PHOENIX_DOCKER_LOG_FILE"
fi