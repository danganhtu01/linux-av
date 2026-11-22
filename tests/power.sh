#!/usr/bin/env bash
# Synthetic sysfs + process stand-ins only. Never contacts the host service manager.
set -uo pipefail
REPO="${AV_REPO_UNDER_TEST:-$(cd "$(dirname "$0")/.." && pwd)}"
BASH_BIN="$BASH"
T="$(mktemp -d)" || exit 2
jobs_to_stop=()
cleanup() {
    local pid
    for pid in "${jobs_to_stop[@]}"; do av_power_stop_tree "$pid"; done
    if [ -f "$T/pids" ]; then
        while read -r pid; do kill -KILL "$pid" 2>/dev/null || true; done < "$T/pids"
    fi
    rm -rf -- "$T"
}
trap cleanup EXIT
fail() { echo "FAIL power: $*" >&2; exit 1; }
export HOME="$T/home" AV_CONFIG="$T/av.env" AV_HOME="$REPO" AV_COLOR=never
export AV_POWER_SUPPLY_DIR="$T/power" AV_POWER_STATE_DIR="$T/state"
export AV_POWER_UNITS_FILE="$T/units" AV_POWER_POLL_INTERVAL=0.03
export AV_LOG_DIR="$T/log" AV_LOG_FILE="$T/log/av-scan.log"
export AV_EXCLUDE_FSTYPES= AV_EXCLUDE_PATTERNS= AV_FULL_EVERY=0
export PATH="$T/bin:$PATH" POWER_TEST_DIR="$T"
mkdir -p "$HOME" "$T/power" "$T/bin" "$T/log" "$T/services"
: > "$AV_CONFIG"
# shellcheck source=../lib/common.sh
. "$REPO/lib/common.sh"

value() { printf '%s\n' "$2" > "$1.new"; mv -f "$1.new" "$1"; }
ac() { value "$T/power/adapter/online" 1; value "$T/power/battery/status" Charging; }
battery() { value "$T/power/battery/status" Discharging; value "$T/power/adapter/online" 0; }
yes_power() { av_on_mains || fail "mains rejected: $*"; }
no_power() { if av_on_mains; then fail "battery/unknown accepted: $*"; fi; }
alive() {
    local state a b rest
    read -r a b state rest 2>/dev/null < "/proc/$1/stat" || return 1
    [ "$state" != Z ] && [ "$state" != X ]
}
await_file() {
    local i
    for ((i=0;i<250;i++)); do [ ! -s "$1" ] || return 0; /bin/sleep 0.02; done
    fail "timed out waiting for $1"
}
await_dead() {
    local i
    for ((i=0;i<250;i++)); do alive "$1" || return 0; /bin/sleep 0.02; done
    fail "process $1 survived power cancellation"
}

yes_power 'batteryless server, empty class'
mkdir -p "$T/power/battery" "$T/power/adapter"
value "$T/power/battery/type" Battery
value "$T/power/battery/present" 0
value "$T/power/adapter/type" Mains
value "$T/power/adapter/online" 0
yes_power 'empty battery slot'
value "$T/power/battery/present" 1
no_power 'missing battery status'
ac; yes_power AC
value "$T/power/battery/status" Discharging
no_power 'discharging wins over stale online adapter'
for type in Mains USB USB_C USB_PD USB_PD_DRP USB_DCP USB_ACA USB_HVDCP Wireless; do
    value "$T/power/adapter/type" "$type"
    ac; yes_power "$type"
    battery; no_power "$type unplugged"
done
value "$T/power/adapter/type" BrickID; ac; yes_power BrickID
mkdir "$T/power/second"
value "$T/power/second/type" Mains
value "$T/power/second/online" 1
value "$T/power/adapter/online" 0
yes_power 'one of multiple adapters online'
rm -rf "$T/power/second"
value "$T/power/battery/type" UPS
value "$T/power/battery/online" 1; yes_power 'UPS on mains'
value "$T/power/battery/online" 0; no_power 'UPS offline'
value "$T/power/battery/type" Battery
ac
value "$T/power/battery/status" Unknown; no_power 'online but battery unknown'
rm "$T/power/adapter/online"; value "$T/power/battery/status" Full
no_power 'full battery without positive mains'
value "$T/power/battery/status" 'Not charging'; no_power 'idle battery without mains'
ac; value "$T/power/battery/status" 'Not charging'; yes_power 'idle battery on mains'
mkdir "$T/power/peripheral"
value "$T/power/peripheral/type" Battery
value "$T/power/peripheral/scope" Device
value "$T/power/peripheral/status" Discharging
yes_power 'peripheral excluded'
value "$T/power/battery/scope" Device
rm "$T/power/adapter/online"; yes_power 'no system battery'
rm "$T/power/battery/scope"; ac
mkdir "$T/power/unknown"
value "$T/power/unknown/type" Unknown
no_power 'unknown supply with battery'
rm -rf "$T/power/unknown"
echo 'ok power_supply matrix'

# Every scanner is a harmless long-running process with a TERM-resistant child.
cat > "$T/bin/standin" <<'EOF'
#!/usr/bin/env bash
echo "${0##*/} $*" >> "$POWER_TEST_DIR/calls"
if [ "${0##*/}" = clamdscan ]; then
    for arg in "$@"; do
        case "$arg" in --config-file=*) cat "${arg#*=}" > "$POWER_TEST_DIR/client.config" ;; esac
    done
fi
[ ! -f "$POWER_TEST_DIR/complete" ] || exit 0
trap '' TERM
/bin/sleep 60 &
printf '%s\n%s\n' "$$" "$!" >> "$POWER_TEST_DIR/pids"
wait
EOF
chmod +x "$T/bin/standin"
for name in clamscan clamdscan rkhunter chkrootkit aide aide.wrapper; do
    ln -s standin "$T/bin/$name"
done
cat > "$T/bin/freshclam" <<'EOF'
#!/bin/sh
echo refresh >> "$POWER_TEST_DIR/refresh"
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$POWER_TEST_DIR/systemctl.calls"
unit=""; for arg in "$@"; do case "$arg" in *.service|*.socket) unit="$arg" ;; esac; done
file="$POWER_TEST_DIR/services/$unit"
case "$1" in
    show) if [ -f "$file" ]; then echo active; else echo inactive; fi ;;
    is-active|is-enabled) [ -f "$file" ] ;;
    kill)
        if [ -s "$file" ]; then
            read -r pid < "$file"
            kill -KILL -- "-$pid" 2>/dev/null || true
        fi ;;
    stop) rm -f "$file" ;;
    start) echo started >> "$POWER_TEST_DIR/resumed.$unit"; touch "$file" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/systemctl" "$T/bin/freshclam"

battery
for mode in --now --rootkit --integrity; do
    "$BASH_BIN" "$REPO/bin/av-scan" "$mode" > "$T/output" 2>&1
    [ "$?" = 75 ] || fail "$mode did not defer on battery"
done
[ ! -e "$T/calls" ] || fail 'scanner invoked on battery'
"$BASH_BIN" "$REPO/bin/av-scan" --update > "$T/output" 2>&1
[ -s "$T/refresh" ] || fail 'signature refresh was blocked'
echo 'ok entry gates and signature refresh separation'

for mode in --now --rootkit --integrity; do
    ac; rm -f "$T/pids"
    "$BASH_BIN" "$REPO/bin/av-scan" "$mode" > "$T/output" 2>&1 &
    job=$!; jobs_to_stop+=("$job")
    await_file "$T/pids"; mapfile -t pids < "$T/pids"
    battery; await_dead "$job"
    wait "$job"; rc=$?
    [ "$rc" = 75 ] || fail "$mode cancellation status $rc: $(cat "$T/output")"
    for pid in "${pids[@]}"; do await_dead "$pid"; done
    [ ! -e "$AV_LOG_DIR/last-good-scan.stamp" ] || fail 'cancelled scan advanced stamp'
done
echo 'ok unplug kills scanners, timeout groups and descendants'

# A scheduled job waits on battery, is cancelled on unplug, and starts afresh
# on reconnect. Only the completed retry can advance a scan stamp.
rm -f "$T/pids" "$T/calls"
"$BASH_BIN" "$REPO/bin/av-scan" --wait-for-mains --now > "$T/output" 2>&1 &
job=$!; jobs_to_stop+=("$job")
/bin/sleep 0.1
[ ! -e "$T/calls" ] || fail 'waiting schedule scanned on battery'
ac; await_file "$T/pids"; mapfile -t pids < "$T/pids"
battery
for pid in "${pids[@]}"; do await_dead "$pid"; done
alive "$job" || fail 'schedule did not remain pending'
touch "$T/complete"; ac
await_dead "$job"; wait "$job" || fail "reconnected scan failed: $(cat "$T/output")"
[ -f "$AV_LOG_DIR/last-good-scan.stamp" ] || fail 'completed retry did not advance stamp'
echo 'ok scheduled reconnect recovery'

battery; rm -f "$T/complete" "$T/pids" "$T/calls"
"$BASH_BIN" "$REPO/bin/av-scan" --scheduled 600000 > "$T/loop.output" 2>&1 &
job=$!; jobs_to_stop+=("$job")
/bin/sleep 0.1
[ ! -e "$T/calls" ] || fail 'foreground schedule scanned on battery'
ac; await_file "$T/pids"; mapfile -t pids < "$T/pids"
battery
for pid in "${pids[@]}"; do await_dead "$pid"; done
touch "$T/complete"; ac
for ((i=0;i<250;i++)); do
    grep -q 'clean — no threats' "$T/loop.output" && break
    /bin/sleep 0.02
done
[ "$i" -lt 250 ] || fail 'foreground loop did not resume on reconnect'
av_power_stop_tree "$job"; wait "$job" 2>/dev/null || true
echo 'ok foreground loop reconnect recovery'

# Delegated work is a separate session, not a client descendant. The fake
# systemctl implements a service cgroup kill using that session's process group.
rm -f "$T/complete" "$T/pids"
setsid "$T/bin/standin" > "$T/daemon.output" 2>&1 & daemon=$!
jobs_to_stop+=("$daemon")
await_file "$T/pids"; mapfile -t pids < "$T/pids"
printf '%s\n' "$daemon" > "$T/services/clamav-daemon.service"
touch "$T/services/linux-av-power.service" "$T/services/clamav-clamonacc.service"
printf '%s\n' clamav-daemon.service clamav-daemon.socket clamav-clamonacc.service chkrootkit.service > "$T/units"
"$BASH_BIN" "$REPO/bin/av-power" --watch > "$T/watch.output" 2>&1 &
guardian=$!; jobs_to_stop+=("$guardian")
"$BASH_BIN" "$REPO/bin/av-scan" --engine clamdscan --now > "$T/client.output" 2>&1 &
client=$!; jobs_to_stop+=("$client")
for ((i=0;i<250;i++)); do
    if grep -q '^clamdscan .*--config-file=/dev/fd/' "$T/calls"; then break; fi
    /bin/sleep 0.02
done
[ "$i" -lt 250 ] || fail "local daemon client not started: $(cat "$T/client.output")"
await_file "$T/client.config"
grep -qx 'LocalSocket /run/clamav/clamd.ctl' "$T/client.config" || fail 'client was not pinned to a local socket'
battery
for pid in "${pids[@]}" "$client"; do await_dead "$pid"; done
wait "$client"; [ "$?" = 75 ] || fail 'delegating client did not cancel'
"$BASH_BIN" "$REPO/bin/av-power" --check-unit chkrootkit.service
[ "$?" = 1 ] || fail 'service gate did not skip on battery'
[ -f "$AV_POWER_STATE_DIR/pending/chkrootkit.service" ] || fail 'missed scheduled service not queued'
ac
await_file "$T/resumed.clamav-daemon.service"
await_file "$T/resumed.clamav-clamonacc.service"
await_file "$T/resumed.chkrootkit.service"
EXIT_STATUS=75 "$BASH_BIN" "$REPO/bin/av-power" --finished-unit rkhunter.service
await_file "$T/resumed.rkhunter.service"
"$BASH_BIN" "$REPO/bin/av-power" --finished-unit clean.service
[ ! -e "$AV_POWER_STATE_DIR/pending/clean.service" ] || fail 'clean service completion queued another run'
av_power_stop_tree "$guardian"; wait "$guardian" 2>/dev/null || true
wait "$daemon" 2>/dev/null || true
echo 'ok delegated daemon cancellation and service/on-access reconnect'

# No guardian means no delegation, including an explicitly requested engine.
AV_CLAMD_SOCKET=/tmp/unmanaged.sock "$BASH_BIN" "$REPO/bin/av-scan" --engine clamdscan --now > "$T/output" 2>&1
[ "$?" = 2 ] || fail 'custom daemon socket accepted'
rm -f "$T/services/linux-av-power.service"
"$BASH_BIN" "$REPO/bin/av-scan" --engine clamdscan --now > "$T/output" 2>&1
[ "$?" = 2 ] || fail 'unmanaged delegation accepted'

# The same command supervisor also covers packaged cron, coalescing repeats.
battery; rm -f "$T/pids"
"$BASH_BIN" "$REPO/bin/av-power" --cron "$T/bin/standin" > "$T/cron.output" 2>&1 &
job=$!; jobs_to_stop+=("$job")
/bin/sleep 0.1
[ ! -e "$T/pids" ] || fail 'cron scanned on battery'
touch "$T/complete"; ac
await_dead "$job"; wait "$job" || fail "cron did not resume: $(cat "$T/cron.output")"
echo 'ok packaged cron recovery'

rm -rf "$T/power"/*
"$BASH_BIN" "$REPO/bin/av-scan" --now > "$T/output" 2>&1 || fail 'batteryless scan failed'
echo 'ok batteryless scan'
jobs_to_stop=()
