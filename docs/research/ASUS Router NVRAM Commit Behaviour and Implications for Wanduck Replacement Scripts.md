# ASUS Router NVRAM Commit Behaviour and Implications for Wanduck Replacement Scripts
## Overview
This report explains how NVRAM is used in ASUSWRT/ASUSWRT‑Merlin firmware, what `nvram commit` actually does, why excessive commits are discouraged, and how this should influence the design of a custom replacement script for the `wanduck` WAN‑detection daemon. It focuses on Broadcom‑based ASUS routers running stock or Merlin firmware, where NVRAM is a small flash‑backed key‑value store with limited size and write endurance.[^1][^2][^3]
## NVRAM in ASUSWRT
### Architecture and role
ASUSWRT and ASUSWRT‑Merlin use NVRAM (Non‑Volatile RAM) as the primary persistent configuration store: a flash‑backed key–value database that holds core settings such as WAN, LAN, wireless, and service configuration. At boot, the firmware loads NVRAM values from flash into an in‑memory copy; services and the WebUI read and write this in‑memory store through the `nvram_*` API.[^1][^2]

DeepWiki documentation for Asuswrt‑Merlin describes NVRAM as the “primary mechanism for storing and retrieving router configuration data” and notes that it backs virtually all configuration parameters that must persist across reboots. Storage‑architecture notes further emphasize that NVRAM capacity is limited (on the order of 64–128 KB total), so only compact configuration values are stored there, while larger data (e.g., traffic statistics, certificates, scripts) is moved to JFFS or USB.[^2][^1]
### NVRAM API and in‑memory vs. flash
The firmware exposes a standard NVRAM API:[^1][^2]

- `nvram_get` / `nvram_safe_get` – read current value from the in‑memory copy.
- `nvram_set` – change a value in the in‑memory copy only.
- `nvram_unset` – remove a key from the in‑memory copy.
- `nvram_commit` – write the entire NVRAM image from memory back to flash.

Storage documentation explicitly notes that `nvram_set()` only affects the in‑memory copy and that changes are not persisted until `nvram_commit()` is called, which writes the updated contents to flash so they survive a reboot. The WebUI therefore batches multiple `nvram_set()` operations and performs a single `nvram_commit()` when the user clicks “Apply,” both for performance and to reduce flash wear.[^1]
## Why Too Many NVRAM Commits Are a Problem
### Flash wear and write‑cycle limits
Flash memory, including the region used for NVRAM, has a finite number of erase/program cycles; repeated `nvram_commit()` calls ultimately wear out the underlying flash cells. The NVRAM configuration system documentation explicitly lists “write cycle limitation” as a key constraint and notes that this is one reason heavy or large data (for example, detailed traffic statistics) is kept out of NVRAM and moved to JFFS or USB.[^1][^2]

Community discussions on ASUSWRT‑Merlin forums repeatedly raise concerns that scripts which commit frequently (e.g., scheduled LED toggling that runs `nvram commit` every day or every few minutes) could accelerate wear on the NVRAM flash region over the lifetime of the router. While exact endurance figures are not always published, embedded flash is typically rated for on the order of tens to hundreds of thousands of erase cycles, so using those cycles for rapidly changing, non‑essential state is considered poor practice.[^2][^4]
### Limited space and fragmentation / exhaustion
NVRAM capacity is small (commonly 64 KB on older Broadcom models, somewhat larger on newer hardware), and all configuration keys must fit within this budget. As configuration grows (long DHCP reservations, many VPN instances, AiMesh metadata, etc.), users can run low on free NVRAM, triggering warnings like “Your router is running low on free NVRAM, which might affect its stability” in the WebUI.[^1][^5]

Blog posts and forum threads describe routers becoming sluggish or unstable when NVRAM is nearly full, sometimes requiring manual cleanup of unused keys followed by an `nvram commit` to free space. The more often scripts write new values and commit them, the more likely stale or unused keys accumulate, increasing the risk of hitting size limits unless configuration is carefully managed.[^5][^6]
### Risk of corruption on power loss or interruption
Firmware documentation and troubleshooting notes for the NVRAM configuration system list corruption as a failure mode, particularly if power is lost during NVRAM writes. Because `nvram_commit()` writes out the NVRAM image from memory to flash, an interruption during that write can leave the configuration in a partially written or corrupt state, potentially forcing a factory reset or recovery.[^2][^7]

OpenWrt and other Broadcom‑based router documentation describe similar failure patterns: if NVRAM is reset or corrupted, devices may boot with factory defaults, requiring restoration from backups or scripted recovery. While ASUSWRT has its own safeguards, more frequent `nvram_commit()` operations proportionally increase the windows of vulnerability where a sudden power cut could corrupt settings.[^7][^8]
### Performance and blocking behavior
Although not usually a massive performance problem, `nvram_commit()` is significantly heavier than simple `nvram_set()` because it writes to flash and may temporarily block other operations while the flash sector is erased and re‑written. For scripts that might run on short intervals, repeatedly calling `nvram_commit()` can introduce unnecessary blocking and CPU/IO overhead on the router’s limited hardware.[^1][^4]
## When NVRAM Commit Is Appropriate
### Persisting real configuration changes
NVRAM’s intended purpose is to store persistent configuration: values that should survive reboots, such as WAN protocol, LAN IP, Wi‑Fi SSIDs, passwords, VPN endpoints, port forwards, and other settings the administrator configures in the WebUI. For these changes, a commit is both necessary and expected; the WebUI explicitly batches them and performs a single `nvram_commit()` after the user applies settings.[^1][^2]

Tools and scripts that manage configuration backups or “factory reset plus restore” workflows rightly use `nvram commit` after applying a series of `nvram set` and `nvram unset` operations, because the whole point is to save a stable configuration snapshot in flash.[^6][^3]
### One‑time maintenance operations
Occasional maintenance operations such as trimming unused NVRAM variables (e.g., unsetting empty keys created across multiple firmware upgrades) also require a commit to make space savings permanent. Guides that walk through NVRAM cleanup generally conclude with a single `nvram commit` to write the cleaned configuration back to flash, followed by a reboot to verify that the router boots correctly with the new layout.[^5][^6]
## When NVRAM Commit Should Be Avoided
### Transient state and runtime indicators
ASUSWRT uses NVRAM not only for persistent configuration but also for some runtime state indicators, such as WAN status fields (`wan0_state`, `wan0_realstate`, `wan0_auxstate`, `link_internet`) and internal daemon state like `wanduck_state`. These values are read by the WebUI and services from the in‑memory NVRAM copy; they do not need to survive a reboot to fulfill their purpose.[^1][^2][^9]

Community documentation about wanduck‑related variables explicitly advises that after setting these with `nvram set`, a commit is not typically needed unless there is a specific requirement for the status to persist across reboots, because the WebUI reads these values live from memory. Persisting rapidly changing status values (such as “WAN disconnected” vs “connected”) to flash on every change offers little benefit and increases wear and corruption risk.[^9]
### Frequently changing dynamic values
Scripts that toggle LEDs, transient firewall flags, temporary test parameters, or fast‑changing counters should generally avoid committing each state change. A forum thread on “Scheduled LED Control” in Merlin firmware shows an example: a user worries about whether committing twice a day just for LED state could wear out NVRAM, highlighting that such dynamic features are better implemented either without commits or using alternative storage (e.g., JFFS or RAM files) when persistence is even needed at all.[^4][^5]

If a value’s lifespan is “until the next reboot” or “until the next link event,” keeping it in volatile memory (in‑memory NVRAM copy, environment variables, or temporary files) is typically sufficient and avoids unnecessary flash writes.[^1][^2]
## Implications for Wanduck Replacement Scripts
### How wanduck uses NVRAM‑exposed WAN state
Wanduck and related rc components track WAN connection status using a set of NVRAM variables, including:[^1][^9]

- `wan0_state` – logical WAN state (initializing, connecting, connected, disconnected, stopped, disabled).
- `wan0_realstate` – physical link state (e.g., link up vs. downed by system).
- `wan0_auxstate` – error sub‑codes (authentication failed, no response from ISP, IP conflict, etc.).
- `link_internet` – high‑level “Internet globe” status for the WebUI (unknown, disconnected, connected).
- `wanduck_state` – whether the wanduck watchdog is active.

Community analysis notes that the WebUI network map reads these values directly from the in‑memory NVRAM copy to decide which icons to show, and that changing them with `nvram set` is enough to influence the display. Guidance for scripting explicitly states that `nvram commit` is not required for the WebUI to reflect these states; a commit is only needed if the author wants the status to survive a reboot, which is rarely desirable for transient link state.[^9]
### Should a wanduck replacement commit NVRAM values?
For a custom script intended to replace or shadow wanduck’s functionality—monitoring connectivity, updating WAN status variables, and possibly triggering `restart_wan_if`—the general recommendation is **not** to call `nvram commit` on wanduck‑related state, for several reasons:[^1][^2][^9]

1. **Status is transient by nature**: WAN state variables reflect current link and session health, which naturally change with every disconnect, reconnect, or error. Persisting these ephemeral conditions to flash has little value, because after a reboot the router will re‑evaluate link state anyway.[^2][^1]
2. **WebUI reads live values**: The WebUI uses `nvram_get` to read from the in‑memory store and does not require that values have been committed to flash to update icons or messages, so committing for UI purposes is unnecessary.[^9][^1]
3. **Flash wear and corruption risk**: Committing on every WAN‑state transition (e.g., flaps, DHCP retries, PPPoE errors) would substantially increase flash write frequency and the risk window for corruption on power loss, especially during unstable periods when the script might change state repeatedly.[^4][^7][^2]
4. **Existing design pattern**: Stock firmware and Merlin’s WebUI batch configuration writes and keep dynamic service state in RAM/JFFS rather than constantly committing NVRAM; following the same pattern keeps custom scripts aligned with upstream design expectations.[^1][^2]

In most cases, a wanduck replacement should therefore:

- Use `nvram set` (without commit) to adjust `wan0_state`, `wan0_realstate`, `wan0_auxstate`, `link_internet`, and `wanduck_state` so that WebUI and dependent services see accurate status.[^9][^1]
- Rely on runtime behavior (re‑evaluation at boot and during link changes) rather than persisted status to restore state after a reboot.[^2][^1]
### When might a commit be justified for wanduck‑adjacent logic?
There are niche scenarios where a script tightly coupled to wanduck logic might reasonably use `nvram commit`, but these should be approached carefully:[^1][^2][^6]

- **Persistent configuration knobs for the script itself**: If the script introduces its own configuration (e.g., probe targets, thresholds, enable/disable flags) that should persist across reboots and be adjustable from the shell or WebUI, storing those as dedicated NVRAM keys and committing them occasionally can be appropriate—mirroring how native services store their configuration.[^2][^1]
- **One‑time migration or cleanup**: If the script performs a one‑off migration of wanduck‑related configuration (for example, renaming or cleaning obsolete keys after a firmware change), it may need to commit once at the end of the operation, similar to other NVRAM maintenance utilities.[^5][^6]

Even in these cases, best practice is to:

- Separate persistent configuration keys (which are rarely changed and can be committed occasionally) from dynamic status keys (which should never be committed on normal state changes).[^1][^2]
- Ensure that any commit is done at low frequency (e.g., only when the admin explicitly changes settings) rather than as part of recurring monitoring loops.[^4][^6]
## Practical Design Guidelines for a Wanduck Replacement
Based on the NVRAM architecture and constraints:

1. **Use `nvram set` without commit for WAN state**: Update `wan0_state`, `wan0_realstate`, `wan0_auxstate`, `link_internet`, and `wanduck_state` only in the in‑memory NVRAM copy so that the WebUI and services see accurate, live status without writing flash on every change.[^1][^9]
2. **Reserve `nvram commit` for true configuration**: Only commit when changing persistent configuration options relevant to the script or router behavior, and ideally batch multiple changes into a single commit event.
3. **Avoid high‑frequency commit loops**: Never place `nvram commit` inside short‑interval cron jobs, watchdog loops, or per‑event handlers for WAN flaps; use RAM or JFFS files for any needed persistent logging or counters instead.[^2][^4][^1]
4. **Plan for safe failure modes**: Assume that power loss can occur during commits and design scripts so that configuration is only committed when the system is otherwise stable, minimizing the risk of corruption.[^7][^2]

Following these principles allows a wanduck replacement to integrate cleanly with ASUSWRT’s configuration system while avoiding unnecessary wear and risk to the router’s limited NVRAM.

---

## References

1. [some-wanduck-information.md.txt](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/143413012/7e950cb1-559a-41fc-b2f5-feb03b0ac4f6/some-wanduck-information.md.txt?AWSAccessKeyId=ASIA2F3EMEYE2RQ25R2Z&Signature=1LOIpEpT8cZTHOkxbva65c9r7Hg%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEBAaCXVzLWVhc3QtMSJIMEYCIQCtCT7PWCTapywNxiuNTQJv349JtzvoA0TPimAlros95gIhAN%2FvABwbpyUIjwR34eCmwJA5nG2fLHaprvvFAtBDXSecKvwECNj%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FwEQARoMNjk5NzUzMzA5NzA1IgxGGiQgY3WX9yaNYjcq0AT34tRkm6BsKR66SpfyOU%2F5S8nOGY3IAoMkeqoFpI8aBEfJ%2BXdEblrZls36mdTlSAdtnQe%2FEQdMsoFOj3mA8QimuCeUFow%2BiHOvSPmHflRJjrXRKIpRL%2FZS%2BhR7b4lzIWB9eY6rV3n5Koau8h3ivYJH0eeeIgMufI7z1UKQQDAguryWt%2FgmhG36H%2Fqco0VBU%2BB8lR2smxJJbi2mKP%2BqF%2FbsPtFknjuyZ%2BVJm8lPy%2Fl62jc37I8QXf9KjCRkxAL%2FDsX2%2FkNq9beGtFwlnJXrfQf9NEYY%2FoE23pBDKoW74QiN0UejH5hv6zw%2FjHvRAWBtOJTK%2Fae8ahuKdIhKmo9NRyEMd3Yvep2R0K41IkjWJlKTtO6kQ8aT6%2FGV7ahZziu9TqhFpuJOfSu7YwXiGe1DO%2FmJv34R95e1b01ETDVEahUHejRx8jBAzhgVpevdXUXstf%2BS6BjmCmnRsB9%2BYKHjaNIM1oEs9yQjx6VYkvmIsNHOtetdzN7phgi36%2BbeIzV1DRYZCYx76ExvCLCeF9VJ9SEQLmQA3QCx%2F0oI1fNj%2FUiTzswijfhUxxRrYk4RRFYCpot%2FBpqIMoILT7BQ2yZSxpYdJfdtddJPHP9hpYkryA9H%2BuYwPRhoD64klSLxZjKgvwlk%2FzeUzVD3EFEb3UNgA0yqGUC3kWQa2nc1quWvXYImqr9x%2FuQDHhF4%2B8cOAVATQeXl7rMiuwVLSxXbgWSjUxYDUd2%2BhhVpyYxIY5eZ7%2Bg1MlfHtrxdh3c1gcJIzctddmM3uLMuNxtgQmeJ5Ame921JMNb60M4GOpcBt3XVGkZJI%2Fz%2FsiYevSVeos3cbtH%2BdpNWN8Vd7XHEXLH2cBYacsSZ08Y0slH2Oam1bPMKE%2F4b68yvXKI3opmy9VWQ7nxIzbeUBXj5tuLxGgR9J%2FnmIje10ideAQZJgtBa9NPj6Yv09r9e4FeEOl7zTqcWmf99vPH6xQMDOCEWNVYoDzjbDaNoPU3M7ZkaYL%2B6q2m7sgph%2BA%3D%3D&Expires=1775520553) - # Wanduck: The Mysterious Know-It-All

## The Restart Mechanism

When wanduck's internal probes (DNS...

2. [research-wanduck.md.txt](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/143413012/52c4f2e5-d45a-4bf0-ac3c-f840749e1124/research-wanduck.md.txt?AWSAccessKeyId=ASIA2F3EMEYE2RQ25R2Z&Signature=tFEH9fL05vKndJR%2FRqTeaQOi5co%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEBAaCXVzLWVhc3QtMSJIMEYCIQCtCT7PWCTapywNxiuNTQJv349JtzvoA0TPimAlros95gIhAN%2FvABwbpyUIjwR34eCmwJA5nG2fLHaprvvFAtBDXSecKvwECNj%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FwEQARoMNjk5NzUzMzA5NzA1IgxGGiQgY3WX9yaNYjcq0AT34tRkm6BsKR66SpfyOU%2F5S8nOGY3IAoMkeqoFpI8aBEfJ%2BXdEblrZls36mdTlSAdtnQe%2FEQdMsoFOj3mA8QimuCeUFow%2BiHOvSPmHflRJjrXRKIpRL%2FZS%2BhR7b4lzIWB9eY6rV3n5Koau8h3ivYJH0eeeIgMufI7z1UKQQDAguryWt%2FgmhG36H%2Fqco0VBU%2BB8lR2smxJJbi2mKP%2BqF%2FbsPtFknjuyZ%2BVJm8lPy%2Fl62jc37I8QXf9KjCRkxAL%2FDsX2%2FkNq9beGtFwlnJXrfQf9NEYY%2FoE23pBDKoW74QiN0UejH5hv6zw%2FjHvRAWBtOJTK%2Fae8ahuKdIhKmo9NRyEMd3Yvep2R0K41IkjWJlKTtO6kQ8aT6%2FGV7ahZziu9TqhFpuJOfSu7YwXiGe1DO%2FmJv34R95e1b01ETDVEahUHejRx8jBAzhgVpevdXUXstf%2BS6BjmCmnRsB9%2BYKHjaNIM1oEs9yQjx6VYkvmIsNHOtetdzN7phgi36%2BbeIzV1DRYZCYx76ExvCLCeF9VJ9SEQLmQA3QCx%2F0oI1fNj%2FUiTzswijfhUxxRrYk4RRFYCpot%2FBpqIMoILT7BQ2yZSxpYdJfdtddJPHP9hpYkryA9H%2BuYwPRhoD64klSLxZjKgvwlk%2FzeUzVD3EFEb3UNgA0yqGUC3kWQa2nc1quWvXYImqr9x%2FuQDHhF4%2B8cOAVATQeXl7rMiuwVLSxXbgWSjUxYDUd2%2BhhVpyYxIY5eZ7%2Bg1MlfHtrxdh3c1gcJIzctddmM3uLMuNxtgQmeJ5Ame921JMNb60M4GOpcBt3XVGkZJI%2Fz%2FsiYevSVeos3cbtH%2BdpNWN8Vd7XHEXLH2cBYacsSZ08Y0slH2Oam1bPMKE%2F4b68yvXKI3opmy9VWQ7nxIzbeUBXj5tuLxGgR9J%2FnmIje10ideAQZJgtBa9NPj6Yv09r9e4FeEOl7zTqcWmf99vPH6xQMDOCEWNVYoDzjbDaNoPU3M7ZkaYL%2B6q2m7sgph%2BA%3D%3D&Expires=1775520553) - Tone: Research or critical analysis tasks.

### **Optimized Prompt**

**Role:** Senior Network Engin...

3. [The script will stop after restarting WAN · Issue #2 · MartineauUK/Chk-WAN](https://github.com/MartineauUK/Chk-WAN/issues/2) - Using command below: /ChkWAN.sh wan googleonly & So I can see this log every 30 seconds Mar 11 05:52...

4. [(CVE-2018-20336) ASUSWRT Stack Overflow in wanduck.c](https://starlabs.sg/advisories/18/18-20336/) - ASUSWRT is the firmware that is shipped with modern ASUS routers. ASUSWRT has a web-based interface,...

5. [ASUSWRT device tracker tracking unknown MAC from WAN?](https://community.home-assistant.io/t/asuswrt-device-tracker-tracking-unknown-mac-from-wan/73747) - So I have successfully gotten the ASUSWRT device tracker working with my instillation but I am findi...

6. [Prevent wanduck's restart_wan_if on WAN connection ...](https://www.snbforums.com/threads/prevent-wanducks-restart_wan_if-on-wan-connection-coming-back.88028/) - I apparently have a sketchy internet connection: a couple times a day, my modem drops the link to my...

7. [Bug in wanduck and apparent loss of Internet](https://www.snbforums.com/threads/bug-in-wanduck-and-apparent-loss-of-internet.25421/) - Whenever I unplug my cable modem, the router magically replaces my DNS redirect rules: DNAT udp -- 1...

8. [asuswrt-merlin.ng/release/src/router/rc/wanduck.c at master · RMerl/asuswrt-merlin.ng](https://github.com/RMerl/asuswrt-merlin.ng/blob/master/release/src/router/rc/wanduck.c) - Third party firmware for Asus routers (newer codebase) - RMerl/asuswrt-merlin.ng

9. [wanduck.c - asus-rt-n66u-merlin - GitHub](https://github.com/shantanugoel/asus-rt-n66u-merlin/blob/master/release/src/router/rc.dsl/wanduck.c) - Discontinued. Please go to https://github.com/RMerl/asuswrt-merlin . Custom firmware for Asus RT-N66...

