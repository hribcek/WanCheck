# Setup Instructions

## Prerequisites

- ASUS router with Asuswrt-Merlin firmware
- SSH access enabled on your router
- Basic familiarity with command line

## Installation

### 1. Access Your Router

Connect to your router via SSH:

```bash
ssh admin@192.168.1.1
```

(Replace with your router's IP address and/or username if different from default)

### 2. Prepare the Files Locally

On your workstation or local machine, clone the repository:

```bash
git clone https://github.com/hribcek/WanCheck.git
cd WanCheck
```

If you are not using git, download the repository archive locally and extract it.

### 3. Copy the Files to the Router

Transfer the executable and installer to the router:

```bash
scp wanmoth install.sh admin@192.168.1.1:/tmp/
```

Adjust the username or IP address as needed for your environment.

### 4. Install on the Router

SSH into the router and run the installer:

```bash
ssh admin@192.168.1.1
cd /tmp
chmod +x wanmoth install.sh
sh install.sh
```

### 5. Configuration

WanMoth should be configured through environment variables passed at runtime. Avoid modifying the tracked `wanmoth` script directly after installation, especially in environments that verify file integrity.

Common options include:

- `PING_TARGETS` to choose the connectivity test targets (space-separated list)
- `DOWN_THRESHOLD` to control how long an outage must persist before marking WAN down
- `FAST_POLL_INTERVAL` to control retry timing during an outage
- `PROBE_MODE` to switch between `ping`, `dns`, `any`, or `all` probe strategies

Example manual run with overrides:

```bash
PING_TARGETS="1.1.1.1 8.8.8.8" DOWN_THRESHOLD=90 /jffs/scripts/wanmoth
```

For persistent custom settings, use a wrapper or custom cron command that exports the desired variables before running `/jffs/scripts/wanmoth`.

### 6. Run WanMoth Manually

After installation, run the installed script directly on the router:

```bash
/jffs/scripts/wanmoth
```

## Scheduling with Cron

To run WanMoth periodically on Asuswrt-Merlin, use `cru`:

```bash
cru a wanmoth "*/5 * * * * /jffs/scripts/wanmoth"
```

List configured jobs:

```bash
cru l
```

Delete the job:

```bash
cru d wanmoth
```

## Troubleshooting

### Script Won't Execute
- Verify permissions: `ls -la /jffs/scripts/wanmoth` (should show `rwxr-xr-x`)

### Permission Denied
```bash
chmod +x /jffs/scripts/wanmoth
```

### SSH Connection Issues
- Ensure SSH is enabled in router settings: System Administration > SSH
- Verify router IP address, port, and credentials
- Check firewall rules aren't blocking SSH (default port 22)

### Script Errors
- Check logs: `logread -e wanmoth -l 20`
- Run with debug mode: `sh -x /jffs/scripts/wanmoth`

### WAN Restart Not Firing
- Ensure `RESTART_WAN=true` is exported before running the script.
- Check the log for "cooldown active" — this means a restart was triggered
  within the last `RESTART_COOLDOWN` seconds (default 300). Remove
  `/tmp/wanmoth_last_restart` to reset the cooldown manually.
- Confirm the `RESTART_WAN_CMD` value is appropriate for your firmware
  (default: `service restart_wan_if 0`).


## Uninstallation

To remove WanMoth:

```bash
cru d wanmoth
rm -f /jffs/scripts/wanmoth
```

## Support

For issues and questions, please visit: https://github.com/hribcek/WanCheck/issues
