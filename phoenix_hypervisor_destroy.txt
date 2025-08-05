#!/bin/bash
# Phoenix Hypervisor Destroy Script
# Tears down resources created by phoenix_hypervisor_establish.sh.
# Supports destroying all LXCs or a specific one.
# Stops and destroys LXCs, removes marker files, and systemd services created within LXCs.
# Optionally removes log files and marker/status directories.
# Does NOT destroy core Proxmox resources like datasets, pools, or templates.
# Prerequisites:
# - Proxmox VE 8.x
# - phoenix_hypervisor_common.sh and phoenix_hypervisor_config.sh (for LXC config loading if targeting specific LXC)
# - jq installed (for LXC config loading)
# Usage: ./phoenix_hypervisor_destroy.sh [--lxc-id <ID>] [--remove-logs] [--force]
# Version: 1.1.0 (Refined for REQ-003 with selective and interactive destruction)
# Author: Assistant

set -euo pipefail

# --- Default Configuration (Aligns with common.sh/config.sh defaults or env vars if sourced) ---
# These defaults are used if sourcing config fails or for specific paths.
DEFAULT_HYPERVISOR_MARKER_DIR="/var/log/phoenix_hypervisor_markers"
DEFAULT_HYPERVISOR_LOGFILE="/var/log/phoenix_hypervisor/phoenix_hypervisor.log"
DEFAULT_PHOENIX_LXC_CONFIG_FILE="/usr/local/etc/phoenix_lxc_configs.json"

# --- Argument Parsing ---
TARGET_LXC_ID=""
REMOVE_LOGS=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --lxc-id)
      TARGET_LXC_ID="$2"
      if [[ -z "$TARGET_LXC_ID" ]] || ! [[ "$TARGET_LXC_ID" =~ ^[0-9]+$ ]]; then
          echo "Error: --lxc-id requires a valid numeric LXC ID." >&2
          exit 1
      fi
      shift 2
      ;;
    --remove-logs)
      REMOVE_LOGS=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--lxc-id <ID>] [--remove-logs] [--force]"
      echo "  --lxc-id <ID>      : Destroy only the specified LXC ID and its related markers."
      echo "                       If not provided, attempts to destroy all LXCs found in config."
      echo "  --remove-logs      : Also remove the log file and marker/status directory."
      echo "  --force            : Skip confirmation prompts (except for individual LXCs if --lxc-id not specified)."
      echo "                       Use with caution."
      exit 0
      ;;
    *)
      echo "Error: Unknown option $1" >&2
      echo "Usage: $0 [--lxc-id <ID>] [--remove-logs] [--force]" >&2
      exit 1
      ;;
  esac
done

# --- Attempt to Source Configuration for Paths and LXC Info ---
# Try to get paths from the common/config setup if possible.
# This makes it consistent with how establish_hypervisor.sh determines paths (REQ-004).
# We need to be careful not to fail if config sourcing fails, especially for log paths.
HYPERVISOR_MARKER_DIR=""
HYPERVISOR_LOGFILE=""
PHOENIX_LXC_CONFIG_FILE=""

# Temporarily disable exit on error to handle potential sourcing issues gracefully for path discovery
set +e
if source /usr/local/bin/phoenix_hypervisor_common.sh 2>/dev/null && \
   source /usr/local/bin/phoenix_hypervisor_config.sh 2>/dev/null; then
    # Sourcing successful, paths should be set by config.sh (which calls common.sh logic)
    # Re-check root as config.sh usually does this
    check_root > /dev/null 2>&1 || true # Ignore if check_root logs to a file not yet set up
    # Load config to get LXC list if needed
    load_hypervisor_config > /dev/null 2>&1 || true # Ignore if this fails before logging is fully up
    # Use the potentially overridden paths
    HYPERVISOR_MARKER_DIR="$HYPERVISOR_MARKER_DIR" # From exported var in config/common
    HYPERVISOR_LOGFILE="$HYPERVISOR_LOGFILE"       # From exported var in config/common
    PHOENIX_LXC_CONFIG_FILE="$PHOENIX_LXC_CONFIG_FILE" # From exported var in config/common
fi
set -e # Re-enable exit on error

# If sourcing failed or paths are still empty, use defaults
HYPERVISOR_MARKER_DIR="${HYPERVISOR_MARKER_DIR:-$DEFAULT_HYPERVISOR_MARKER_DIR}"
HYPERVISOR_LOGFILE="${HYPERVISOR_LOGFILE:-$DEFAULT_HYPERVISOR_LOGFILE}"
PHOENIX_LXC_CONFIG_FILE="${PHOENIX_LXC_CONFIG_FILE:-$DEFAULT_PHOENIX_LXC_CONFIG_FILE}"

# --- Logging Setup (Basic, file might be removed) ---
# We need a basic way to log actions, even if the main log is being removed.
# Use a temporary log or the main log file location.
TEMP_LOG=""
if [[ "$REMOVE_LOGS" == true ]]; then
    TEMP_LOG=$(mktemp)
    exec 1>>"$TEMP_LOG" 2>&1
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Logging to temporary file: $TEMP_LOG (Main log may be removed)"
else
    # Ensure the main log directory exists and set up logging to it
    mkdir -p "$(dirname "$HYPERVISOR_LOGFILE")"
    touch "$HYPERVISOR_LOGFILE"
    exec 1>>"$HYPERVISOR_LOGFILE" 2>&1
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [INFO] Starting phoenix_hypervisor_destroy.sh"

# --- Helper Function: Log ---
log() {
    local level="$1"
    shift
    local message="$*"
    # Log to the determined output (temp file or main log)
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [$level] $message"
    # Also echo critical info/errors to terminal if not forced
    if [[ "$level" == "INFO" ]] || [[ "$level" == "WARN" ]] || [[ "$level" == "ERROR" ]]; then
        if [[ "$FORCE" == false ]] || [[ "$level" == "ERROR" ]]; then
             # Send to original stderr (usually terminal) if available
             echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [$level] $message" >&3
        fi
    fi
}

# --- Re-open stderr to terminal (fd 3) for user prompts ---
# This allows prompts and critical messages to reach the user even if stdout is redirected to a log.
exec 3>/dev/tty

# --- Function: get_lxc_name_from_config ---
# Description: Retrieves the LXC name from the JSON config for a given ID.
# Parameters: lxc_id
# Returns: name (or empty string if not found/error)
get_lxc_name_from_config() {
    local lxc_id="$1"
    local name=""
    if [[ -f "$PHOENIX_LXC_CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1; then
        name=$(jq -r --argjson id "$lxc_id" '.lxc_configs[$id].name // ""' "$PHOENIX_LXC_CONFIG_FILE" 2>/dev/null)
    fi
    echo "$name"
}

# --- Function: destroy_lxc ---
# Description: Stops, destroys an LXC, removes its specific marker files, and systemd service.
# Parameters: lxc_id
# Returns: 0 on success or if LXC doesn't exist, 1 on failure
destroy_lxc() {
    local lxc_id="$1"
    log "INFO" "Attempting to destroy LXC $lxc_id..."

    # Validate LXC ID format (basic check)
    if ! [[ "$lxc_id" =~ ^[0-9]+$ ]]; then
        log "WARN" "Skipping LXC $lxc_id - Invalid ID format."
        return 1
    fi

    # --- Individual LXC Confirmation (unless --force) ---
    if [[ "$FORCE" == false ]]; then
        # Get name for better prompt
        local lxc_name
        lxc_name=$(get_lxc_name_from_config "$lxc_id")
        local prompt_msg="Are you sure you want to DESTROY LXC $lxc_id"
        if [[ -n "$lxc_name" ]]; then
            prompt_msg+=" ($lxc_name)"
        fi
        prompt_msg+="? Type 'yes' to confirm: "
        read -u 3 -p "$prompt_msg" confirmation
        echo >&3 # Newline after input
        if [[ "$confirmation" != "yes" ]]; then
            log "INFO" "Destruction of LXC $lxc_id cancelled by user."
            echo "Destruction of LXC $lxc_id skipped." >&3
            return 0 # Not an error, just skipped
        fi
    fi

    # Check if LXC exists using pct
    if ! pct status "$lxc_id" >/dev/null 2>&1; then
        log "INFO" "LXC $lxc_id does not exist or is not managed by pct. Skipping LXC destruction."
    else
        # Stop the LXC if it's running
        if pct status "$lxc_id" | grep -q "status: running"; then
            log "INFO" "Stopping LXC $lxc_id..."
            if ! timeout 60 pct stop "$lxc_id"; then # Add timeout to prevent hanging
                log "WARN" "Failed to stop LXC $lxc_id within 60 seconds. Attempting to destroy anyway."
            else
                log "INFO" "LXC $lxc_id stopped."
            fi
        else
             log "DEBUG" "LXC $lxc_id is not running."
        fi

        # Destroy the LXC
        log "INFO" "Destroying LXC $lxc_id..."
        if ! timeout 120 pct destroy "$lxc_id"; then # Add timeout
            log "ERROR" "Failed to destroy LXC $lxc_id."
             # Don't exit, continue to clean up markers
             # return 1 # Considered soft failure for overall script if continuing
        else
            log "INFO" "LXC $lxc_id destroyed."
        fi
    fi

    # Remove LXC-specific marker files
    log "INFO" "Removing marker files for LXC $lxc_id..."
    local lxc_marker_files=(
        "${HYPERVISOR_MARKER_DIR}/lxc_${lxc_id}_created.marker"
        "${HYPERVISOR_MARKER_DIR}/lxc_${lxc_id}_gpu_configured.marker"
        # Add marker files for other specific setup scripts if they follow a pattern
        # e.g., "${HYPERVISOR_MARKER_DIR}/lxc_${lxc_id}_setup_<name>.marker"
        "${HYPERVISOR_MARKER_DIR}/lxc_${lxc_id}_setup_drdevstral.marker" # Example
    )

    local marker_removed=false
    for marker in "${lxc_marker_files[@]}"; do
        if [[ -f "$marker" ]]; then
            log "INFO" "Removing marker file: $marker"
            rm -f "$marker" || log "WARN" "Failed to remove marker file: $marker"
            marker_removed=true
        else
            log "DEBUG" "Marker file not found (skipping): $marker"
        fi
    done
    if [[ "$marker_removed" == false ]]; then
        log "INFO" "No marker files found for LXC $lxc_id to remove."
    fi

    # Attempt to remove systemd service inside the LXC (best effort)
    local lxc_name_for_service
    lxc_name_for_service=$(get_lxc_name_from_config "$lxc_id")
    if [[ -n "$lxc_name_for_service" ]]; then
         log "INFO" "Attempting to remove systemd service 'vllm-${lxc_name_for_service}.service' from LXC $lxc_id (if accessible)..."
         # These commands are best-effort. They will likely fail if LXC is destroyed.
         # We can try, but failure is expected and not critical.
         # Use a short timeout for pct exec to prevent hanging if LXC is down.
         timeout 10 pct exec "$lxc_id" -- systemctl stop "vllm-${lxc_name_for_service}.service" || true
         timeout 10 pct exec "$lxc_id" -- systemctl disable "vllm-${lxc_name_for_service}.service" || true
         timeout 10 pct exec "$lxc_id" -- rm -f "/etc/systemd/system/vllm-${lxc_name_for_service}.service" || true
         timeout 10 pct exec "$lxc_id" -- systemctl daemon-reload || true
         log "INFO" "Cleanup commands for 'vllm-${lxc_name_for_service}.service' sent to LXC $lxc_id (success not guaranteed)."
    else
         log "WARN" "Could not determine name for LXC $lxc_id from config to clean up systemd service."
    fi

    log "INFO" "Completed destruction steps for LXC $lxc_id."
    return 0
}

# --- Main Destruction Logic ---

# --- Overall Confirmation (unless --force or --lxc-id specified) ---
if [[ "$FORCE" == false ]] && [[ -z "$TARGET_LXC_ID" ]]; then
  echo >&3
  echo "WARNING: This script will attempt to destroy Phoenix Hypervisor resources." >&3
  echo "This includes:" >&3
  echo "  - Stopping and destroying LXC containers (as defined in config or specified)." >&3
  echo "  - Removing marker files used for idempotency." >&3
  echo "  - Attempting to remove systemd services inside LXCs (best effort)." >&3
  echo "" >&3
  echo "It will NOT destroy:" >&3
  echo "  - ZFS datasets or pools." >&3
  echo "  - Proxmox storage configurations." >&3
  echo "  - LXC templates." >&3
  echo "  - System-wide packages (Docker, NVIDIA runtime)." >&3
  echo "" >&3
  if [[ "$REMOVE_LOGS" == true ]]; then
      echo "It WILL remove:" >&3
      echo "  - Log file: $HYPERVISOR_LOGFILE" >&3
      echo "  - Marker directory: $HYPERVISOR_MARKER_DIR" >&3
      echo "" >&3
  fi
  read -u 3 -p "Are you sure you want to proceed with destroying ALL configured LXCs? Type 'yes' to confirm: " confirmation
  echo >&3 # Newline after input
  if [[ "$confirmation" != "yes" ]]; then
    log "INFO" "Overall destruction cancelled by user."
    echo "Destruction cancelled." >&3
    # Clean up temp log if it was used
    if [[ -n "$TEMP_LOG" ]] && [[ -f "$TEMP_LOG" ]]; then rm -f "$TEMP_LOG"; fi
    exit 0
  fi
fi

# --- Determine LXCs to Destroy ---
declare -a LXCS_TO_DESTROY

if [[ -n "$TARGET_LXC_ID" ]]; then
    # Targeting a specific LXC
    log "INFO" "Targeting specific LXC ID for destruction: $TARGET_LXC_ID"
    LXCS_TO_DESTROY=("$TARGET_LXC_ID")
else
    # Targeting all LXCs from config
    log "INFO" "Attempting to load LXC configurations to destroy all..."
    # Try to load LXC IDs from config
    if [[ -f "$PHOENIX_LXC_CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1; then
        mapfile -t ALL_LXC_IDS < <(jq -r '.lxc_configs | keys[]' "$PHOENIX_LXC_CONFIG_FILE" 2>/dev/null)
        if [[ ${#ALL_LXC_IDS[@]} -gt 0 ]]; then
            log "INFO" "Found LXC IDs in config: ${ALL_LXC_IDS[*]}"
            LXCS_TO_DESTROY=("${ALL_LXC_IDS[@]}")
        else
            log "WARN" "No LXC IDs found in $PHOENIX_LXC_CONFIG_FILE or jq failed to parse keys."
        fi
    else
        log "WARN" "Could not load LXC config file ($PHOENIX_LXC_CONFIG_FILE) or jq not found. Cannot determine list of all LXCs to destroy."
    fi

    # Fallback: Check for existing marker files to infer LXC IDs
    if [[ ${#LXCS_TO_DESTROY[@]} -eq 0 ]] && [[ -d "$HYPERVISOR_MARKER_DIR" ]]; then
        log "INFO" "Falling back to scanning marker directory for LXC IDs."
        mapfile -t MARKER_LXC_IDS < <(find "$HYPERVISOR_MARKER_DIR" -maxdepth 1 -name 'lxc_*_created.marker' -exec basename {} _created.marker \; | cut -d'_' -f2 | sort -u)
        if [[ ${#MARKER_LXC_IDS[@]} -gt 0 ]]; then
            log "INFO" "Inferred LXC IDs from marker files: ${MARKER_LXC_IDS[*]}"
            LXCS_TO_DESTROY=("${MARKER_LXC_IDS[@]}")
        else
             log "INFO" "No LXC IDs inferred from marker files either."
        fi
    fi

    if [[ ${#LXCS_TO_DESTROY[@]} -eq 0 ]]; then
        log "WARN" "No LXC IDs identified for destruction (from config or markers). Nothing to destroy based on config."
        echo "No LXC IDs found to destroy." >&3
    fi
fi

# --- Destroy Identified LXCs ---
for lxc_id in "${LXCS_TO_DESTROY[@]}"; do
    destroy_lxc "$lxc_id"
    # Note: We continue even if one LXC fails, trying to clean up others.
done

# --- Remove Global Marker File (if destroying all or if it exists and user wants cleanup) ---
if [[ -z "$TARGET_LXC_ID" ]]; then # Only for "destroy all"
    GLOBAL_MARKER_FILE="${HYPERVISOR_MARKER_DIR}/establish_hypervisor.marker"
    if [[ -f "$GLOBAL_MARKER_FILE" ]]; then
        log "INFO" "Removing global marker file: $GLOBAL_MARKER_FILE"
        rm -f "$GLOBAL_MARKER_FILE" || log "WARN" "Failed to remove global marker file: $GLOBAL_MARKER_FILE"
    else
        log "DEBUG" "Global marker file not found: $GLOBAL_MARKER_FILE"
    fi
fi

# --- Remove Initial Setup Marker File (if destroying all) ---
if [[ -z "$TARGET_LXC_ID" ]]; then # Only for "destroy all"
    INITIAL_MARKER_FILE="${HYPERVISOR_MARKER_DIR}/initial_setup.marker"
    if [[ -f "$INITIAL_MARKER_FILE" ]]; then
        log "INFO" "Removing initial setup marker file: $INITIAL_MARKER_FILE"
        rm -f "$INITIAL_MARKER_FILE" || log "WARN" "Failed to remove initial setup marker file: $INITIAL_MARKER_FILE"
    else
        log "DEBUG" "Initial setup marker file not found: $INITIAL_MARKER_FILE"
    fi
fi

# --- Remove Log Files and Marker Directory (if requested) ---
if [[ "$REMOVE_LOGS" == true ]]; then
    log "INFO" "Removing log files and marker directory as requested..."
    if [[ -f "$HYPERVISOR_LOGFILE" ]]; then
        log "INFO" "Removing log file: $HYPERVISOR_LOGFILE"
        rm -f "$HYPERVISOR_LOGFILE" || log "WARN" "Failed to remove log file: $HYPERVISOR_LOGFILE"
    else
        log "DEBUG" "Log file not found: $HYPERVISOR_LOGFILE"
    fi

    if [[ -d "$HYPERVISOR_MARKER_DIR" ]]; then
        log "INFO" "Removing marker directory: $HYPERVISOR_MARKER_DIR"
        rm -rf "$HYPERVISOR_MARKER_DIR" || log "WARN" "Failed to remove marker directory: $HYPERVISOR_MARKER_DIR"
    else
        log "DEBUG" "Marker directory not found: $HYPERVISOR_MARKER_DIR"
    fi
fi

# --- Note about Secrets/Keys ---
log "INFO" "NOTE: Hugging Face token and LXC root password files have NOT been deleted."
log "INFO" "      Please remove them manually if no longer needed:"
log "INFO" "        - ${PHOENIX_HF_TOKEN_FILE:-/usr/local/etc/phoenix_hf_token.conf}"
log "INFO" "        - ${PHOENIX_LXC_ROOT_PASSWD_FILE:-/root/.phoenix_lxc_root_passwd}"
log "INFO" "NOTE: Host encryption key has NOT been deleted."
log "INFO" "      Please remove it manually if no longer needed:"
log "INFO" "        - ${PHOENIX_SECRET_KEY_FILE:-/etc/phoenix/secret.key}" # Assuming default path from REQ-001 impl

log "INFO" "Completed phoenix_hypervisor_destroy.sh run."
echo "Destruction process finished. Review logs for details." >&3
if [[ -n "$TEMP_LOG" ]] && [[ -f "$TEMP_LOG" ]]; then
    echo "Temporary log file (not removed): $TEMP_LOG" >&3
    # Note: Temp log is not removed automatically to allow review.
fi
if [[ "$REMOVE_LOGS" == false ]]; then
    echo "Main log file: $HYPERVISOR_LOGFILE" >&3
fi
exit 0