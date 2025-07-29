#!/bin/bash

# Phoenix Hypervisor Common Functions

#######################################################
# Function: check_root
# Description: Checks if the script is running as root.
# Parameters: None
# Returns: Exits with status code 1 if not root, continues otherwise.
#######################################################
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error: This script must be run as root"
        exit 1
    fi
}

#######################################################
# Function: setup_logging
# Description: Sets up logging for scripts.
# Parameters:
#   LOGFILE - The log file path (must be exported before calling this function)
# Returns: Exits with status code 1 if LOGFILE is not set, continues otherwise.
#######################################################
setup_logging() {
    if [[ -z "$LOGFILE" ]]; then
        echo "Error: LOGFILE variable not set before calling setup_logging"
        exit 1
    fi

    touch "$LOGFILE" || { echo "Error: Cannot create log file $LOGFILE"; exit 1; }
    chmod 644 "$LOGFILE"

    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] Initialized logging for $(basename "$0")" >> "$LOGFILE"
}

#######################################################
# Function: retry_command
# Description: Retries a command up to a specified number of times.
# Parameters:
#   cmd - The command to execute.
#   max_attempts (optional) - Maximum number of attempts. Default is 3.
# Returns: Exit code of the last attempt.
#######################################################
retry_command() {
    local cmd="$1"
    local max_attempts="${2:-3}"
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        log "INFO" "Attempt $attempt/$max_attempts: $cmd"
        eval $cmd
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
# Description: Executes a command inside an LXC container.
# Parameters:
#   lxc_id - The ID of the LXC container.
#   cmd - The command to execute in the container.
# Returns: Exit code from the executed command.
#######################################################
execute_in_lxc() {
    local lxc_id="$1"
    shift
    local cmd="$@"

    log "INFO" "Executing in LXC $lxc_id: $cmd"
    pct exec "$lxc_id" -- bash -c "$cmd"
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
# Returns: 0 (true) if marker file exists, 1 (false) otherwise.
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
# Returns: None
#######################################################
mark_script_completed() {
    local marker_file="$1"
    touch "$marker_file"
    log "INFO" "Marked script completed: $marker_file"
}

#######################################################
# Function: load_hypervisor_config
# Description: Source the hypervisor configuration file.
# Parameters: None
# Returns: Exits with status code 1 if sourcing fails, continues otherwise.
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
# Returns: None
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