# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `PING_TARGETS`: space-separated list of probe targets; WAN is UP if any responds (multi-host probe)
- `PING_TARGET`: kept as deprecated single-target fallback for backwards compatibility
- `DNS_PROBE_HOST`: optional hostname to resolve as a DNS connectivity check
- `PROBE_MODE`: probe strategy — `ping` (default), `dns`, or `any` (pass if ping or DNS succeeds)
- `RESTART_WAN`: set to `true` to trigger a firmware WAN restart when the outage threshold is exceeded (default `false`)
- `RESTART_WAN_CMD`: command executed to restart the WAN interface (default `service restart_wan_if 0`)
- `RESTART_COOLDOWN`: minimum seconds between successive WAN restart triggers (default `300`)
- `NVRAM_VAR2_UP` / `NVRAM_VAR2_DOWN`: per-variable up/down overrides for the second primary NVRAM variable

### Changed
- Default `NVRAM_VAR` changed from `wanduck_state` to `link_internet` (correct WebUI globe-icon variable)
- Default `NVRAM_VAR2` changed from `link_internet` to empty (disabled); `link_internet` is now the primary
- Default `STATE_DOWN` changed from `0` to `1` to match `link_internet` semantics (1=disconnected)
- Default `EXTRA_NVRAM_VARS` now pre-populates `wan0_state:2:3 wan0_realstate:2:0 wanduck_state:1:0` for correct out-of-box WebUI accuracy; set to `""` to disable

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
