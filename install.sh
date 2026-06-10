#!/bin/sh
# shellcheck shell=ash
# =============================================================================
# install.sh — Deploy WanMoth to Asuswrt-Merlin JFFS persistent storage
# =============================================================================
# Run this script once on the router (via SSH or the router's admin console)
# to copy wanmoth to the JFFS partition and wire up a cron job that
# survives reboots.
#
# Usage:
#   sh install.sh [--install] [--dry-run]
#   sh install.sh --uninstall
#
#   --dry-run / -d   Install with DRY_RUN=true so wanmoth logs what it would
#                    do without writing NVRAM or restarting the WAN interface.
#                    Useful for observing behaviour before going live.
#
# Prerequisites:
#   • JFFS2 partition enabled in the router admin UI
#     (Administration → System → Enable JFFS custom scripts and configs: Yes)
#   • wanmoth is present in the same directory as this script
# =============================================================================

set -e

scriptName="wanmoth"
scriptSrc="$(cd "$(dirname "$0")" && pwd)/${scriptName}"

jffsScripts="/jffs/scripts"
jffsConfigs="/jffs/configs"
installPath="${jffsScripts}/${scriptName}"
initScript="${jffsScripts}/services-start"

# Marker for installation in services-start
scriptTag="# ${scriptName}"

# Default cron schedule: every 5 minutes
cronSchedule="${cronSchedule:-*/5 * * * *}"
cronTag="${scriptName}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}
info() {
  printf '[install] %s\n' "$*"
}

check_jffs() {
  if [ ! -d "${jffsScripts}" ]; then
    info "Creating ${jffsScripts} ..."
    mkdir -p "${jffsScripts}" || die "Could not create ${jffsScripts}. Is JFFS enabled?"
  fi
  if [ ! -d "${jffsConfigs}" ]; then
    mkdir -p "${jffsConfigs}" || die "Could not create ${jffsConfigs}. Is JFFS enabled?"
  fi
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

do_install() {
  check_jffs

  if [ ! -f "${scriptSrc}" ]; then
    die "${scriptName} not found at ${scriptSrc}"
  fi

  # Build the command that cron will invoke.
  # When dry-run mode is requested, prefix DRY_RUN=true so the script logs
  # what it would do without writing NVRAM or restarting the WAN interface.
  local cronCmd
  if [ "${dryRun}" = "true" ]; then
    cronCmd="DRY_RUN=true ${installPath}"
  else
    cronCmd="${installPath}"
  fi

  info "Copying ${scriptName} -> ${installPath}"
  cp -f "${scriptSrc}" "${installPath}" || die "Failed to copy ${scriptName} to ${installPath}"
  chmod 755 "${installPath}" || die "Failed to set executable permissions on ${installPath}"

  # Register cron job using the Merlin 'cru' helper (persists via
  # /jffs/scripts/services-start which is sourced on every boot).
  info "Adding cron job: ${cronSchedule} ${cronCmd}"
  cru a "${cronTag}" "${cronSchedule} ${cronCmd}"

  # Persist the cron registration across reboots via services-start
  _persist_cron "${cronCmd}"

  info "Installation complete."
  info "  Script : ${installPath}"
  info "  Cron   : ${cronSchedule} (tag: ${cronTag})"
  [ "${dryRun}" = "true" ] && info "  Dry-run: yes — WAN state changes will be logged only"
}

# Append the cru registration to services-start so it survives reboots.
_persist_cron() {
  local cronCmd="$1"
  local entry="cru a ${cronTag} \"${cronSchedule} ${cronCmd}\"  ${scriptTag}"

  if [ ! -f "${initScript}" ]; then
    info "Creating ${initScript}"
    printf '#!/bin/sh\n' > "${initScript}"
    chmod 755 "${initScript}"
  fi

  if grep -q "${scriptTag}" "${initScript}" 2>/dev/null; then
    info "services-start already contains ${scriptName} entry - skipping."
  else
    info "Appending cron registration to ${initScript}"
    printf '\n%s\n' "${entry}" >> "${initScript}"
  fi
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

do_uninstall() {
  info "Removing cron job (tag: ${cronTag})"
  cru d "${cronTag}" 2>/dev/null || true

  if [ -f "${initScript}" ]; then
    info "Removing entry from ${initScript}"
    # Remove lines previously added by this installer.
    sed -i "/${scriptTag}/d" "${initScript}" 2>/dev/null || true
  fi

  if [ -f "${installPath}" ]; then
    info "Removing ${installPath}"
    rm -f "${installPath}"
  fi

  info "Cleaning up temporary files"
  rm -f "/tmp/${scriptName}.lock" "/tmp/${scriptName}_down_since"

  info "Uninstall complete."
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

dryRun=false
action=install

for arg in "$@"; do
  case "${arg}" in
    --dry-run|-d)   dryRun=true ;;
    --uninstall|-u) action=uninstall ;;
    --install|-i)   action=install ;;
    *)
      printf 'Usage: %s [--install] [--dry-run] | --uninstall\n' "$0" >&2
      exit 1
      ;;
  esac
done

case "${action}" in
  uninstall) do_uninstall ;;
  install)   do_install ;;
  *)         printf 'Internal error: unknown action "%s"\n' "${action}" >&2; exit 1 ;;
esac
