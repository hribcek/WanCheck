# Wanduck: The Mysterious Know-It-All

## The Restart Mechanism

When wanduck's internal probes (DNS or ICMP) fail consistently, it performs the following steps:

  - Triggers restart_wan_if: Wanduck sends a notification to the system's service manager to execute the restart_wan_if command. This is the core logic that tears down the existing connection and brings it back up.
  - Service Signal: In logs, you will often see a message like rc_service: wanduck: notify_rc restart_wan_if 0. The 0 indicates the primary WAN interface.
  - Interface Reset: The restart_wan_if service:
    - Kills existing DHCP clients (like udhcpc) or PPP daemons.
    - Flushes the IP address and routes from the physical interface (e.g., eth0).
    - Restarts the connection process (e.g., requesting a new DHCP lease or initiating a new PPPoE handshake).
- Firewall & NAT Refresh: Once the interface receives a new IP, wanduck (or the rc service it triggered) ensures that NAT rules and firewall settings are reapplied to match the new connection state. 

## How to Replicate This in Your Script

If you kill wanduck and want your script to handle the reconnection, you should use the same command the system uses. Running this command via SSH or a script is the most reliable way to "bounce" the connection without a full reboot: 

```bash
service "restart_wan_if 0"
```

## Summary Table for Your Script

If you are writing a custom script to replace wanduck, use these combinations to toggle the WebUI display:
| Variable       |  Connected (Normal) | Disconnected (Error)              |
|----------------|---------------------|-----------------------------------|
| wan0_state     | 2                   | 4 (Stopped) or 3 (Disconnected)   |
| wan0_auxstate  | 0                   | Non-zero (e.g., 1 for Auth Error) |
| wan0_realstate | 2                   | 0 or 4                            |

Tip: After your script changes these values using nvram set, you typically do not need to run nvram commit unless you want the status to persist through a reboot. The WebUI reads these values live from the router's memory.

## Variables and Their Meaning

1. wan0_state & wan0_realstate
  These variables represent the primary status of the physical and logical WAN interface.
    0: INITIALIZING – Router is booting or the interface is starting up.
    1: CONNECTING   – In the process of obtaining an IP (DHCP) or authenticating (PPPoE).
    2: CONNECTED    – Healthy connection. This is the value needed for a "Green" status.
    3: DISCONNECTED – The link is physically or logically down.
    4: STOPPED      – The service has been manually halted or has given up after failed retries.
    5: DISABLED     – The WAN interface is turned off in settings. 


2. link_internet
  This is the high-level "Internet" indicator used specifically for the globe icon in the Network Map. 
    0: Unknown/Initializing – Status is being determined.
    1: Disconnected         – No internet access detected (even if the WAN link is technically "up").
    2: Connected            – Internet is fully accessible.


3. wan0_auxstate
  This variable tracks specific error sub-states. 
    0: No Error              – Normal operating state.
    1: Authentication Failed – Common for PPPoE errors.
    2: No Response from ISP  – DHCP server didn't respond.
    3: IP Conflict           – Local network conflict detected.


4. wanduck_state
  This tracks the operational status of the watchdog daemon itself. 
    0: Inactive – The service is stopped (this is what happens when you run service stop_wanduck).
    1: Active   – The wanduck service is running and monitoring probes.


## wan0_state & wan0_realstate: The Key Difference

  wan0_state:     The Logical state. This is what the software stack (DHCP client, PPPoE) believes is happening.
  wan0_realstate: The Physical/Actual state. This is what the hardware driver and wanduck report is actually happening on the wire.

## How the States Apply

| Value | State        | wan0_state (Logical)                 | wan0_realstate (Physical)             |
|-------|--------------|--------------------------------------|---------------------------------------|
|   0   | Initializing | Starting the DHCP/PPPoE service.     | Cable just plugged in, training link. |
|   1   | Connecting   | Requesting an IP address.            | Authenticating or synchronising.      |
|   2   | Connected    | IP obtained and active.              | Physical link is stable.              |
|   3   | Disconnected | User clicked "Disconnect" in UI.     | Cable unplugged / No carrier.         |
|   4   | Stopped      | Service failed (e.g., DHCP timeout). | Link downed by system/wanduck.        |
|   5   | Disabled     | WAN interface turned off in menu.    | Hardware port is powered down.        |

## Can they have all states?

Technically, yes, the variables can hold any of those integers. However, in practice:
  - wan0_realstate rarely stays at 1: It usually jumps from 0 (init) straight to 2 (connected) once the electrical signal is confirmed.
  - wan0_state spends more time in 1: Since getting an IP address (DHCP) takes a few seconds, you'll see this variable sit at 1 while realstate is already at 2.

Conflict is possible: If your cable is plugged in (realstate=2) but your ISP isn't giving you an IP (state=4), the WebUI will show a red "X" because the logical connection failed even though the wire is fine.
