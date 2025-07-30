#!/bin/bash

# Phoenix Hypervisor Common Functions
# Provides reusable functions for logging, error handling, script execution, and LXC management.

#######################################################
# Function: check_root
# Description: Checks if the script is running as root.
# Parameters: None
# Inputs: None
# Outputs: Exits with status code 1 if not root, continues otherwise.
# Example: check_root
#######################################################
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error: This script must be run as root"
        exit 1
    fi
}

#######################################################
# Function: sanitize_cmd
# Description: Escapes special characters in a command string to prevent injection.
# Parameters:
#   cmd - The command string to sanitize.
# Inputs: Command string (e.g., "apt-get update")
# Outputs: Sanitized command string
# Returns: None (prints sanitized command)
# Example: sanitized=$(sanitize_cmd "apt-get update; rm -rf /")
#######################################################
sanitize_cmd() {
    local cmd="$1"
    printf '%q' "$cmd"
}

#######################################################
# Function: setup_logging
# Description: Sets up logging for scripts with rotation to prevent log file growth.
# Parameters:
#   LOGFILE - The log file path (must be exported before calling this function)
# Inputs: LOGFILE environment variable
# Outputs: Creates or rotates log file, logs initialization message
# Returns: Exits with status code 1 if LOGFILE is not set or cannot be created
# Example: export LOGFILE=/var/log/hypervisor_prep.log; setup_logging
#######################################################
setup_logging() {
    if [[ -z "$LOGFILE" ]]; then
        echo "Error: LOGFILE variable not set before calling setup_logging"
        exit 1
    fi

    # Rotate log file if it exceeds 10MB (10485760 bytes)
    if [[ -f "$LOGFILE" ]]; then
        # Use `find` with `-size` for a more robust size check
        local file_size
        file_size=$(find "$LOGFILE" -maxdepth 0 -printf "%s" 2>/dev/null || stat -c %s "$LOGFILE" 2>/dev/null)
        if [[ -n "$file_size" && "$file_size" -gt 10485760 ]]; then
            mv "$LOGFILE" "$LOGFILE.1" || { echo "Error: Failed to rotate log file $LOGFILE"; exit 1; }
        fi
    fi

    touch "$LOGFILE" || { echo "Error: Cannot create log file $LOGFILE"; exit 1; }
    chmod 644 "$LOGFILE"

    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] Initialized logging for $(basename "$0")" >> "$LOGFILE"
}

#######################################################
# Function: retry_command
# Description: Retries a command up to a specified number of times with a timeout.
# Parameters:
#   cmd - The command to execute.
#   max_attempts (optional) - Maximum number of attempts. Default is 3.
# Inputs: Command string, optional max_attempts integer
# Outputs: Logs success/failure, executes command
# Returns: Exit code of the last attempt
# Example: retry_command "apt-get update" 3
#######################################################
retry_command() {
    local cmd="$1"
    local max_attempts="${2:-3}"
    local attempt=1
    local exit_code
    local timeout_duration="${COMMAND_TIMEOUT:-300}" # Default timeout: 300 seconds

    while [ $attempt -le $max_attempts ]; do
        log "INFO" "Attempt $attempt/$max_attempts: $cmd"
        timeout "$timeout_duration" bash -c "$cmd"
        exit_code=$?
        if [ $exit_code -eq 0 ]; then
            log "INFO" "Command succeeded: $cmd"
            return 0
        fi
        log "WARN" "Command failed, retrying ($attempt/$max_attempts): $cmd (Exit code: $exit_code)"
        sleep 5
        ((attempt++))
    done
    log "ERROR" "Command failed after $max_attempts attempts: $cmd (Final exit code: $exit_code)"
    return $exit_code
}

#######################################################
# Function: execute_in_lxc
# Description: Executes a command inside an LXC container with a timeout.
# Parameters:
#   lxc_id - The ID of the LXC container.
#   cmd - The command to execute in the container.
# Inputs: LXC ID (integer), command string
# Outputs: Logs execution, runs command in LXC
# Returns: Exit code from the executed command
# Example: execute_in_lxc 901 "apt-get update"
#######################################################
execute_in_lxc() {
    local lxc_id="$1"
    shift
    local cmd="$@"
    local timeout_duration="${COMMAND_TIMEOUT:-300}" # Default timeout: 300 seconds

    # Sanitize the command
    cmd=$(sanitize_cmd "$cmd")

    log "INFO" "Executing in LXC $lxc_id: $cmd"
    timeout "$timeout_duration" pct exec "$lxc_id" -- bash -c "$cmd"
    exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Command failed in LXC $lxc_id (Exit code: $exit_code): $cmd"
    fi
    return $exit_code
}

#######################################################
# Function: is_script_completed
# Description: Checks if a script has been completed based on the presence of a marker file.
# Parameters:
#   marker_file - The path to the marker file.
# Inputs: Marker file path (string)
# Outputs: None
# Returns: 0 (true) if marker file exists, 1 (false) otherwise
# Example: is_script_completed "/var/log/hypervisor_prep_markers/initial_setup.marker"
#######################################################
is_script_completed() {
    local marker_file="$1"
    if [[ -f "$marker_file" ]]; then
        return 0 # true
    else
        return 1 # false
    fi
}

#######################################################
# Function: mark_script_completed
# Description: Marks a script as completed by creating a marker file.
# Parameters:
#   marker_file - The path to the marker file to create.
# Inputs: Marker file path (string)
# Outputs: Creates marker file, logs completion
# Returns: None
# Example: mark_script_completed "/var/log/hypervisor_prep_markers/initial_setup.marker"
#######################################################
mark_script_completed() {
    local marker_file="$1"
    touch "$marker_file"
    log "INFO" "Marked script completed: $marker_file"
}

#######################################################
# Function: load_hypervisor_config
# Description: Sources the hypervisor configuration file.
# Parameters: None
# Inputs: None
# Outputs: Sources config file, logs error on failure
# Returns: Exits with status code 1 if sourcing fails, continues otherwise
# Example: load_hypervisor_config
#######################################################
load_hypervisor_config() {
    source /usr/local/bin/phoenix_hypervisor_config.sh || { echo "Error: Failed to source phoenix_hypervisor_config.sh" >&2; exit 1; }
}

#######################################################
# Function: log
# Description: Logs messages with timestamps.
# Parameters:
#   level - The log level (INFO, WARN, ERROR).
#   message - The message to log.
# Inputs: Log level (string), message (string)
# Outputs: Writes to LOGFILE and console
# Returns: Exits with status code 1 if LOGFILE is not set
# Example: log "INFO" "Starting script"
#######################################################
log() {
    local level="$1"
    shift
    local message="$@"

    if [[ -z "$LOGFILE" ]]; then
        echo "Error: LOGFILE variable not set before calling log"
        exit 1
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [$level] $message" | tee -a "$LOGFILE"
}

# End of phoenix_hypervisor_common.sh