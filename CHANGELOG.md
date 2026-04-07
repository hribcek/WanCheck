# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `PING_TARGETS`: space-separated list of probe targets; WAN is UP if any responds (multi-host probe)
- `PING_TARGET`: kept as deprecated single-target fallback for backwards compatibility
- `DNS_PROBE_HOSTS`: space-separated list of hostnames for DNS connectivity probes; WAN is UP if any resolves
- `DNS_PROBE_HOST`: kept as deprecated single-host fallback for backwards compatibility
- `PROBE_MODE`: probe strategy — `ping` (default), `dns`, or `any` (pass if ping or DNS succeeds)
- `MANAGE_LINK_INTERNET`: enable/disable management of `link_internet` (default `true`; UP=2, DOWN=1)
- `MANAGE_WAN0_STATE`: enable/disable management of `wan0_state` (default `true`; UP=2, DOWN=3)
- `MANAGE_WAN0_REALSTATE`: enable/disable management of `wan0_realstate` (default `true`; UP=2, DOWN=0)
- `MANAGE_WANDUCK_STATE`: enable/disable management of `wanduck_state` (default `true`; UP=1, DOWN=0)
- `MANAGE_WAN0_AUXSTATE`: enable/disable management of `wan0_auxstate` (default `false`; UP=0, DOWN=2)
- `RESTART_WAN`: set to `true` to trigger a firmware WAN restart when the outage threshold is exceeded (default `false` — disabled pending a firm definition of "confirmed outage"; see README)
- `RESTART_WAN_CMD`: command executed to restart the WAN interface (default `service restart_wan_if 0`)
- `RESTART_COOLDOWN`: minimum seconds between successive WAN restart triggers (default `300`)

### Changed
- NVRAM variables are now each managed individually with hardcoded correct UP/DOWN values matching Asuswrt-Merlin firmware semantics, instead of a generic configurable slot
- `link_internet` DOWN value corrected from `0` to `1` (1=disconnected, not unknown)
- `wanduck_state` UP value corrected from `2` to `1` (1=active; there is no state 2)
- DNS probe now supports multiple hosts via `DNS_PROBE_HOSTS` (space-separated); single `DNS_PROBE_HOST` retained as deprecated fallback
- `nvram commit` is no longer called after writing WAN state variables; `nvram set` is used exclusively so that no flash sectors are written during normal monitoring operation. WAN state variables are transient runtime indicators — the WebUI reads them live from memory and they do not need to survive a reboot. This avoids flash wear and the risk of configuration corruption on power loss (see `docs/research/ASUS Router NVRAM Commit Behaviour...`)

### Removed
- `NVRAM_VAR`, `NVRAM_VAR2`, `STATE_UP`, `STATE_DOWN`, `NVRAM_VAR2_UP`, `NVRAM_VAR2_DOWN`: replaced by the specific `MANAGE_*` variables
- `EXTRA_NVRAM_VARS`: removed as cumbersome and a potential security concern; all relevant NVRAM variables are now managed individually by dedicated code

## [1.0.0] - 2026-XX-XX

### Added
- Initial release
- WAN connectivity monitoring
- ASUS Merlin firmware compatibility
- Basic status reporting

### Changed

### Deprecated

### Removed

### Fixed

### Security
