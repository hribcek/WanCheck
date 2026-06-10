# Indicators for WAN Failure in a Wanduck Replacement Script
## Overview
This report identifies the practical indicators a custom script should monitor to decide when the WAN connection is truly "down" and when it should trigger recovery actions such as `restart_wan_if` in environments where the native ASUSWRT `wanduck` daemon has been disabled or replaced. It draws on documented wanduck behavior, ASUSWRT state variables, and community watchdog scripts (for example, ChkWAN and Merlin watchdog) to derive a robust, low‑false‑positive detection strategy.[^1][^2][^3][^4]
## Native Wanduck Behaviour and State Variables
### Internal probes and restart mechanism
Existing analysis of wanduck shows that it relies on internal connectivity probes (DNS or ICMP) and, after consistent failures, calls the rc service manager to execute `restart_wan_if` for the affected WAN unit. When this occurs, router logs show entries such as `rc_service: wanduck <pid>:notify_rc restart_wan_if 0`, followed by teardown and re‑initialisation of DHCP or PPP clients, route flushing, and firewall/NAT refresh. This confirms that wanduck differentiates between transient failures and sustained loss of connectivity before initiating a potentially disruptive restart.[^5][^2]
### NVRAM status variables relevant to WAN health
ASUSWRT exposes several NVRAM keys that summarise WAN status from different perspectives:[^1][^2]

- `wan0_state` – logical WAN state from the client stack (initialising, connecting, connected, disconnected, stopped, disabled).
- `wan0_realstate` – physical link state as seen by the driver and wanduck (link up, disconnected, downed by system, disabled).
- `wan0_auxstate` – error sub‑state (for example: authentication failed, no response from ISP, IP conflict).
- `link_internet` – high‑level WebUI "globe" status (unknown, disconnected, connected).
- `wanduck_state` – whether the wanduck daemon is inactive or actively monitoring probes.

Community documentation provides a table of value mappings, with `wan0_state = 2`, `wan0_realstate = 2`, and `wan0_auxstate = 0` used for a healthy connection, and values such as `wan0_state = 3` or `4`, `wan0_realstate = 0` or `4`, and non‑zero `wan0_auxstate` describing various error or disconnected conditions. These variables are read live from the in‑memory NVRAM copy by the WebUI and higher‑level services, so they are natural candidates for a replacement script to inspect and update.[^2]
## Categories of WAN‑Down Indicators
A robust replacement for wanduck should consider three layers of indicators before declaring WAN failure: physical link status, logical/transport status, and end‑to‑end reachability to external hosts.[^2][^3][^4]
### 1. Physical link indicators
Physical link indicators answer the question "Is there electrical carrier or a modem link on the WAN port?" independent of IP or PPP state.[^5][^2]

Key checks include:

- `wan0_realstate` in NVRAM: values representing disconnected (`3`) or stopped/downed (`4`) suggest the Ethernet link or upstream modem is down, while `2` indicates a stable physical link.[^2]
- Kernel/connection logs: entries such as `WAN(0)_Connection: WAN(0) link down` and `kernel: eth0 ... Link DOWN` versus `Link Up at ... full duplex` indicate physical flaps detected by the driver.[^5]
- Interface carrier state via system tools (outside NVRAM), for example `ip link show` or `ethtool` (where available) returning `state DOWN` or `no carrier` for the WAN interface.

A wanduck replacement script can treat a sustained physical down (for example, `wan0_realstate` consistently `3` or `4` for a period) as a strong indicator that recovery actions like restarting the WAN client or prompting for manual investigation might be required.[^2][^5]
### 2. Logical / IP‑layer connectivity indicators
Logical indicators describe whether the router has a valid Layer‑3 session to the ISP, including DHCP/PPPoE success and default routing.[^1][^2]

Useful checks include:

- `wan0_state`: if it remains in `1` (connecting), `3` (disconnected), or `4` (stopped) for longer than an expected interval, the WAN is not logically up.[^2]
- `wan0_auxstate`: specific error codes can hint at the cause—`1` (authentication failed), `2` (no response from ISP’s DHCP server), `3` (IP conflict)—which may influence whether to retry, back off, or avoid aggressive restarts.[^2]
- Presence of a valid IP address on the WAN interface: checking that the interface has a non‑link‑local, non‑private address where appropriate (for example, not stuck with a modem’s failover IP) can reveal misconfigured or stuck DHCP sessions.[^4][^6]
- Existence of a default route via the WAN interface: `ip route` or `route -n` should show a default gateway via the WAN; its absence suggests that even with an IP, traffic will not leave the router correctly.

A replacement script can combine these indicators to recognise cases where the physical link is up (`wan0_realstate = 2`) but the logical connection has failed (for example, `wan0_state = 4` with `wan0_auxstate = 2`), which often correspond to ISP DHCP failures or PPP authentication issues.[^6][^2]
### 3. End‑to‑end Internet reachability indicators
Even when physical and logical indicators are nominal, external connectivity may be broken due to upstream routing, DNS problems, or captive portals. For this reason, nearly all community WAN‑watchdog scripts perform active reachability tests.[^3][^4]

The ChkWAN script for ASUS routers is a widely referenced model; it can:

- Ping multiple targets in sequence: typically the ISP‑provided WAN gateway, two ISP DNS servers, and well‑known public DNS servers like 8.8.8.8 (Google) and 1.1.1.1 (Cloudflare).[^3]
- Consider the WAN "up" as soon as any one target responds; failure is declared only if all hosts fail after a configured number of retries and fail‑thresholds (default `retries=3`, `fails=3`).[^3]
- Optionally perform HTTP/HTTPS data transfers via curl (for example, 15‑byte, 500‑byte, or 12‑MB downloads) and treat repeated inability to retrieve data, or excessively low throughput, as a failure condition.[^3]

Other watchdog examples (such as simple ping scripts or Merlin‑specific watchdogs) also perform repeated pings to the ISP default gateway and external IPs and only restart DHCP or the WAN interface after several consecutive timeouts, to avoid flapping on transient packet loss.[^4][^7][^8]

For a wanduck replacement, best practice is to implement a similar multi‑target, hysteresis‑based reachability check rather than relying on a single ping to one host.[^4][^3]
## Combining Indicators into a Decision Strategy
### Avoiding false positives
A well‑designed replacement script should treat the WAN as "down" only when multiple categories of indicators agree, or when the end‑to‑end checks fail persistently despite nominal physical and logical status.[^2][^3]

Example strategies include:

- **Physical hard‑down**: If `wan0_realstate` indicates the link is down and log messages show repeated `WAN(0) link down` without subsequent successful `link up` within a grace period, the script can immediately treat WAN as down and consider restarting the interface or signalling an error state.[^5][^2]
- **Logical failure with physical up**: If `wan0_realstate = 2` (link up) but `wan0_state` is stuck in `3` or `4` and `wan0_auxstate` reports repeated DHCP or authentication failures, a restart might be justified after a back‑off delay, or after confirming that external pings also fail.[^6][^2]
- **Reachability failure despite OK link and session**: If both `wan0_state` and `wan0_realstate` are `2` (connected) and a valid default route exists, but all configured ping/curl targets fail repeatedly (for example, to ISP gateway, DNS, and public DNS), then the script can reasonably conclude that there is an upstream routing or ISP issue and optionally restart DHCP or the interface as a recovery attempt.[^3][^4]

By layering these conditions and using counters (for example, "mark a failure only after N consecutive failed probe cycles"), a replacement script avoids unnecessarily bouncing the WAN for short‑lived glitches.
### When to trigger `restart_wan_if`
In community practice, a restart action is typically taken when:[^2][^3][^4]

- All end‑to‑end tests fail across several cycles (default three attempts, with delays between), and
- Either the logical state indicates trouble (non‑zero `wan0_auxstate`, `wan0_state` not equal to `2`) or the script is configured to treat pure reachability failure as sufficient grounds for restart.

ChkWAN, for example, allows the user to choose between simply reporting status, restarting only the WAN interface, or rebooting the router, based on how severe and persistent the failure is. Merlin watchdog scripts typically start with less intrusive actions (kill DHCP client or force a WAN reconnect) and escalate only if problems persist.[^3][^4][^7]

A wanduck replacement should similarly:

- Start with a WAN reconnect (`service "restart_wan_if 0"`) when persistent failures are detected.[^2]
- Optionally escalate to a router reboot only after multiple unsuccessful attempts or when specifically configured to do so.
## Recommended Indicator Set for a Wanduck Replacement
Based on the above, an effective minimum set of indicators a replacement script should check before declaring WAN down and acting is:

1. **Physical link state**
   - NVRAM: `wan0_realstate` (look for `3` or `4` vs. `2`).[^2]
   - Logs: recent `WAN(0) link down` / `Link DOWN` messages without a subsequent stable `link up`.

2. **Logical WAN session state**
   - NVRAM: `wan0_state` (ensure it is `2` for normal operation; treat `3` or `4` as failure if persistent).[^2]
   - NVRAM: `wan0_auxstate` for detailed error diagnosis (authentication failure, no response from ISP, IP conflict).[^2]
   - IP configuration: verify that the WAN interface has an expected address and that a default route exists via that interface.[^4][^6]

3. **End‑to‑end reachability**
   - Multi‑host ping: at least one ISP gateway, one or two ISP DNS servers, and multiple public DNS IPs (for example, 8.8.8.8 and 1.1.1.1), with success defined as any single target responding within the retry window.[^3]
   - Optional HTTP/HTTPS checks: small curl requests to known endpoints to confirm application‑level connectivity, especially useful when DNS is misbehaving.[^8][^3]

4. **Hysteresis and timing**
   - Use counters such as `retries` and `fails` (for example, `retries=3`, `fails=3`) similar to ChkWAN, so that the script only acts when failures are sustained over multiple probe rounds.[^3]
   - Include grace periods after modem resyncs or DHCP renewals to avoid racing against normal recovery.

Monitoring these indicators in combination provides a foundation for a wanduck replacement script that can confidently decide when the WAN is truly down and when it should invoke recovery actions like `restart_wan_if`, while minimising false triggers and unnecessary service disruption.[^5][^3][^2]

---

## References

1. [some-wanduck-information.md.txt] - # Wanduck: The Mysterious Know-It-All

## The Restart Mechanism

When wanduck's internal probes (DNS...

2. [research-wanduck.md.txt] - Tone: Research or critical analysis tasks.

### **Optimized Prompt**

**Role:** Senior Network Engin...

3. [(CVE-2018-20336) ASUSWRT Stack Overflow in wanduck.c](https://starlabs.sg/advisories/18/18-20336/) - ASUSWRT is the firmware that is shipped with modern ASUS routers. ASUSWRT has a web-based interface,...

4. [ASUSWRT device tracker tracking unknown MAC from WAN?](https://community.home-assistant.io/t/asuswrt-device-tracker-tracking-unknown-mac-from-wan/73747) - So I have successfully gotten the ASUSWRT device tracker working with my instillation but I am findi...

5. [Prevent wanduck's restart_wan_if on WAN connection ...](https://www.snbforums.com/threads/prevent-wanducks-restart_wan_if-on-wan-connection-coming-back.88028/) - I apparently have a sketchy internet connection: a couple times a day, my modem drops the link to my...

6. [Bug in wanduck and apparent loss of Internet](https://www.snbforums.com/threads/bug-in-wanduck-and-apparent-loss-of-internet.25421/) - Whenever I unplug my cable modem, the router magically replaces my DNS redirect rules: DNAT udp -- 1...

7. [asuswrt-merlin.ng/release/src/router/rc/wanduck.c at master · RMerl/asuswrt-merlin.ng](https://github.com/RMerl/asuswrt-merlin.ng/blob/master/release/src/router/rc/wanduck.c) - Third party firmware for Asus routers (newer codebase) - RMerl/asuswrt-merlin.ng

8. [The script will stop after restarting WAN · Issue #2 · MartineauUK/Chk-WAN](https://github.com/MartineauUK/Chk-WAN/issues/2) - Using command below: /ChkWAN.sh wan googleonly & So I can see this log every 30 seconds Mar 11 05:52...

