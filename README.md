# WanMoth

A lightweight, persistent WAN-connection monitoring script for
**Asuswrt-Merlin** routers. It probes connectivity via ICMP ping and/or DNS
lookups against one or more configurable targets and keeps the key NVRAM state
variables (`link_internet`, `wan0_state`, `wan0_realstate`, `wanduck_state`)
accurately reflecting the WAN status — surviving reboots thanks to the
router's JFFS2 persistent partition.

---

## Features

| Feature | Detail |
|---|---|
| **Accurate state tracking** | NVRAM is only set to DOWN after a configurable silence threshold, preventing false alarms from brief transient blips |
| **Fast-polling during outages** | Switches to a tight check loop (default every 10 s) so recovery is detected and NVRAM is restored quickly |
| **Multi-target probe** | `PING_TARGETS` accepts a space-separated list; WAN is considered UP as soon as any target responds |
| **DNS probe support** | Set `DNS_PROBE_HOST` and `PROBE_MODE=dns` (or `any`) to use DNS lookups alongside or instead of ICMP pings |
| **WAN restart trigger** | Set `RESTART_WAN=true` to call `service restart_wan_if 0` when a confirmed outage exceeds the threshold, with a configurable cooldown to prevent back-to-back resets |
| **Correct NVRAM semantics** | Manages `link_internet` (2/1), `wan0_state` (2/3), `wan0_realstate` (2/0), and `wanduck_state` (1/0) with the values the WebUI actually expects |
| **wanduck awareness** | Detects if the `wanduck` daemon is running and defers to it, avoiding conflicting NVRAM writes |
| **Lock file** | Prevents multiple overlapping cron invocations |
| **Syslog integration** | All messages are written to syslog via BusyBox `logger` — readable with `logread` |
| **One-command install** | `install.sh` copies the script, sets up cron, and wires the cron entry into `services-start` for persistence |

---

## Requirements

* Router running **Asuswrt-Merlin** firmware (tested with 386.x / 388.x)
* **JFFS2 partition** enabled:  
  *Administration → System → Enable JFFS custom scripts and configs → Yes*
* SSH access (or the router's built-in terminal)

---

## Quick Start

### 1 — Transfer files to the router

```sh
# From your workstation
scp wanmoth install.sh admin@192.168.1.1:/tmp/
```

### 2 — Install

```sh
# On the router (via SSH)
cd /tmp
sh install.sh
```

`install.sh` will:

1. Copy `wanmoth` to `/jffs/scripts/wanmoth`
2. Add a cron job via `cru` (runs every 5 minutes by default)
3. Append the `cru` registration to `/jffs/scripts/services-start` so the
   cron job is re-registered on every boot

### 3 — Verify

```sh
# Confirm cron entry
cru l

# Run once manually and watch syslog
/jffs/scripts/wanmoth
logread -e wanmoth -l 20

# Check the NVRAM variables
nvram get wanduck_state
nvram get link_internet
```

### Uninstall

```sh
sh install.sh --uninstall
```

---

## Configuration

All options are environment variables with sensible defaults.  
Override them by exporting before running. Avoid editing the tracked `wanmoth`
script directly after installation, especially in environments that verify file
integrity.

### Probe settings

| Variable | Default | Description |
|---|---|---|
| `PING_TARGETS` | *(empty — falls back to `PING_TARGET`)* | Space-separated list of IPs/hostnames to ping; WAN is UP if **any** responds |
| `PING_TARGET` | `1.0.0.1` | Deprecated single-target fallback when `PING_TARGETS` is unset |
| `PING_COUNT` | `3` | ICMP packets sent per target per check |
| `PING_TIMEOUT` | `3` | Seconds to wait per packet |
| `DNS_PROBE_HOST` | *(empty — disabled)* | Hostname to resolve as a DNS connectivity probe |
| `PROBE_MODE` | `ping` | Probe strategy: `ping`, `dns`, or `any` (pass if ping **or** DNS succeeds) |

### Timing settings

| Variable | Default | Description |
|---|---|---|
| `DOWN_THRESHOLD` | `60` | Seconds of continuous failure before DOWN is committed to NVRAM |
| `FAST_POLL_INTERVAL` | `10` | Seconds between checks in fast-polling (outage) mode |

### WAN restart settings

| Variable | Default | Description |
|---|---|---|
| `RESTART_WAN` | `false` | Set to `true` to trigger a firmware WAN restart when the DOWN threshold is exceeded |
| `RESTART_WAN_CMD` | `service restart_wan_if 0` | Command run to restart the WAN interface |
| `RESTART_COOLDOWN` | `300` | Minimum seconds between successive WAN restart triggers |

### NVRAM settings

| Variable | Default | Description |
|---|---|---|
| `NVRAM_VAR` | `link_internet` | Primary NVRAM variable to manage (`2`=connected, `1`=disconnected) |
| `NVRAM_VAR2` | *(empty — disabled)* | Optional second primary NVRAM variable |
| `NVRAM_VAR2_UP` | *(same as `STATE_UP`)* | UP value override for `NVRAM_VAR2` |
| `NVRAM_VAR2_DOWN` | *(same as `STATE_DOWN`)* | DOWN value override for `NVRAM_VAR2` |
| `STATE_UP` | `2` | Integer value written to `NVRAM_VAR` when WAN is UP |
| `STATE_DOWN` | `1` | Integer value written to `NVRAM_VAR` when WAN is DOWN |
| `EXTRA_NVRAM_VARS` | `wan0_state:2:3 wan0_realstate:2:0 wanduck_state:1:0` | Space-separated extra variables — see below |

### Extra NVRAM variables

`EXTRA_NVRAM_VARS` accepts a space-separated list.  
Each entry can be either:

* `varname` — uses the global `STATE_UP` / `STATE_DOWN` values
* `varname:up_val:down_val` — uses per-variable integer overrides

The default value keeps `wan0_state`, `wan0_realstate`, and `wanduck_state`
in sync with the correct semantics used by the Asuswrt-Merlin WebUI.  
Set `EXTRA_NVRAM_VARS=""` to disable all extra-variable management.

**Example** — add a custom flag (up=1, down=0) on top of the defaults:

```sh
export EXTRA_NVRAM_VARS="wan0_state:2:3 wan0_realstate:2:0 wanduck_state:1:0 custom_flag:1:0"
/jffs/scripts/wanmoth
```

For persistent custom settings, use a wrapper or custom cron command that
exports the desired variables before running `/jffs/scripts/wanmoth`.

### Custom cron schedule

Pass a different schedule to `install.sh` via the `CRON_SCHEDULE` variable:

```sh
# Run every 2 minutes instead of 5
CRON_SCHEDULE="*/2 * * * *" sh install.sh
```

---

## How It Works

```
cron (every N min)
      │
      └─► wanmoth
              │
              ├─ wanduck running? ──► yes → log to syslog, exit immediately
              │
              ├─ acquire lock  (/tmp/wanmoth.lock)
              │
              ├─ probe WAN (ping PING_TARGETS / DNS / any)
              │       │
              │       ├─ [success] ──► clear down-start timestamp
              │       │                set NVRAM → STATE_UP
              │       │                release lock, exit
              │       │
              │       └─ [failure] ──► record down-start timestamp (once)
              │                        enter fast-polling loop:
              │                          ┌─ probe every FAST_POLL_INTERVAL s
              │                          ├─ [success] → set UP, exit loop
              │                          └─ [failure, elapsed ≥ DOWN_THRESHOLD]
              │                               → set NVRAM → STATE_DOWN
              │                               → if RESTART_WAN=true and
              │                                 cooldown elapsed:
              │                                 run RESTART_WAN_CMD
              │
              └─ release lock
```

The fast-polling loop continues until the WAN recovers, at which point the
DOWN timestamp is cleared and the NVRAM variables are restored to `STATE_UP`.

---

## File Layout (after install)

```
/jffs/
└── scripts/
    ├── wanmoth              ← monitoring script
    └── services-start       ← boot hook (cron registration appended here)

/tmp/
  ├── wanmoth.lock             ← PID lock file (auto-removed on exit)
  ├── wanmoth_down_since       ← outage start epoch (auto-removed on recovery)
  └── wanmoth_last_restart     ← epoch of last WAN restart (restart cooldown)
```

  All log messages are written to syslog - use `logread -e wanmoth -l 20` to view them.

---

## NVRAM Reference (Asuswrt-Merlin)

| Variable | UP value | DOWN value | Notes |
|---|---|---|---|
| `link_internet` | `2` | `1` | WebUI globe icon: 2=connected, 1=disconnected (`NVRAM_VAR`) |
| `wan0_state` | `2` | `3` | WAN0 logical state: 2=connected, 3=disconnected (`EXTRA_NVRAM_VARS`) |
| `wan0_realstate` | `2` | `0` | WAN0 physical link state: 2=stable, 0=init/down (`EXTRA_NVRAM_VARS`) |
| `wanduck_state` | `1` | `0` | Watchdog daemon active: 1=active, 0=inactive (`EXTRA_NVRAM_VARS`) |

Values match those used internally by the Asuswrt-Merlin `wanduck` daemon.

---

## License

See [LICENSE](LICENSE).
