#!/usr/bin/env bash
# Inert unprivileged policy/readback + /proc fixtures. No host systemctl, sudo,
# cron dispatch, scanner, chroot, ownership change or service action.
set -euo pipefail
[ "$EUID" != 0 ] || { echo 'policy fixtures require an unprivileged user' >&2; exit 2; }
REPO=${AV_REPO_UNDER_TEST:-$(cd "$(dirname "$0")/.." && pwd)}
T=$(mktemp -d)
locker= launched=
cleanup() {
    for pid in $locker $launched; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
    rm -rf -- "$T"
}
trap cleanup EXIT
R=$T/root; B=$T/bin; L=$R/usr/local/lib/linux-av
mkdir -p "$B" "$L" "$R/etc/linux-av" "$R/etc/cron.daily" "$R/etc/systemd/system" "$R/proc/1/fd" "$R/run" "$T/home"
for dir in bin lib systemd; do cp -r "$REPO/$dir" "$L/$dir"; done
: > "$R/etc/linux-av/av.env"; : > "$R/proc/1/cmdline"
cp "$REPO/tests/fixtures/policy-systemctl" "$B/systemctl"; chmod +x "$B/systemctl"
# Root metadata is simulated ONLY in this test PATH. Real bytes/types/modes and
# every verification branch are exercised; real root ownership needs root-power.
cat > "$B/stat" <<'STUB'
#!/bin/bash
set -eu
if [ "$1" = -c ] && [ "$2" = '%u %g %a' ]; then
    owner=0
    if [ -f "$POLICY_FIXTURE_ROOT/stat-foreign" ] && [ "$(cat "$POLICY_FIXTURE_ROOT/stat-foreign")" = "$3" ]; then owner=1000; fi
    printf '%s 0 %s\n' "$owner" "$(/usr/bin/stat -c %a "$3")"
elif [ "$1" = -c ] && [ "$2" = '%u %A' ]; then
    printf '0 %s\n' "$(/usr/bin/stat -c %A "$3")"
else exec /usr/bin/stat "$@"; fi
STUB
chmod +x "$B/stat"
fail() { echo "FAIL policy: $*" >&2; [ ! -f "$T/out" ] || cat "$T/out" >&2; exit 1; }
run_env() {
    env -i PATH="$B:/usr/bin:/bin" HOME="$T/home" AV_ROOT="$R" AV_CONFIG="$R/etc/linux-av/av.env" \
        AV_HOME="$L" AV_COLOR=never AV_LOG_FILE="$T/install.log" POLICY_FIXTURE_ROOT="$R" "$@"
}
install_policy() {
    run_env /bin/bash -c '. "$AV_HOME/lib/common.sh"; . "$AV_HOME/lib/root-policy.sh"; av_install_power_policy' > "$T/out" 2>&1
}
verify_policy() { run_env /bin/bash "$L/bin/av-setup" power-policy-verify > "$T/out" 2>&1; }
snapshot() {
    # Read-only verification must not touch even mtime/ctime or directory state.
    find "$R" "$T/home" -printf '%y %m %U %G %T@ %C@ %p %l\n' | sort
    find "$R" "$T/home" -type f ! -path "$R/calls" -print0 | sort -z | xargs -0 sha256sum
    if [ -f "$T/install.log" ]; then
        find "$T/install.log" -printf '%y %m %U %G %T@ %C@ %p\n'
        sha256sum "$T/install.log"
    fi
}
unchanged_verify() {
    snapshot > "$T/before"
    : > "$R/calls"
    if verify_policy; then status=0; else status=$?; fi
    snapshot > "$T/after"
    # Calls are the only fixture side effect; the command never writes installed
    # paths or logs. Exclude stub call-record timestamps as well as its contents.
    sed "\\| $R/calls |d;\\| $R/calls\$|d" "$T/before" > "$T/a"
    sed "\\| $R/calls |d;\\| $R/calls\$|d" "$T/after" > "$T/b"
    cmp -s "$T/a" "$T/b" || fail 'verification changed fixture files/metadata'
    if grep -v '^show ' "$R/calls"; then fail 'verification called a mutating systemctl operation'; fi
}
refused() {
    unchanged_verify
    [ "$status" != 0 ] || fail "mismatch accepted: $1"
    grep -q "$1" "$T/out" || fail "wrong refusal; wanted $1"
}
# Fresh and existing active cron are independent of inactive managed scanners.
# Exercise the actual installer quiescence block in isolation, without running it.
sed -n '/^quiescent() {/,/^t=$(mktemp/ { /^t=$(mktemp/!p; }' "$REPO/root-install-power.sh" > "$T/quiescent"
# Existing inventory read is fixed to the host in production; this test copy has
# one explicit scratch-path substitution, never an installer test-root option.
sed -i "s|/etc/linux-av/power.units|$R/etc/linux-av/power.units|g" "$T/quiescent"
quiescent() { run_env /bin/sh -c 'fail() { echo "$*" >&2; exit 1; }; . "$1"' sh "$T/quiescent"; }
[ "$(run_env "$B/systemctl" show cron.service -p ActiveState --value)" = active ] || fail 'cron fixture not active'
quiescent || fail 'fresh active cron refused'
printf 'active\n' > "$R/override.linux-av-scan.service.ActiveState"
if quiescent > "$T/out" 2>&1; then fail 'active scanner accepted'; fi
rm "$R/override.linux-av-scan.service.ActiveState"
printf '#!/bin/sh\n# inert package fixture\nexit 0\n' > "$R/etc/cron.daily/rkhunter"
chmod 0755 "$R/etc/cron.daily/rkhunter"
printf '[Service]\nExecStart=/usr/local/bin/av-scan --now\n' > "$R/etc/systemd/system/linux-av-scan.service"
printf '[Service]\nExecStart=/usr/local/lib/linux-av/bin/av-scan --rootkit\n' > "$R/etc/systemd/system/linux-av-rootkit.service"
printf '[Timer]\nOnBootSec=1min\n' > "$R/etc/systemd/system/linux-av-scan.timer"
install_policy || fail 'fresh policy render'
chmod 0600 "$R/etc/systemd/system/linux-av-scan.service" "$R/etc/cron.daily/rkhunter.linux-av-power-original"
install_policy || fail 'existing policy metadata normalization'
[ "$(/usr/bin/stat -c %a "$R/etc/systemd/system/linux-av-scan.service")" = 644 ] || fail 'canonical unit metadata not normalized'
[ "$(/usr/bin/stat -c %a "$R/etc/cron.daily/rkhunter.linux-av-power-original")" = 644 ] || fail 'retained original metadata not normalized'
quiescent || fail 'existing active cron refused'
cp -p "$R/etc/linux-av/power.units" "$T/inventory"
printf 'custom-scan.service\n' >> "$R/etc/linux-av/power.units"
printf 'active\n' > "$R/override.custom-scan.service.ActiveState"
if quiescent > "$T/out" 2>&1; then fail 'active custom inventory scanner accepted'; fi
rm "$R/override.custom-scan.service.ActiveState"
cp -p "$T/inventory" "$R/etc/linux-av/power.units"
# Never execute production preflight on the host: base/proc name scratch paths.
sed -e "s|^proc=/proc\$|proc='$R/proc'|" -e "s|^base=\$|base='$R'|" "$REPO/bin/av-guard" > "$T/preflight"
/bin/sh "$T/preflight" --cron-idle || fail 'idle process fixture refused'
mkdir -p "$R/proc/22/fd"
for job in /etc/cron.daily/rkhunter /etc/cron.daily/aide-common.linux-av-power-original /usr/bin/run-parts /usr/sbin/anacron /usr/bin/aide.wrapper /usr/sbin/clamd /usr/local/lib/linux-av/bin/av-power; do
    printf '/bin/sh\0%s\0' "$job" > "$R/proc/22/cmdline"
    if /bin/sh "$T/preflight" --cron-idle > "$T/out" 2>&1; then fail "running job accepted: $job"; fi
done
# A recognized guarded launcher waiting with the real lock descriptor is safe.
: > "$R/run/linux-av-policy.lock"
ln -s "$R/run/linux-av-policy.lock" "$R/proc/22/fd/9"
printf '/bin/sh\0/usr/local/lib/linux-av/bin/av-root\0av-power\0--cron\0/etc/cron.daily/rkhunter.linux-av-power-original\0' > "$R/proc/22/cmdline"
/bin/sh "$T/preflight" --cron-idle || fail 'guarded lock waiter refused'
printf '/bin/sh\0/etc/cron.daily/rkhunter-unrelated\0' > "$R/proc/22/cmdline"
/bin/sh "$T/preflight" --cron-idle || fail 'unrelated similarly named route refused'
printf '/bin/sh\0-c\0/etc/cron.daily/rkhunter; :\0' > "$R/proc/22/cmdline"
if /bin/sh "$T/preflight" --cron-idle > "$T/out" 2>&1; then fail 'shell dispatch string accepted'; fi
rm -rf "$R/proc/22"
mv "$R/proc/1/cmdline" "$R/proc/1/hidden"
if /bin/sh "$T/preflight" --cron-idle > "$T/out" 2>&1; then fail 'unreadable proc accepted'; fi
mv "$R/proc/1/hidden" "$R/proc/1/cmdline"
echo 'ok active cron, existing inventory and affected-job preflight (synthetic)'
# Exercise the actual launcher's lock with inert tool/identity stand-ins. Only
# fixed lib/PATH/lock paths are relocated in a private copy; no production knob.
cp -p "$L/bin/av-guard" "$T/saved-guard"
cp -p "$L/bin/av-power" "$T/saved-power"
sed -e "s|^base=\$|base='$R'|" -e "s|^PATH=.*|PATH='$B:/usr/bin:/bin'|" "$REPO/bin/av-guard" > "$L/bin/av-guard"
printf '#!/bin/sh\necho 0\n' > "$B/id"; chmod +x "$B/id"
sed -e "s|^lib=/usr/local/lib/linux-av\$|lib='$L'|" -e "s|^PATH=.*|PATH='$B:/usr/bin:/bin'|" \
    -e "s|/run/linux-av-policy|$R/run/linux-av-policy|g" -e "s|/etc/linux-av/power.incomplete|$R/etc/linux-av/power.incomplete|g" "$REPO/bin/av-root" > "$T/launcher"
# Both migrated scan arguments cross the launcher's own guard before the tool.
# The stand-in records argv only; no scanner is executed.
cp -p "$L/bin/av-scan" "$T/saved-scan"
printf 'printf "%%s\\n" "$@"\n' > "$L/bin/av-scan"
for arg in --now --rootkit; do
    /bin/sh "$T/launcher" av-scan "$arg" > "$T/out" 2>&1 || fail 'scan launcher refused safe tree'
    [ "$(cat "$T/out")" = "$(printf 'av-guard: ok\n%s' "$arg")" ] || fail 'scan launcher skipped guard or changed argument'
    chmod g+w "$L/bin/av-scan"
    if /bin/sh "$T/launcher" av-scan "$arg" > "$T/out" 2>&1; then fail 'scan launcher bypassed guard'; fi
    grep -q 'av-guard:' "$T/out" || fail 'scan launcher did not report guard refusal'
    ! grep -qx -- "$arg" "$T/out" || fail 'scan stand-in ran after guard refusal'
    chmod g-w "$L/bin/av-scan"
done
cp -p "$T/saved-scan" "$L/bin/av-scan"
echo 'ok scan launcher enforces its own guard for both migrated arguments (inert stand-in)'
printf 'printf ran > "%s"\nread -r line < "%s"\n' "$T/cron-ran" "$T/job-release" > "$L/bin/av-power"
mkfifo "$T/install-release" "$T/job-release"
flock --no-fork -x "$R/run/linux-av-policy.lock" /bin/bash -c 'touch "$1"; read -r line < "$2"' sh "$T/locked" "$T/install-release" & locker=$!
for ((n=0;n<100;n++)); do [ ! -e "$T/locked" ] || break; sleep 0.01; done
[ -e "$T/locked" ] || fail 'exclusive lock fixture did not start'
/bin/sh "$T/launcher" av-power --cron /etc/cron.daily/rkhunter.linux-av-power-original > "$T/launch-out" 2>&1 & launched=$!
sleep 0.1
[ ! -e "$T/cron-ran" ] || fail 'cron crossed exclusive installation lock'
printf 'release\n' > "$T/install-release"; wait "$locker"; locker=
for ((n=0;n<100;n++)); do [ ! -e "$T/cron-ran" ] || break; sleep 0.01; done
[ -e "$T/cron-ran" ] || { cat "$T/launch-out"; fail 'cron did not resume after installation'; }
if flock -n -x "$R/run/linux-av-policy.lock" /bin/true; then fail 'exclusive install lock crossed running cron'; fi
printf 'release\n' > "$T/job-release"; wait "$launched"; launched=
: > "$R/etc/linux-av/power.incomplete"; rm "$T/cron-ran"
if /bin/sh "$T/launcher" av-power --cron /etc/cron.daily/rkhunter.linux-av-power-original > "$T/out" 2>&1; then fail 'cron ran after incomplete installation'; else status=$?; fi
[ "$status" = 75 ] && [ ! -e "$T/cron-ran" ] || fail 'incomplete policy did not defer cron'
rm "$R/etc/linux-av/power.incomplete"
cp -p "$T/saved-guard" "$L/bin/av-guard"; cp -p "$T/saved-power" "$L/bin/av-power"; rm "$B/id"
echo 'ok guarded cron waits across installation and holds shared lock for job lifetime'
# Use current trusted test release inputs, not production override controls.
while read -r _ _ hash rel; do
    [ -n "${rel:-}" ] || continue
    case $rel in bin/*) chmod 0755 "$L/$rel" ;; *) chmod 0644 "$L/$rel" ;; esac
    printf '%s %s\n' "$(sha256sum < "$L/$rel" | cut -c1-64)" "$rel"
done < <(sed -n '/^# sha256 /p' "$REPO/root-install-power.sh") > "$R/etc/linux-av/power.release.sha256"
chmod 0644 "$R/etc/linux-av/power.release.sha256"
# av-guard itself on the installed scratch tree: only base and PATH differ.
sed -e "s|^base=\$|base='$R'|" -e "s|^PATH=.*|PATH='$B:/usr/bin:/bin'|" "$REPO/bin/av-guard" > "$T/guard"
/bin/sh "$T/guard" --power > "$T/out" 2>&1 || fail 'synthetic installed av-guard refused'
unchanged_verify
[ "$status" = 0 ] || fail 'matching installed policy refused'
[ "$(cat "$T/out")" = 'linux-av: installed power policy verified' ] || fail 'success marker differs'
echo 'ok read-only verified installed policy (simulated root metadata)'
: > "$R/etc/linux-av/power.incomplete"; refused 'installation incomplete'; rm "$R/etc/linux-av/power.incomplete"
# Unknown options must also refuse without logs or other writes.
snapshot > "$T/options-before"
if run_env /bin/bash "$L/bin/av-setup" power-policy-verify --repair > "$T/out" 2>&1; then fail 'verifier accepted options'; fi
snapshot > "$T/options-after"
cmp -s "$T/options-before" "$T/options-after" || fail 'argument refusal wrote installed state'
for file in "$R/etc/systemd/system/linux-av-power.service" "$R/etc/systemd/system/clamav-daemon.service.d/40-linux-av-power.conf" "$R/etc/systemd/system/linux-av-scan.timer.d/40-linux-av-power.conf" "$R/etc/linux-av/power.units" "$R/etc/cron.daily/rkhunter" "$R/etc/linux-av/power.cron.sha256"; do
    cp -p "$file" "$T/saved"
    printf '\n# mismatch\n' >> "$file"; refused 'policy bytes differ'
    cp -p "$T/saved" "$file"
    chmod 0600 "$file"; refused 'type/owner/mode'
    cp -p "$T/saved" "$file"
    printf '%s\n' "$file" > "$R/stat-foreign"; refused 'type/owner/mode'; rm "$R/stat-foreign"
done
original=$R/etc/cron.daily/rkhunter.linux-av-power-original
cp -p "$original" "$T/saved"
printf '# changed original\n' >> "$original"; refused 'policy bytes differ'
cp -p "$T/saved" "$original"
chmod 0755 "$original"; refused 'wrong cron original'; chmod 0644 "$original"
mv "$original" "$T/original"
refused 'wrong cron original'; mv "$T/original" "$original"
for prop in NeedDaemonReload ExecStart ExecCondition ExecStopPost KillMode Requires BindsTo After Conditions; do
    case $prop in
        NeedDaemonReload) unit=linux-av-power.service; value=yes; want='stale loaded policy' ;;
        ExecStart) unit=linux-av-power.service; value='override'; want='unexpected effective ExecStart' ;;
        ExecCondition|ExecStopPost) unit=linux-av-scan.service; value='override'; want="unexpected effective $prop" ;;
        Conditions) unit=linux-av-scan.timer; value=ConditionACPower; want='AC condition bypasses' ;;
        *) unit=linux-av-scan.service; value=override; want="$prop" ;;
    esac
    printf '%s\n' "$value" > "$R/override.$unit.$prop"
    refused "$want"; rm "$R/override.$unit.$prop"
done
: > "$R/force-not-found.linux-av-power.service"; refused 'installed unit not loaded'; rm "$R/force-not-found.linux-av-power.service"
: > "$R/show-failure"; refused 'cannot inspect'; rm "$R/show-failure"
for name in scan rootkit; do
    unit=linux-av-$name.service
    wrong=--rootkit; [ "$name" != rootkit ] || wrong=--now
    printf 'ExecStart={ path=/bin/sh ; argv[]=/bin/sh /usr/local/lib/linux-av/bin/av-root av-scan %s ; ignore_errors=no ; status=0/0 }\n' "$wrong" > "$R/override.$unit.ExecStart"
    refused 'unexpected effective ExecStart'
    rm "$R/override.$unit.ExecStart"
    # Explicit emptiness and one permanent guard are the two valid readbacks.
    printf 'ExecStartPre={ path=/usr/local/lib/linux-av/bin/av-guard ; argv[]=/usr/local/lib/linux-av/bin/av-guard ; ignore_errors=no ; status=0/0 }\n' > "$R/override.$unit.ExecStartPre"
    unchanged_verify
    [ "$status" = 0 ] || fail 'known permanent pre-start guard refused'
    for pre in '' 'ExecStartPre=garbage' \
        'ExecStartPre={ path=/usr/bin/false ; argv[]=/usr/bin/false ; ignore_errors=no ; status=0/0 }' \
        'ExecStartPre={ path=/usr/local/lib/linux-av/bin/av-guard ; argv[]=/usr/local/lib/linux-av/bin/av-guard ; ignore_errors=yes ; status=0/0 }'; do
        printf '%s' "$pre" > "$R/override.$unit.ExecStartPre"
        refused 'unsupported effective ExecStartPre'
    done
    rm "$R/override.$unit.ExecStartPre"
done
cp -p "$L/bin/av-power" "$T/saved-code"
printf '\n' >> "$L/bin/av-power"; refused 'installed release bytes differ'
cp -p "$T/saved-code" "$L/bin/av-power"
printf 'AV_TIMER_NAME=custom-scan\n' > "$R/etc/linux-av/av.env"; refused 'policy bytes differ'
: > "$R/etc/linux-av/av.env"
# Original snapshots + metadata checks must fail on unsafe guard paths too.
chmod 0666 "$original"
if /bin/sh "$T/guard" --power > "$T/out" 2>&1; then fail 'av-guard allowed writable cron original'; fi
chmod 0644 "$original"
echo 'ok file bytes/modes/owners, originals, inventory, loaded state and command mismatches; all read-only'
