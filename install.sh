#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# install.sh — Deploy WanCheck to Asuswrt-Merlin JFFS persistent storage
# =============================================================================
# Run this script once on the router (via SSH or the router's admin console)
# to copy wancheck.sh to the JFFS partition and wire up a cron job that
# survives reboots.
#
# Usage:
#   sh install.sh [--uninstall]
#
# Prerequisites:
#   • JFFS2 partition enabled in the router admin UI
#     (Administration → System → Enable JFFS custom scripts and configs: Yes)
#   • wancheck.sh is present in the same directory as this script
# =============================================================================

set -e

SCRIPT_SRC="$(cd "$(dirname "$0")" && pwd)/wancheck.sh"
JFFS_SCRIPTS="/jffs/scripts"
JFFS_CONFIGS="/jffs/configs"
INSTALL_PATH="${JFFS_SCRIPTS}/wancheck.sh"
INIT_SCRIPT="${JFFS_SCRIPTS}/services-start"
CRON_TAG="wancheck"

# Default cron schedule: every 5 minutes
CRON_SCHEDULE="${CRON_SCHEDULE:-*/5 * * * *}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '[install] %s\n' "$*"; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "This script must be run as root."
}

check_jffs() {
    if [ ! -d "$JFFS_SCRIPTS" ]; then
        info "Creating ${JFFS_SCRIPTS} ..."
        mkdir -p "$JFFS_SCRIPTS" \
            || die "Could not create ${JFFS_SCRIPTS}. Is JFFS enabled?"
    fi
    if [ ! -d "$JFFS_CONFIGS" ]; then
        mkdir -p "$JFFS_CONFIGS"
    fi
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

do_install() {
    require_root
    check_jffs

    [ -f "$SCRIPT_SRC" ] || die "wancheck.sh not found at ${SCRIPT_SRC}"

    info "Copying wancheck.sh → ${INSTALL_PATH}"
    cp "$SCRIPT_SRC" "$INSTALL_PATH"
    chmod 755 "$INSTALL_PATH"

    # Register cron job using the Merlin 'cru' helper (persists via
    # /jffs/scripts/services-start which is sourced on every boot).
    info "Adding cron job: ${CRON_SCHEDULE} ${INSTALL_PATH}"
    cru a "$CRON_TAG" "${CRON_SCHEDULE} ${INSTALL_PATH}"

    # Persist the cron registration across reboots via services-start
    _persist_cron

    info "Installation complete."
    info "  Script : ${INSTALL_PATH}"
    info "  Cron   : ${CRON_SCHEDULE} (tag: ${CRON_TAG})"
    info "  Log    : /tmp/wancheck.log"
}

# Append the cru registration to services-start so it survives reboots.
_persist_cron() {
    local marker="# wancheck-cron"
    local entry="cru a ${CRON_TAG} \"${CRON_SCHEDULE} ${INSTALL_PATH}\""

    if [ ! -f "$INIT_SCRIPT" ]; then
        info "Creating ${INIT_SCRIPT}"
        printf '#!/bin/sh\n' > "$INIT_SCRIPT"
        chmod 755 "$INIT_SCRIPT"
    fi

    if grep -q "$marker" "$INIT_SCRIPT" 2>/dev/null; then
        info "services-start already contains wancheck cron entry — skipping."
    else
        info "Appending cron registration to ${INIT_SCRIPT}"
        printf '\n%s\n%s\n' "$marker" "$entry" >> "$INIT_SCRIPT"
    fi
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

do_uninstall() {
    require_root

    info "Removing cron job (tag: ${CRON_TAG})"
    cru d "$CRON_TAG" 2>/dev/null || true

    if [ -f "$INIT_SCRIPT" ]; then
        info "Removing cron entry from ${INIT_SCRIPT}"
        # Remove the marker line and the cru command line that follows it
        sed -i "/# wancheck-cron/,+1d" "$INIT_SCRIPT"
    fi

    if [ -f "$INSTALL_PATH" ]; then
        info "Removing ${INSTALL_PATH}"
        rm -f "$INSTALL_PATH"
    fi

    info "Cleaning up temporary files"
    rm -f /tmp/wancheck.lock /tmp/wancheck_down_since /tmp/wancheck.log

    info "Uninstall complete."
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

case "${1:-}" in
    --uninstall|-u)
        do_uninstall
        ;;
    ""|--install|-i)
        do_install
        ;;
    *)
        printf 'Usage: %s [--install | --uninstall]\n' "$0" >&2
        exit 1
        ;;
esac
