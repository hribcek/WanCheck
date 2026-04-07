#!/bin/sh
# =============================================================================
# tests/test_wanmoth.sh — Unit/integration tests for wanmoth
#
# Strategy: create a per-test stub directory early on PATH so that `nvram`,
# `ping`, `date`, and `sleep` can be replaced without patching the script.
# =============================================================================
set -e

# Resolve the script path relative to this test file's location
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${TESTS_DIR}/../wanmoth"

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

assert_equals() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    printf 'PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s  expected="%s"  actual="%s"\n' "$label" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_log_contains() {
  local label="$1" pattern="$2" logfile="$3"
  if grep -q "$pattern" "$logfile" 2>/dev/null; then
    printf 'PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s  pattern="%s" not found in %s\n' "$label" "$pattern" "$logfile"
    printf '      Log contents:\n'
    sed 's/^/        /' "$logfile" 2>/dev/null || true
    FAIL=$((FAIL + 1))
  fi
}

assert_file_absent() {
  local label="$1" file="$2"
  if [ ! -f "$file" ]; then
    printf 'PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s  file "%s" should not exist\n' "$label" "$file"
    FAIL=$((FAIL + 1))
  fi
}

# Build a complete stub /bin directory inside <td>
# ping_lines   — each line is "0" (success) or "1" (failure), consumed in order
# epoch_lines  — each line is an integer epoch returned by `date +%s`
make_stubs() {
  local td="$1"
  local ping_lines="$2"
  local epoch_lines="$3"

  mkdir -p "${td}/bin" "${td}/nvram_store"
  touch "${td}/nvram_store/vars"

  printf '%s\n' "$ping_lines" > "${td}/ping_seq"
  printf '%s\n' "$epoch_lines" > "${td}/date_seq"

  # nvram stub
  cat > "${td}/bin/nvram" << STUB
#!/bin/sh
store="${td}/nvram_store/vars"
touch "\$store"
case "\$1" in
  get)
  grep "^\${2}=" "\$store" 2>/dev/null | cut -d= -f2- || true
  ;;
  set)
  var="\${2%%=*}"; val="\${2#*=}"
  # Always remove the old entry (grep may return 1 when nothing to exclude)
  grep -v "^\${var}=" "\$store" > "\${store}.tmp" 2>/dev/null || true
  mv "\${store}.tmp" "\$store" 2>/dev/null || true
  printf '%s=%s\n' "\$var" "\$val" >> "\$store"
  ;;
  commit) ;;
esac
STUB
  chmod +x "${td}/bin/nvram"

  # ping stub
  cat > "${td}/bin/ping" << STUB
#!/bin/sh
seq="${td}/ping_seq"
r=\$(head -1 "\$seq")
tail -n +2 "\$seq" > "\${seq}.tmp" && mv "\${seq}.tmp" "\$seq"
exit "\${r:-0}"
STUB
  chmod +x "${td}/bin/ping"

  # date stub
  cat > "${td}/bin/date" << STUB
#!/bin/sh
if [ "\$1" = '+%s' ]; then
  seq="${td}/date_seq"
  v=\$(head -1 "\$seq")
  tail -n +2 "\$seq" > "\${seq}.tmp" && mv "\${seq}.tmp" "\$seq"
  echo "\${v:-0}"
else
  /bin/date "\$@"
fi
STUB
  chmod +x "${td}/bin/date"

  # sleep stub (instant)
  printf '#!/bin/sh\nexit 0\n' > "${td}/bin/sleep"
  chmod +x "${td}/bin/sleep"

  # pidof stub — returns the contents of ${td}/pidof_wanduck when queried
  # for "wanduck"; file absent means the process is not running (exit 1).
  cat > "${td}/bin/pidof" << STUB
#!/bin/sh
if [ "\$1" = "wanduck" ]; then
  file="${td}/pidof_wanduck"
  if [ -f "\$file" ]; then
    cat "\$file"
    exit 0
  fi
  exit 1
fi
exit 1
STUB
  chmod +x "${td}/bin/pidof"

  # logger stub — captures syslog output to LOG_FILE for test assertions.
  # Parses -t TAG and -p PRIO flags; remaining arguments form the message.
  cat > "${td}/bin/logger" << STUB
#!/bin/sh
_tag=""; _prio=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -t) _tag="\$2"; shift 2 ;;
    -p) _prio="\$2"; shift 2 ;;
    -s|-c) shift ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
printf '[%s] %s: %s\n' "\$_prio" "\$_tag" "\$*" >> "\${LOG_FILE:-${td}/wanmoth.log}"
STUB
  chmod +x "${td}/bin/logger"

  # service stub — records each invocation to SERVICE_LOG for test assertions.
  cat > "${td}/bin/service" << STUB
#!/bin/sh
printf '%s\n' "\$*" >> "\${SERVICE_LOG:-${td}/service.log}"
exit 0
STUB
  chmod +x "${td}/bin/service"

  # nslookup stub — exit code is consumed from ${td}/nslookup_seq (one per line)
  # if that file exists; otherwise read from ${td}/nslookup_rc (default 0).
  cat > "${td}/bin/nslookup" << STUB
#!/bin/sh
seq="${td}/nslookup_seq"
if [ -f "\$seq" ]; then
  rc=\$(head -1 "\$seq")
  tail -n +2 "\$seq" > "\${seq}.tmp" && mv "\${seq}.tmp" "\$seq"
  exit "\${rc:-0}"
fi
rc_file="${td}/nslookup_rc"
rc=0
if [ -f "\$rc_file" ]; then rc=\$(cat "\$rc_file"); fi
exit "\${rc:-0}"
STUB
  chmod +x "${td}/bin/nslookup"
}

nvram_val() { grep "^${2}=" "${1}/nvram_store/vars" 2>/dev/null | cut -d= -f2- || true; }

run() {
  local td="$1"; shift
  (
    export PATH="${td}/bin:$PATH"
    export LOG_FILE="${td}/wanmoth.log"
    export SERVICE_LOG="${td}/service.log"
    export LOCK_FILE="${td}/wanmoth.lock"
    export STATE_FILE="${td}/wanmoth_down_since"
    export RESTART_FILE="${td}/wanmoth_last_restart"
    export PING_TARGET=8.8.8.8
    export DOWN_THRESHOLD=30 FAST_POLL_INTERVAL=5
    # Allow callers to pass "VAR=value" pairs as extra arguments
    for kv in "$@"; do
      _k="${kv%%=*}"
      _v="${kv#*=}"
      export "${_k}=${_v}"
    done
    sh "$SCRIPT"
  )
}

# =============================================================================
# Test 1: WAN UP on first check → both wanduck_state and link_internet set
# =============================================================================
echo ""
echo "=== Test 1: WAN UP on entry ==="
T="$(mktemp -d)"
make_stubs "$T" "0" "1000"
run "$T"
assert_equals     "wanduck_state=1"   "1" "$(nvram_val "$T" wanduck_state)"
assert_equals     "link_internet=2"   "2" "$(nvram_val "$T" link_internet)"
assert_equals     "wan0_state=2"      "2" "$(nvram_val "$T" wan0_state)"
assert_equals     "wan0_realstate=2"  "2" "$(nvram_val "$T" wan0_realstate)"
assert_log_contains "log: WAN UP"     "WAN UP"   "${T}/wanmoth.log"
assert_file_absent  "lock removed"    "${T}/wanmoth.lock"
rm -rf "$T"

# =============================================================================
# Test 2: WAN DOWN then quick recovery (below threshold) → DOWN never committed
#         ping: fail once, then succeed
#         epoch: 1000 (record start), 1010 (elapsed=10 < 30)
# =============================================================================
echo ""
echo "=== Test 2: WAN down then quick recovery ==="
T="$(mktemp -d)"
make_stubs "$T" "$(printf '1\n0')" "$(printf '1000\n1010\n1010')"
run "$T"
assert_equals       "wanduck_state=1 (UP)"    "1"   "$(nvram_val "$T" wanduck_state)"
assert_log_contains "log: WAN recovered"      "WAN recovered"        "${T}/wanmoth.log"
assert_file_absent  "down_since file cleared" "${T}/wanmoth_down_since"
rm -rf "$T"

# =============================================================================
# Test 3: WAN DOWN beyond threshold → STATE_DOWN written, then UP on recovery
#         ping: fail, fail, fail, succeed
#         epoch: 1000 (start), 1040 (>30s — threshold exceeded), 1040, 1040
# =============================================================================
echo ""
echo "=== Test 3: WAN down beyond threshold → DOWN written to NVRAM ==="
T="$(mktemp -d)"
make_stubs "$T" "$(printf '1\n1\n1\n0')" "$(printf '1000\n1040\n1040\n1040\n1040')"
run "$T"
assert_log_contains "log: threshold exceeded"  "Outage exceeded"  "${T}/wanmoth.log"
assert_log_contains "log: WAN recovered"       "WAN recovered"    "${T}/wanmoth.log"
assert_equals       "wanduck_state=1 after recovery" "1" "$(nvram_val "$T" wanduck_state)"
assert_equals       "link_internet=2 after recovery" "2" "$(nvram_val "$T" link_internet)"
rm -rf "$T"

# =============================================================================
# Test 4: MANAGE_WAN0_AUXSTATE=true — wan0_auxstate committed after threshold
#         and cleared back to 0 (no error) on recovery.
#         ping: fail x3, then succeed
#         epoch: 1000 (start), 1040 (>30 — threshold), 1040, 1040, 1040
# =============================================================================
echo ""
echo "=== Test 4: MANAGE_WAN0_AUXSTATE=true sets wan0_auxstate ==="
T="$(mktemp -d)"
make_stubs "$T" "$(printf '1\n1\n1\n0')" "$(printf '1000\n1040\n1040\n1040\n1040')"
run "$T" "MANAGE_WAN0_AUXSTATE=true"
assert_log_contains "log: threshold exceeded" "Outage exceeded"  "${T}/wanmoth.log"
assert_log_contains "log: WAN recovered"      "WAN recovered"    "${T}/wanmoth.log"
assert_equals "wan0_auxstate=0 after recovery" "0" "$(nvram_val "$T" wan0_auxstate)"
rm -rf "$T"

# =============================================================================
# Test 5: Lock file with live PID prevents a second instance
# =============================================================================
echo ""
echo "=== Test 5: Lock prevents second instance ==="
T="$(mktemp -d)"
make_stubs "$T" "0" "1000"
echo $$ > "${T}/wanmoth.lock"           # simulate already-running instance
run "$T" || true                        # should exit 0 early (not an error)
assert_log_contains "log: another instance warning" \
  "Another instance" "${T}/wanmoth.log"
rm -rf "$T"

# =============================================================================
# Test 6: wanduck daemon running → script logs and exits immediately
# =============================================================================
echo ""
echo "=== Test 6: wanduck running — script defers and exits ==="
T="$(mktemp -d)"
make_stubs "$T" "0" "1000"
echo "1234" > "${T}/pidof_wanduck"   # simulate wanduck PID
run "$T" || true
assert_log_contains "log: wanduck running" \
  "Daemon wanduck is still running" "${T}/wanmoth.log"
# wanduck_state must NOT be written (no nvram activity expected)
assert_equals "wanduck_state not written" "" "$(nvram_val "$T" wanduck_state)"
rm -rf "$T"

# =============================================================================
# Test 7: RESTART_WAN=true — service restart_wan_if called when threshold exceeded
#         ping: fail x3, then succeed
#         epoch: 1000 (start), 1040 (>30 — threshold), 1040, 1040, 1040
# =============================================================================
echo ""
echo "=== Test 7: RESTART_WAN=true triggers service restart ==="
T="$(mktemp -d)"
make_stubs "$T" "$(printf '1\n1\n1\n0')" "$(printf '1000\n1040\n1040\n1040\n1040\n1040')"
run "$T" \
  "RESTART_WAN=true" \
  "RESTART_WAN_CMD=service restart_wan_if 0" \
  "RESTART_COOLDOWN=300"
assert_log_contains    "log: restart triggered"     "Triggering WAN restart" "${T}/wanmoth.log"
assert_log_contains    "service log: restart called" "restart_wan_if 0"       "${T}/service.log"
rm -rf "$T"

# =============================================================================
# Test 8: Multi-target probe — first target fails, second succeeds → WAN UP
#         Two ping calls: first returns 1, second returns 0
# =============================================================================
echo ""
echo "=== Test 8: Multi-target probe — first fails, second succeeds ==="
T="$(mktemp -d)"
make_stubs "$T" "$(printf '1\n0')" "1000"
run "$T" \
  "PING_TARGETS=192.0.2.1 1.0.0.1"
assert_equals       "wanduck_state=1 (UP)" "1" "$(nvram_val "$T" wanduck_state)"
assert_log_contains "log: WAN UP"          "WAN UP" "${T}/wanmoth.log"
rm -rf "$T"

# =============================================================================
# Test 9: Restart cooldown — second call within RESTART_COOLDOWN does NOT restart
#         First call sets RESTART_FILE at epoch 1000; second call at epoch 1050
#         with RESTART_COOLDOWN=300 should skip restart.
# =============================================================================
echo ""
echo "=== Test 9: Restart cooldown suppresses duplicate restart ==="
T="$(mktemp -d)"
# First invocation: WAN goes down and exceeds threshold, restart fires
make_stubs "$T" "$(printf '1\n1\n1\n0')" "$(printf '1000\n1040\n1040\n1040\n1040\n1040')"
run "$T" \
  "RESTART_WAN=true" \
  "RESTART_WAN_CMD=service restart_wan_if 0" \
  "RESTART_COOLDOWN=300"
assert_log_contains "first restart fired" "restart_wan_if 0" "${T}/service.log"
# Second invocation at epoch 1050 — only 50s since last restart (< 300s cooldown)
# Reset ping_seq and date_seq for the second run
printf '1\n1\n1\n0\n' > "${T}/ping_seq"
printf '1050\n1090\n1090\n1090\n1090\n1090\n' > "${T}/date_seq"
run "$T" \
  "RESTART_WAN=true" \
  "RESTART_WAN_CMD=service restart_wan_if 0" \
  "RESTART_COOLDOWN=300"
restart_count="$(grep -c "restart_wan_if" "${T}/service.log" 2>/dev/null || echo 0)"
assert_equals "second restart suppressed by cooldown" "1" "${restart_count}"
assert_log_contains "log: cooldown message" "cooldown active" "${T}/wanmoth.log"
rm -rf "$T"

# =============================================================================
# Test 10: DNS probe mode — PROBE_MODE=dns with a succeeding nslookup stub
#          Uses deprecated DNS_PROBE_HOST single-host fallback.
# =============================================================================
echo ""
echo "=== Test 10: DNS probe mode — nslookup succeeds → WAN UP ==="
T="$(mktemp -d)"
make_stubs "$T" "1" "1000"   # ping always fails; nslookup will succeed
# nslookup_rc defaults to 0 (success) in the stub — no file needed
run "$T" \
  "PROBE_MODE=dns" \
  "DNS_PROBE_HOST=connectivity-check.example.com"
assert_equals       "wanduck_state=1 (UP via DNS)" "1" "$(nvram_val "$T" wanduck_state)"
assert_log_contains "log: WAN UP via DNS"           "WAN UP" "${T}/wanmoth.log"
rm -rf "$T"

# =============================================================================
# Test 11: Default MANAGE_* settings — all four named NVRAM variables are set
#          to their correct UP values with no overrides.
# =============================================================================
echo ""
echo "=== Test 11: Default MANAGE_* settings set all named NVRAM variables ==="
T="$(mktemp -d)"
make_stubs "$T" "0" "1000"
run "$T"
assert_equals "link_internet=2 (UP)"        "2" "$(nvram_val "$T" link_internet)"
assert_equals "wan0_state=2 (UP)"           "2" "$(nvram_val "$T" wan0_state)"
assert_equals "wan0_realstate=2 (UP)"       "2" "$(nvram_val "$T" wan0_realstate)"
assert_equals "wanduck_state=1 (active)"    "1" "$(nvram_val "$T" wanduck_state)"
assert_equals "wan0_auxstate not written"   ""  "$(nvram_val "$T" wan0_auxstate)"
rm -rf "$T"

# =============================================================================
# Test 12: DNS multi-host probe — first host fails, second succeeds → WAN UP
#          Uses DNS_PROBE_HOSTS (new variable, space-separated list).
# =============================================================================
echo ""
echo "=== Test 12: DNS multi-host probe — first fails, second succeeds ==="
T="$(mktemp -d)"
make_stubs "$T" "1" "1000"   # ping always fails; nslookup will use sequence
printf '1\n0\n' > "${T}/nslookup_seq"   # first DNS host fails, second succeeds
run "$T" \
  "PROBE_MODE=dns" \
  "DNS_PROBE_HOSTS=fail.example.com ok.example.com"
assert_equals       "wanduck_state=1 (UP via DNS multi-host)" "1" "$(nvram_val "$T" wanduck_state)"
assert_log_contains "log: WAN UP"                              "WAN UP" "${T}/wanmoth.log"
rm -rf "$T"

# =============================================================================
# Summary
# =============================================================================
echo ""
printf '==============================\n'
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
printf '==============================\n'
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
