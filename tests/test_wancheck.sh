#!/bin/sh
# =============================================================================
# tests/test_wancheck.sh — Unit/integration tests for wancheck.sh
#
# Strategy: create a per-test stub directory early on PATH so that `nvram`,
# `ping`, `date`, and `sleep` can be replaced without patching the script.
# =============================================================================
set -e

# Resolve the script path relative to this test file's location
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${TESTS_DIR}/../wancheck.sh"

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
}

nvram_val() { grep "^${2}=" "${1}/nvram_store/vars" 2>/dev/null | cut -d= -f2- || true; }

run() {
    local td="$1"; shift
    (
        export PATH="${td}/bin:$PATH"
        export LOG_FILE="${td}/wancheck.log"
        export LOCK_FILE="${td}/wancheck.lock"
        export STATE_FILE="${td}/wancheck_down_since"
        export PING_TARGET=8.8.8.8
        export NVRAM_VAR=wanduck_state
        export STATE_UP=2 STATE_DOWN=0
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
# Test 1: WAN UP on first check → NVRAM set to STATE_UP (2)
# =============================================================================
echo ""
echo "=== Test 1: WAN UP on entry ==="
T="$(mktemp -d)"
make_stubs "$T" "0" "1000"
run "$T"
assert_equals     "wanduck_state=2"  "2" "$(nvram_val "$T" wanduck_state)"
assert_log_contains "log: WAN UP"    "WAN UP"   "${T}/wancheck.log"
assert_file_absent  "lock removed"   "${T}/wancheck.lock"
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
assert_equals       "wanduck_state=2 (UP)"    "2"   "$(nvram_val "$T" wanduck_state)"
assert_log_contains "log: WAN recovered"      "WAN recovered"        "${T}/wancheck.log"
assert_file_absent  "down_since file cleared" "${T}/wancheck_down_since"
rm -rf "$T"

# =============================================================================
# Test 3: WAN DOWN beyond threshold → STATE_DOWN committed, then UP on recovery
#         ping: fail, fail, fail, succeed
#         epoch: 1000 (start), 1040 (>30s — threshold exceeded), 1040, 1040
# =============================================================================
echo ""
echo "=== Test 3: WAN down beyond threshold → DOWN committed ==="
T="$(mktemp -d)"
make_stubs "$T" "$(printf '1\n1\n1\n0')" "$(printf '1000\n1040\n1040\n1040\n1040')"
run "$T"
assert_log_contains "log: threshold exceeded"  "Outage exceeded"  "${T}/wancheck.log"
assert_log_contains "log: WAN recovered"       "WAN recovered"    "${T}/wancheck.log"
assert_equals       "wanduck_state=2 after recovery" "2" "$(nvram_val "$T" wanduck_state)"
rm -rf "$T"

# =============================================================================
# Test 4: EXTRA_NVRAM_VARS — additional variables are synced on WAN UP
# =============================================================================
echo ""
echo "=== Test 4: Extra NVRAM variables synced ==="
T="$(mktemp -d)"
make_stubs "$T" "0" "1000"
run "$T" \
    "EXTRA_NVRAM_VARS=wan0_state_t:2:0 custom_flag:1:0"
assert_equals "wan0_state_t=2"  "2" "$(nvram_val "$T" wan0_state_t)"
assert_equals "custom_flag=1"   "1" "$(nvram_val "$T" custom_flag)"
rm -rf "$T"

# =============================================================================
# Test 5: Lock file with live PID prevents a second instance
# =============================================================================
echo ""
echo "=== Test 5: Lock prevents second instance ==="
T="$(mktemp -d)"
make_stubs "$T" "0" "1000"
echo $$ > "${T}/wancheck.lock"          # simulate already-running instance
run "$T" || true                        # should exit 0 early (not an error)
assert_log_contains "log: another instance warning" \
    "Another instance" "${T}/wancheck.log"
rm -rf "$T"

# =============================================================================
# Summary
# =============================================================================
echo ""
printf '==============================\n'
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
printf '==============================\n'
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
