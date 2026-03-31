# WanCheck

A lightweight, persistent WAN-connection monitoring script for
**Asuswrt-Merlin** routers. It pings a configurable target to detect
outages and keeps one or more NVRAM variables (e.g. `wanduck_state`)
accurately reflecting the WAN status — surviving reboots thanks to the
router's JFFS2 persistent partition.

---

## Features

| Feature | Detail |
|---|---|
| **Accurate state tracking** | NVRAM is only set to DOWN after a configurable silence threshold, preventing false alarms from brief transient blips |
| **Fast-polling during outages** | Switches to a tight check loop (default every 5 s) so recovery is detected and NVRAM is restored quickly |
| **Configurable NVRAM targets** | Primary variable (`wanduck_state`) plus an arbitrary list of extra variables, each optionally with their own UP/DOWN integer values |
| **Lock file** | Prevents multiple overlapping cron invocations |
| **Log rotation** | Keeps `/tmp/wancheck.log` under a configurable size cap |
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
scp wancheck.sh install.sh admin@192.168.1.1:/tmp/
```

### 2 — Install

```sh
# On the router (via SSH)
cd /tmp
sh install.sh
```

`install.sh` will:

1. Copy `wancheck.sh` to `/jffs/scripts/wancheck.sh`
2. Add a cron job via `cru` (runs every 5 minutes by default)
3. Append the `cru` registration to `/jffs/scripts/services-start` so the
   cron job is re-registered on every boot

### 3 — Verify

```sh
# Confirm cron entry
crontab -l | grep wancheck

# Run once manually and tail the log
sh /jffs/scripts/wancheck.sh
tail -f /tmp/wancheck.log

# Check the NVRAM variable
nvram get wanduck_state
```

### Uninstall

```sh
sh install.sh --uninstall
```

---

## Configuration

All options are environment variables with sensible defaults.  
Override them by exporting before running, or by editing the `Configuration`
block at the top of `wancheck.sh`.

| Variable | Default | Description |
|---|---|---|
| `PING_TARGET` | `8.8.8.8` | IP or hostname pinged to verify WAN connectivity |
| `PING_COUNT` | `3` | ICMP packets sent per check |
| `PING_TIMEOUT` | `3` | Seconds to wait per packet |
| `NVRAM_VAR` | `wanduck_state` | Primary NVRAM variable to manage |
| `STATE_UP` | `2` | Integer value written when WAN is UP |
| `STATE_DOWN` | `0` | Integer value written when WAN is DOWN |
| `EXTRA_NVRAM_VARS` | *(empty)* | Space-separated extra variables — see below |
| `DOWN_THRESHOLD` | `30` | Seconds of continuous failure before DOWN is committed |
| `FAST_POLL_INTERVAL` | `5` | Seconds between checks in fast-polling (outage) mode |
| `LOG_MAX_BYTES` | `262144` | Log file size cap (bytes) before rotation (256 KB) |

### Extra NVRAM variables

`EXTRA_NVRAM_VARS` accepts a space-separated list.  
Each entry can be either:

* `varname` — uses the global `STATE_UP` / `STATE_DOWN` values
* `varname:up_val:down_val` — uses per-variable integer overrides

**Example** — also manage `wan0_state_t` (up=2, down=0) and a custom
flag (up=1, down=0):

```sh
export EXTRA_NVRAM_VARS="wan0_state_t:2:0 custom_flag:1:0"
sh /jffs/scripts/wancheck.sh
```

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
      └─► wancheck.sh
              │
              ├─ acquire lock  (/tmp/wancheck.lock)
              │
              ├─ ping PING_TARGET
              │       │
              │       ├─ [success] ──► clear down-start timestamp
              │       │                set NVRAM → STATE_UP
              │       │                release lock, exit
              │       │
              │       └─ [failure] ──► record down-start timestamp (once)
              │                        enter fast-polling loop:
              │                          ┌─ ping every FAST_POLL_INTERVAL s
              │                          ├─ [success] → set UP, exit loop
              │                          └─ [failure, elapsed ≥ DOWN_THRESHOLD]
              │                               → set NVRAM → STATE_DOWN
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
    ├── wancheck.sh          ← monitoring script
    └── services-start       ← boot hook (cron registration appended here)

/tmp/
├── wancheck.log             ← rolling log (rotated at LOG_MAX_BYTES)
├── wancheck.lock            ← PID lock file (auto-removed on exit)
└── wancheck_down_since      ← outage start epoch (auto-removed on recovery)
```

---

## NVRAM Reference (Asuswrt-Merlin)

| Variable | UP value | DOWN value | Notes |
|---|---|---|---|
| `wanduck_state` | `2` | `0` | Primary WAN duck state |
| `wan0_state_t` | `2` | `0` | WAN0 interface state |
| `wan1_state_t` | `2` | `0` | WAN1 interface state (dual-WAN) |

Values match those used internally by the Asuswrt-Merlin `wanduck` daemon.

---

## License

See [LICENSE](LICENSE).