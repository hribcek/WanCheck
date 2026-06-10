# Technical Research on ASUSWRT "wanduck" WAN Detection Utility

## Overview

Wanduck is a userspace WAN-detection and captive‑portal component in ASUSWRT and ASUSWRT‑Merlin router firmware that monitors Internet connectivity, manipulates DNS/HTTP redirection when the WAN is down, and can trigger WAN interface restarts. It also exposes DNS and HTTP listener functionality on internal ports and participates in the router’s status state machine used by the WebUI and higher‑level services.[^1][^2][^3][^4][^5]


## Core Responsibilities

### Connectivity monitoring and failover triggers

Wanduck periodically probes external connectivity using DNS lookups and/or ICMP pings; when probes consistently fail, it notifies the rc service manager to restart the WAN interface via `restart_wan_if` for the affected WAN unit. Router logs typically show entries of the form `rc_service: wanduck <pid>:notify_rc restart_wan_if 0` when the WAN link drops or flaps. The `restart_wan_if` action tears down client daemons (DHCP or PPPoE), flushes IP addresses and routes on the physical WAN interface, then re‑establishes the connection, and finally refreshes NAT and firewall rules once a new lease or session is obtained.[^6][^2][^7][^8]


### HTTP and DNS redirection on loss of Internet

When the WAN is down or in a captive‑portal / walled‑garden state, wanduck rewrites NAT rules so LAN clients’ traffic is redirected to its own internal HTTP and DNS listeners instead of going directly out to the Internet. It listens on TCP port 18017 and UDP port 18018, where the HTTP listener typically redirects to the router’s main web interface (port 80) and the DNS listener processes DNS requests, often used for ASUS “detect portal” logic. iptables DNAT rules show how normal DNS and HTTP flows are replaced by rules such as `DNAT tcp -- 0.0.0.0/0 !LAN tcp dpt:80 to:192.168.1.1:18017` and `DNAT udp -- 0.0.0.0/0 0.0.0.0/0 udp dpt:53 to:192.168.1.1:18018` when wanduck engages its redirection behavior.[^1][^3]


### Participation in WAN state machine and WebUI status

The ASUSWRT WebUI and services rely on several nvram variables to represent logical and physical WAN state, including `wan0_state`, `wan0_realstate`, `wan0_auxstate`, `link_internet`, and `wanduck_state`.[^6][^4]

A typical mapping described in community analysis is:

| Variable        | Purpose                                      | Key values and meaning                                                  |
|-----------------|----------------------------------------------|-------------------------------------------------------------------------| 
| `wan0_state`    | Logical WAN state from client stack          | 0 init, 1 connecting, 2 connected, 3 disconnected, 4 stopped, 5 disabled[^6] |
| `wan0_realstate`| Physical WAN link state                      | 0 init, 1 connecting, 2 link up, 3 disconnected, 4 link downed, 5 disabled[^6] |
| `wan0_auxstate` | Error sub‑state (PPPoE/DHCP/IP conflicts)    | 0 no error; 1 auth failed; 2 no response from ISP; 3 IP conflict[^6] |
| `link_internet` | High‑level “Internet globe” status in UI     | 0 unknown; 1 disconnected; 2 connected[^6] |
| `wanduck_state` | Internal status of wanduck watchdog daemon   | 0 inactive; 1 active and monitoring probes[^6] |

The WebUI’s network map globe and connection icons derive their green/amber/red indication from combinations of these fields rather than simply link presence, so any custom replacement must maintain or emulate these nvram semantics if UI accuracy matters.[^4][^6]


## Internal Architecture and Implementation Notes

### Source code location and listeners

In ASUSWRT‑Merlin source trees, `wanduck.c` resides under `release/src/router/rc/` as part of the rc subsystem. The `wanduck_main` entrypoint sets up sockets for the HTTP and DNS listeners and dispatches packets to handlers such as `run_dns_serv`, which reads up to `MAXLINE` (2048) bytes from UDP and passes parsed data to request handlers. Conditional compilation shows integration with dual‑WAN logic; for example, when `RTCONFIG_DUALWAN` is enabled, wanduck may use `wandog_target` nvram and `do_ping_detect()` for more advanced WAN probing.[^1][^4][^5]


### Security considerations (CVE‑2018‑20336)

A historical stack overflow vulnerability (CVE‑2018‑20336) was identified in `wanduck.c`’s DNS request handling, where insufficient bounds checking around a 2048‑byte buffer (`MAXLINE`) in `run_dns_serv` could enable an attacker on the WAN or LAN side to trigger a buffer overflow via crafted packets to UDP port 18018. The advisory notes that wanduck listens on TCP port 18017 and UDP port 18018, with the DNS server part vulnerable, and details a proof‑of‑concept payload constructed by sending an oversized message filled with `"A"` characters to 18018. ASUS subsequently patched affected firmware, but this history underscores that any custom WAN‑watchdog replacement must be designed with strict input validation if it exposes its own listeners.[^1]


## Behaviour in Real‑World Log Scenarios

### WAN flapping and forced restarts

Users with unstable ISP connections report log patterns where a brief link flap (physical down and up within a few seconds) triggers wanduck to perform a full `restart_wan_if`, resulting in longer outages (10–20 seconds) for LAN clients as PPPoE/DHCP renegotiation completes. This behavior has led some advanced users to explore disabling or replacing wanduck’s automatic restart logic in order to avoid over‑aggressive resets on transient link bounces. On Merlin firmware, custom scripts like `/jffs/scripts/service-event` can hook these `restart_wan_if` notifications, providing an avenue to intercept or augment wanduck’s actions.[^2][^9][^7][^8]


### DNS hijack / redirect behavior

Community discussions show that when wanduck concludes that the Internet is down, it may reprogram DNAT rules so that all HTTP and DNS traffic from LAN clients is redirected back to the router, sometimes causing confusing behavior like apparent DNS “hijack” to 192.168.1.1 or forced captive‑portal pages for detectportal.asus.com and related probes. This has led to questions about whether wanduck can safely be killed or bypassed to avoid unwanted DNS and HTTP rewriting, especially in advanced setups that already have custom DNS filtering or external captive portals.[^3][^10]


## Replacement or Bypass Strategies

### Constraints and missing information

Any concrete replacement strategy for wanduck depends heavily on the specific router model, CPU architecture (Broadcom vs MediaTek, etc.), firmware branch (stock ASUSWRT vs ASUSWRT‑Merlin), and whether features like Dual‑WAN or USB modems are in use; without these details, only generic patterns can be outlined. Community posts emphasize that wanduck also interacts with ASUS‑specific features like captive portal detection, WAN failover, and graphical status indicators, so disabling it without mirroring its state machine can have side effects such as broken UI indicators or unexpected failover behavior.[^6][^3][^4][^10][^11]


### Community alternatives and helper scripts

SNBForums and GitHub host a number of shell scripts whose goal is to monitor WAN connectivity and optionally restart interfaces, such as `ChkWAN.sh` and other watchdog utilities running out of `/jffs/scripts` on Merlin firmware. These scripts typically perform periodic pings or DNS queries against stable external targets (for example, multiple public resolvers) and, on repeated failure, run `service "restart_wan_if 0"` or issue `ifconfig` / `ip` commands to bounce the WAN interface, optionally logging outcomes to syslog. While such scripts can replicate the basic connectivity‑check and restart behavior of wanduck, they usually do not update nvram state variables or WebUI indicators, which must be considered if user‑visible status is important.[^6][^9][^10]


### DIY script design based on observed behavior

A DIY replacement that deliberately kills wanduck would need to:

- Implement robust probe logic (multi‑host ping and/or DNS checks, backoff, and hysteresis) to avoid false positives and oscillations.[^2][^9]
- Invoke the same rc actions that wanduck uses for reconnection, such as `service "restart_wan_if 0"`, in order to benefit from the firmware’s existing teardown and re‑init code.[^6]
- Optionally manipulate `wan0_state`, `wan0_realstate`, `wan0_auxstate`, `link_internet`, and `wanduck_state` nvram keys using `nvram set` to maintain WebUI consistency, following the documented value table and not committing unless persistence across reboots is required.[^6]
- Avoid exposing its own external HTTP/DNS listeners unless absolutely necessary, and if so, ensure strict bounds checking and input validation to avoid repeating past buffer‑overflow issues.[^1]

On ASUSWRT‑Merlin, best practice is often to leave wanduck running but tune its behavior (for example, changing detection targets or intervals via nvram) and layer a custom monitoring script that can react to its `service-event` hooks instead of fully replacing it.[^4][^10][^2]


## Risks of Disabling or Replacing Wanduck

Disabling wanduck entirely can:

- Prevent auto‑recovery from certain classes of WAN failures, requiring manual intervention or an alternative watchdog to bounce the interface.[^2][^8]
- Break or desync WebUI indicators (e.g., globe showing disconnected even when connectivity exists, or never indicating captive‑portal situations), because no process is maintaining `link_internet` and related state.[^6][^3]
- Interfere with ASUS‑implemented DNS/HTTP redirection flows used for firmware‑specific features like captive portal detection, cloud services, or some “Network Tools” diagnostics.[^3][^10]

Conversely, leaving wanduck fully active may cause:

- Longer‑than‑necessary outages when a brief physical link flap triggers a full logical restart.[^7][^2]
- Unexpected DNS/HTTP rule changes that conflict with custom firewall, DNS, or policy‑routing setups on advanced deployments.[^10][^3]

As a result, many advanced users aim not for a full replacement but for carefully constrained modification of wanduck’s behavior, combined with supplemental monitoring scripts.


## Summary of Key Technical Insights

- Wanduck is tightly integrated into ASUSWRT’s WAN‑state machine, rc event system, and NAT/DNS/HTTP redirection, so it is more than a simple ping script.[^6][^1][^3][^4]
- It exposes internal HTTP and DNS listeners on ports 18017 and 18018 and historically suffered from at least one DNS‑related stack‑overflow vulnerability (CVE‑2018‑20336), which has security implications for exposed routers.[^1]
- Community experience shows both benefits (automatic recovery from WAN failures) and drawbacks (over‑aggressive restarts, DNS/HTTP hijack side‑effects) of wanduck’s default behavior, motivating some users to tune or partially bypass it rather than remove it outright.[^2][^3][^10][^8]
- Any replacement must at minimum replicate its restart triggers and, if UI and ASUS features are to remain accurate, also maintain the relevant nvram state variables in a way that mirrors wanduck’s internal state machine.[^4][^6]

---

## References

1. [(CVE-2018-20336) ASUSWRT Stack Overflow in wanduck.c](https://starlabs.sg/advisories/18/18-20336/) - ASUSWRT is the firmware that is shipped with modern ASUS routers. ASUSWRT has a web-based interface,...

2. [Prevent wanduck's restart_wan_if on WAN connection ...](https://www.snbforums.com/threads/prevent-wanducks-restart_wan_if-on-wan-connection-coming-back.88028/) - I apparently have a sketchy internet connection: a couple times a day, my modem drops the link to my...

3. [Bug in wanduck and apparent loss of Internet](https://www.snbforums.com/threads/bug-in-wanduck-and-apparent-loss-of-internet.25421/) - Whenever I unplug my cable modem, the router magically replaces my DNS redirect rules: DNAT udp -- 1...

4. [asuswrt-merlin.ng/release/src/router/rc/wanduck.c at master · RMerl/asuswrt-merlin.ng](https://github.com/RMerl/asuswrt-merlin.ng/blob/master/release/src/router/rc/wanduck.c) - Third party firmware for Asus routers (newer codebase) - RMerl/asuswrt-merlin.ng

5. [wanduck.c - asus-rt-n66u-merlin - GitHub](https://github.com/shantanugoel/asus-rt-n66u-merlin/blob/master/release/src/router/rc.dsl/wanduck.c) - Discontinued. Please go to https://github.com/RMerl/asuswrt-merlin . Custom firmware for Asus RT-N66...

6. [some-wanduck-information.md.txt](attached)

7. [ASUS RT-AC68U router disconnects randomly(?) : r/techsupport](https://www.reddit.com/r/techsupport/comments/3wi4hr/asus_rtac68u_router_disconnects_randomly/) - Dec 3 23:33:48 rc_service: wanduck 562:notify_rc restart_wan_if 0 Dec 3 23:33:48 kernel: Attempt to ...

8. [AC68P Dual WAN and "ISP's DHCP did not function properly"](https://www.snbforums.com/threads/ac68p-dual-wan-and-isps-dhcp-did-not-function-properly.45791/) - Now about once a week I get the same error, but when it tries to fail back to WAN(0) it can never re...

9. [The script will stop after restarting WAN · Issue #2 · MartineauUK/Chk-WAN](https://github.com/MartineauUK/Chk-WAN/issues/2) - Using command below: /ChkWAN.sh wan googleonly & So I can see this log every 30 seconds Mar 11 05:52...

10. [Tweaking network settings in Asuswrt-Merlin - The 8th Voyager](http://voyager8.blogspot.com/2018/11/tweaking-network-settings-in-asuswrt.html) - The 8th Voyager - Information, knowledge, tips and tricks sharing that might be beneficial or useful...

11. [Asus rt-ac1200](https://forum.openwrt.org/t/asus-rt-ac1200/4755) - So ... TLDR I thought I was getting a deal on a completely different router. I didn't see a lot of m...

