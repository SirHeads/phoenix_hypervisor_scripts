#!/bin/bash
# phoenix_hypervisor_common.sh
# Common functions for the Hypervisor Prep Scripts project.
# Version: 1.1.0
# Author: Assistant

# --- Function Definitions ---

# Function to check if the script is running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error: This script must be run as root"
        exit 1
    fi
}

# Function to set up logging
setup_logging() {
    # Assume LOGFILE is set by the calling script or config
    if [[ -z "$LOGFILE" ]]; then
        echo "Error: LOGFILE variable not set before calling setup_logging"
        exit 1
    fi
    # Ensure log file exists and is writable
    touch "$LOGFILE" || { echo "Error: Cannot create log file $LOGFILE"; exit 1; }
    chmod 644 "$LOGFILE"

    # Log initial message
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] Initialized logging for $(basename "$0")" >> "$LOGFILE"
}

# Function to log messages with timestamp
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    if [[ -n "$LOGFILE" ]] && [[ -w "$LOGFILE" ]]; then
        echo "[$timestamp] [$level] $message" >> "$LOGFILE"
    else
        echo "[$timestamp] [$level] $message" >&2
    fi
}

# Function to execute commands with retries
retry_command() {
    local cmd="$1"
    local max_attempts=3
    local attempt=1
    local exit_code=0

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

# Function to wait for a command or process to finish with timeout
wait_for_command() {
    local cmd="$1"
    local timeout_seconds="${2:-60}" # Default 60 seconds
    local interval="${3:-5}"         # Default check every 5 seconds
    local elapsed=0

    log "INFO" "Waiting for command to finish (timeout: ${timeout_seconds}s): $cmd"

    while [ $elapsed -lt $timeout_seconds ]; do
        if eval "$cmd"; then
            log "INFO" "Command succeeded: $cmd"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        log "DEBUG" "Waiting... Elapsed: ${elapsed}s"
    done

    log "ERROR" "Timeout waiting for command: $cmd"
    return 1
}

# Function to check if a script has already been completed (based on a marker file)
is_script_completed() {
    local marker_file="$1"
    if [[ -f "$marker_file" ]]; then
        return 0  # Marker file found (completed)
    else
        return 1  # Marker file not found (not completed)
    fi
}

# Function to mark a script as completed (create a marker file)
mark_script_completed() {
    local marker_file="$1"
    touch "$marker_file"
    log "INFO" "Marked script as completed using marker: $marker_file"
}

# Function to clean up a marker file
cleanup_marker() {
    local marker_file="$1"
    if [[ -f "$marker_file" ]]; then
        rm -f "$marker_file"
        log "INFO" "Removed marker file: $marker_file"
    fi
}

# Ensure this script is sourced, not executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This script is intended to be sourced, not executed directly."
    exit 1
fi
