# WanMoth

A lightweight WAN-connection monitoring script for
**Asuswrt-Merlin** routers. It probes connectivity via ICMP ping and/or DNS
lookups against one or more configurable targets and keeps the key NVRAM state
variables (`link_internet`, `wan0_state`, `wan0_realstate`, `wanduck_state`)
accurately reflecting the WAN status in the router's in-memory NVRAM store.

> **Note on NVRAM persistence**: these WAN state variables are transient
> runtime indicators — the WebUI reads them live from memory and they do not
> need to survive a reboot. WanMoth never calls `nvram commit`, so no flash
> writes occur during normal operation. This avoids flash wear and the risk of
> configuration corruption on power loss. See
> `docs/research/ASUS Router NVRAM Commit Behaviour...` for the full
> rationale.

---

## Features

| Feature | Detail |
|---|---|
| **Accurate state tracking** | NVRAM is only set to DOWN after a configurable silence threshold, preventing false alarms from brief transient blips |
| **Flash-safe NVRAM writes** | Uses `nvram set` only — never `nvram commit` — so no flash sectors are written during normal operation, avoiding wear and corruption risk |
| **Fast-polling during outages** | Switches to a tight check loop (default every 10 s) so recovery is detected and NVRAM is restored quickly |
| **Multi-target probe** | `PING_TARGETS` accepts a space-separated list; WAN is considered UP as soon as any target responds |
| **DNS probe support** | `DNS_PROBE_HOSTS` accepts a space-separated list of hostnames; set `PROBE_MODE=dns`, `any`, or `all` to use DNS lookups alongside or instead of ICMP pings |
| **WAN restart trigger** | `RESTART_WAN=true` calls `service restart_wan_if 0` when a confirmed outage exceeds the threshold, with a configurable cooldown to prevent back-to-back resets — **disabled by default** (see Configuration) |
| **Correct NVRAM semantics** | Manages `link_internet` (2/1), `wan0_state` (2/3), `wan0_realstate` (2/0), `wanduck_state` (1/0), and optionally `wan0_auxstate` (0/2) with hardcoded values the WebUI actually expects |
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
| `PING_TARGETS` | `1.0.0.1 8.8.4.4` | Space-separated list of IPs/hostnames to ping; WAN is UP if **any** responds |
| `PING_COUNT` | `3` | ICMP packets sent per target per check |
| `PING_TIMEOUT` | `3` | Seconds to wait per packet |
| `DNS_PROBE_HOSTS` | `dns.google one.one.one.one` | Space-separated list of hostnames to resolve; WAN is UP if **any** resolves |
| `PROBE_MODE` | `ping` | Probe strategy: `ping`, `dns`, `any` (pass if ping **or** DNS succeeds), or `all` (pass only if ping **and** DNS both succeed) |

### Timing settings

| Variable | Default | Description |
|---|---|---|
| `DOWN_THRESHOLD` | `60` | Seconds of continuous failure before DOWN is written to NVRAM |
| `FAST_POLL_INTERVAL` | `10` | Seconds between checks in fast-polling (outage) mode |

### WAN restart settings

> **Disabled by default.**  
> The exact definition of a "confirmed outage" is still under review. Enabling
> `RESTART_WAN` prematurely may cause unnecessary WAN bounces on transient link
> flaps. Enable it only once you have confirmed that the threshold and cooldown
> values match your ISP's reconnect behaviour.

| Variable | Default | Description |
|---|---|---|
| `RESTART_WAN` | `false` | Set to `true` to trigger a firmware WAN restart when the DOWN threshold is exceeded |
| `RESTART_WAN_CMD` | `service restart_wan_if 0` | Command run to restart the WAN interface |
| `RESTART_COOLDOWN` | `300` | Minimum seconds between successive WAN restart triggers |

### NVRAM management settings

Each NVRAM variable is managed individually. Values are hardcoded to match
the exact semantics used by the Asuswrt-Merlin firmware and WebUI.

| Variable | Default | NVRAM variable managed | UP value | DOWN value |
|---|---|---|---|---|
| `MANAGE_LINK_INTERNET` | `true` | `link_internet` | `2` | `1` |
| `MANAGE_WAN0_STATE` | `true` | `wan0_state` | `2` | `3` |
| `MANAGE_WAN0_REALSTATE` | `true` | `wan0_realstate` | `2` | `0` |
| `MANAGE_WANDUCK_STATE` | `true` | `wanduck_state` | `1` | `0` |
| `MANAGE_WAN0_AUXSTATE` | `false` | `wan0_auxstate` | `0` | `2` |

`MANAGE_WAN0_AUXSTATE` is disabled by default because the correct DOWN value
is ISP-protocol-specific: PPPoE authentication failures use `1`; DHCP timeouts
use `2`. Enable it only when you know which value applies to your link type.

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
              ├─ probe WAN (ping PING_TARGETS / DNS / any / all)
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
              │                               → set NVRAM → DOWN values
              │                               → if RESTART_WAN=true and
              │                                 cooldown elapsed:
              │                                 run RESTART_WAN_CMD
              │                                 (disabled by default — see
              │                                 Configuration for details)
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
| `link_internet` | `2` | `1` | WebUI globe icon: 2=connected, 1=disconnected (`MANAGE_LINK_INTERNET`) |
| `wan0_state` | `2` | `3` | WAN0 logical state: 2=connected, 3=disconnected (`MANAGE_WAN0_STATE`) |
| `wan0_realstate` | `2` | `0` | WAN0 physical link state: 2=stable, 0=init/down (`MANAGE_WAN0_REALSTATE`) |
| `wanduck_state` | `1` | `0` | Watchdog daemon active: 1=active, 0=inactive (`MANAGE_WANDUCK_STATE`) |
| `wan0_auxstate` | `0` | `2` | WAN0 error sub-state: 0=no error, 2=no ISP response (`MANAGE_WAN0_AUXSTATE`, disabled by default) |

Values match those used internally by the Asuswrt-Merlin `wanduck` daemon.

---

## License

See [LICENSE](LICENSE).
