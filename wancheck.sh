#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# wancheck.sh — WAN Connection Monitor for Asuswrt-Merlin
# =============================================================================
# Monitors WAN connectivity by pinging a configurable target and keeps
# NVRAM state variables (wanduck_state, link_internet, + any extras) in sync.
#
# Intended deployment:  /jffs/scripts/wancheck.sh
# Cron schedule (normal): every 5 minutes via the Merlin cru helper
#   cru a wancheck "*/5 * * * * /jffs/scripts/wancheck.sh"
#
# During an outage the script enters a fast-polling loop and only commits
# a DOWN state to NVRAM after DOWN_THRESHOLD seconds have elapsed without
# a successful ping, preventing false alarms from short transient blips.
# =============================================================================

# ---------------------------------------------------------------------------
# Configuration — edit to suit your environment
# ---------------------------------------------------------------------------

# IP or hostname to ping for WAN verification
PING_TARGET="${PING_TARGET:-8.8.8.8}"

# Number of ICMP echo requests to send per ping attempt
PING_COUNT="${PING_COUNT:-3}"

# Seconds to wait for each ping response
PING_TIMEOUT="${PING_TIMEOUT:-3}"

# Primary NVRAM variable whose value reflects WAN status
NVRAM_VAR="${NVRAM_VAR:-wanduck_state}"

# Second primary NVRAM variable that also reflects WAN/internet status.
# Set to an empty string to disable management of this variable.
NVRAM_VAR2="${NVRAM_VAR2:-link_internet}"

# NVRAM integer value that represents the connected (UP) state
STATE_UP="${STATE_UP:-2}"

# NVRAM integer value that represents the disconnected (DOWN) state
STATE_DOWN="${STATE_DOWN:-0}"

# Space-separated list of additional NVRAM variables to keep in sync.
# Each entry may optionally carry per-variable up/down overrides using
# the format  "varname:up_val:down_val"  (colon-separated).
# Example:  EXTRA_NVRAM_VARS="wan0_state_t:2:0 custom_flag:1:0"
EXTRA_NVRAM_VARS="${EXTRA_NVRAM_VARS:-}"

# Seconds a WAN outage must persist before STATE_DOWN is written to NVRAM
DOWN_THRESHOLD="${DOWN_THRESHOLD:-30}"

# Seconds between connectivity checks while in fast-polling (outage) mode
FAST_POLL_INTERVAL="${FAST_POLL_INTERVAL:-5}"

# ---------------------------------------------------------------------------
# Internal constants — normally no need to change these
# ---------------------------------------------------------------------------

SCRIPT_NAME="wancheck"
LOCK_FILE="${LOCK_FILE:-/tmp/${SCRIPT_NAME}.lock}"
STATE_FILE="${STATE_FILE:-/tmp/${SCRIPT_NAME}_down_since}"
LOG_FILE="${LOG_FILE:-/tmp/${SCRIPT_NAME}.log}"

# Maximum log size in bytes before the log is rotated (default 256 KB)
LOG_MAX_BYTES="${LOG_MAX_BYTES:-262144}"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

_log() {
    local level="$1"
    shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"

    # Rotate log if it exceeds LOG_MAX_BYTES
    if [ -f "$LOG_FILE" ]; then
        local size
        size="$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)"
        if [ "$size" -ge "$LOG_MAX_BYTES" ]; then
            mv "$LOG_FILE" "${LOG_FILE}.1"
        fi
    fi

    printf '%s [%s] %s\n' "$ts" "$level" "$*" >> "$LOG_FILE"
}

log_info()  { _log "INFO " "$@"; }
log_warn()  { _log "WARN " "$@"; }
log_error() { _log "ERROR" "$@"; }

# ---------------------------------------------------------------------------
# Lock helpers — prevent overlapping cron invocations
# ---------------------------------------------------------------------------

acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid
        pid="$(cat "$LOCK_FILE" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log_warn "Another instance (PID $pid) is already running. Exiting."
            exit 0
        fi
        log_warn "Stale lock file found (PID $pid). Removing."
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() {
    rm -f "$LOCK_FILE"
}

# ---------------------------------------------------------------------------
# NVRAM helpers
# ---------------------------------------------------------------------------

nvram_get_val() {
    # Usage: nvram_get_val <variable>
    nvram get "$1" 2>/dev/null
}

nvram_set_val() {
    # Usage: nvram_set_val <variable> <value>
    nvram set "${1}=${2}" 2>/dev/null
    nvram commit 2>/dev/null
}

# Write the primary NVRAM variables (wanduck_state + link_internet) and any
# extras with the given state value.  For extra variables that specify their
# own up/down values the appropriate per-variable value is used; otherwise
# STATE_UP / STATE_DOWN is used.
set_nvram_state() {
    local target_state="$1"   # "UP" or "DOWN"
    local primary_val

    if [ "$target_state" = "UP" ]; then
        primary_val="$STATE_UP"
    else
        primary_val="$STATE_DOWN"
    fi

    local current

    # ---- NVRAM_VAR (wanduck_state) ----
    current="$(nvram_get_val "$NVRAM_VAR")"
    if [ "$current" != "$primary_val" ]; then
        log_info "Setting NVRAM ${NVRAM_VAR}=${primary_val} (was ${current})"
        nvram_set_val "$NVRAM_VAR" "$primary_val"
    fi

    # ---- NVRAM_VAR2 (link_internet) — skip if empty ----
    if [ -n "$NVRAM_VAR2" ]; then
        current="$(nvram_get_val "$NVRAM_VAR2")"
        if [ "$current" != "$primary_val" ]; then
            log_info "Setting NVRAM ${NVRAM_VAR2}=${primary_val} (was ${current})"
            nvram_set_val "$NVRAM_VAR2" "$primary_val"
        fi
    fi

    # ---- Extra variables ----
    for entry in $EXTRA_NVRAM_VARS; do
        local var up_val down_val val
        var="${entry%%:*}"
        up_down_part="${entry#*:}"
        if [ "$up_down_part" = "$entry" ]; then
            # No colon — use global defaults
            up_val="$STATE_UP"
            down_val="$STATE_DOWN"
        else
            up_val="${up_down_part%%:*}"
            down_val_part="${up_down_part#*:}"
            if [ "$down_val_part" = "$up_down_part" ]; then
                down_val="$STATE_DOWN"
            else
                down_val="$down_val_part"
            fi
        fi

        if [ "$target_state" = "UP" ]; then
            val="$up_val"
        else
            val="$down_val"
        fi

        current="$(nvram_get_val "$var")"
        if [ "$current" != "$val" ]; then
            log_info "Setting NVRAM ${var}=${val} (was ${current})"
            nvram_set_val "$var" "$val"
        fi
    done
}

# ---------------------------------------------------------------------------
# Connectivity check
# ---------------------------------------------------------------------------

wan_is_up() {
    ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$PING_TARGET" \
        > /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# DOWN-state timestamp helpers
# ---------------------------------------------------------------------------

# Record the epoch when the outage started (only on first call)
record_down_start() {
    if [ ! -f "$STATE_FILE" ]; then
        date '+%s' > "$STATE_FILE"
        log_info "Outage detected. Recording start time."
    fi
}

# Return the epoch stored in STATE_FILE, or empty string if not set
down_start_epoch() {
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE" 2>/dev/null
    fi
}

# Remove the outage-start timestamp
clear_down_start() {
    rm -f "$STATE_FILE"
}

# Return 0 (true) if the outage has persisted longer than DOWN_THRESHOLD
down_threshold_exceeded() {
    local start
    start="$(down_start_epoch)"
    [ -z "$start" ] && return 1
    local now
    now="$(date '+%s')"
    local elapsed=$(( now - start ))
    [ "$elapsed" -ge "$DOWN_THRESHOLD" ]
}

# ---------------------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------------------

main() {
    acquire_lock
    trap 'release_lock' EXIT INT TERM

    log_info "=== WanCheck starting (PID $$) ==="
    log_info "Target: ${PING_TARGET}, NVRAM vars: ${NVRAM_VAR}, ${NVRAM_VAR2}, UP=${STATE_UP}, DOWN=${STATE_DOWN}"

    if wan_is_up; then
        # ----- WAN is UP on entry -----
        log_info "WAN UP."
        clear_down_start
        set_nvram_state UP
    else
        # ----- WAN appears DOWN -----
        log_warn "WAN DOWN — entering fast-polling loop (interval=${FAST_POLL_INTERVAL}s, threshold=${DOWN_THRESHOLD}s)."
        record_down_start

        while true; do
            if wan_is_up; then
                log_info "WAN recovered."
                clear_down_start
                set_nvram_state UP
                break
            fi

            # Still down — check threshold
            if down_threshold_exceeded; then
                log_warn "Outage exceeded ${DOWN_THRESHOLD}s threshold. Committing DOWN state to NVRAM."
                set_nvram_state DOWN
            else
                local start elapsed remaining
                start="$(down_start_epoch)"
                elapsed=$(( $(date '+%s') - start ))
                remaining=$(( DOWN_THRESHOLD - elapsed ))
                log_info "Still down (${elapsed}s elapsed, ${remaining}s until NVRAM commit)."
            fi

            sleep "$FAST_POLL_INTERVAL"
        done
    fi

    log_info "=== WanCheck done ==="
}

main "$@"
