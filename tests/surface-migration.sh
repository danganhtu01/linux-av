#!/usr/bin/env bash
# Exact Surface legacy layout, entirely in an unprivileged private fixture.
# No chroot, host service calls, scanner or checkout target is run.
set -euo pipefail
[ "$EUID" != 0 ] || { echo 'Surface fixture requires an unprivileged user' >&2; exit 2; }
REPO=${AV_REPO_UNDER_TEST:-$(cd "$(dirname "$0")/.." && pwd)}
check_layout() (
layout=$1
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
export T REPO
. "$REPO/tests/fixtures/power-install-env.sh"
fail() { echo "FAIL Surface migration: $*" >&2; cat "$T/out" >&2; exit 1; }
run() { (cd "$T/release" && /bin/sh "$T/installer") > "$T/out" 2>&1; }
units=$R/etc/systemd/system
legacy=/home/atdang/.cache/os-config/repos/danganhtu01/linux-av/bin/av-scan
for name in scan rootkit; do
    arg=--now; [ "$name" != rootkit ] || arg=--rootkit
    unit=linux-av-$name.service
    mkdir -p "$units/$unit.d"
    printf '# Surface legacy unit\n[Unit]\nDescription=Surface %s\n[Service]\nType=oneshot\nEnvironment=AV_SCAN_PATHS=/root\nExecStart=%s %s\nNice=10\nTimeoutStartSec=12h\n[Install]\nWantedBy=multi-user.target\n' "$name" "$legacy" "$arg" > "$units/$unit"
    printf '[Service]\nExecStart=\nExecStart=/usr/local/lib/linux-av/bin/av-scan %s\n' "$arg" > "$units/$unit.d/root-owned.conf"
    if [ "$layout" = guarded ]; then
        printf '[Service]\nExecStartPre=/usr/local/lib/linux-av/bin/av-guard\n' > "$units/$unit.d/05-guard.conf"
    fi
    printf '[Service]\nCPUQuota=37%%\nCPUWeight=20\nMemoryMax=3G\n' > "$units/$unit.d/R-3377-cpu-cap.conf"
done
cp -r "$units" "$T/original"
mkdir -p "$R/etc/linux-av" "$R/var/log/linux-av"
# Fail after the real installer has copied code and set its persistent gate.
# Correct only effective guard readback, then retry without clearing that gate.
printf 'ExecStartPre={ path=/usr/bin/false ; argv[]=/usr/bin/false ; ignore_errors=no ; status=0/0 }\n' > "$R/override.linux-av-scan.service.ExecStartPre"
if run; then fail 'installer accepted incorrect effective guard'; fi
[ -f "$L/lib/root-policy.sh" ] && [ -f "$R/etc/linux-av/power.incomplete" ] || fail 'failed install did not leave code and retry gate'
[ ! -e "$units/linux-av-power.service" ] || fail 'failed install published policy'
rm "$R/override.linux-av-scan.service.ExecStartPre"
run || fail "exact $layout Surface layout rejected on incomplete-install retry"
[ ! -e "$R/etc/linux-av/power.incomplete" ] || fail 'successful retry retained gate'
for name in scan rootkit; do
    arg=--now; [ "$name" != rootkit ] || arg=--rootkit
    unit=linux-av-$name.service
    for rel in "$unit" "$unit.d/root-owned.conf"; do
        sed "s|^ExecStart=.*av-scan $arg$|ExecStart=/bin/sh /usr/local/lib/linux-av/bin/av-root av-scan $arg|" "$T/original/$rel" > "$T/expected"
        cmp -s "$T/expected" "$units/$rel" || fail "unexpected changed bytes: $rel"
        cmp -s "$T/original/$rel" "$units/$rel.before-OC-T-0139" || fail "wrong original backup: $rel"
    done
    if [ "$layout" = unguarded ]; then
        ! grep -r '^ExecStartPre=' "$units/$unit" "$units/$unit.d" || fail 'introduced a pre-start hook'
    fi
    for rel in 05-guard.conf R-3377-cpu-cap.conf; do
        [ -f "$T/original/$unit.d/$rel" ] || continue
        cmp -s "$T/original/$unit.d/$rel" "$units/$unit.d/$rel" || fail "lost guard/limits: $unit/$rel"
    done
done
if grep -E '^(start|stop|restart|enable|disable|kill) ' "$R/calls"; then fail 'service activation during install'; fi
snapshot() { (cd "$R" && find usr/local/lib/linux-av etc var -type f -print0 | sort -z | xargs -0 sha256sum); }
snapshot > "$T/first"
run || fail 'repeat installation failed'
snapshot > "$T/second"
cmp -s "$T/first" "$T/second" || fail 'repeat changed installed bytes/backups'
echo "ok $layout exact Surface migration, default root identity, incomplete retry, settings/backups and stable repeat"

/bin/sh "$L/bin/av-guard" --power > "$T/out" 2>&1 || fail 'installed guard refused'
policy_snapshot() {
    snapshot
    (cd "$R" && find usr/local/lib/linux-av etc var -printf '%y %m %U %G %T@ %C@ %p %l\n' | sort)
}
readonly_verify() {
    policy_snapshot > "$T/verify-before"
    : > "$R/calls"
    if /bin/bash "$T/policy-driver" verify > "$T/out" 2>&1; then status=0; else status=$?; fi
    policy_snapshot > "$T/verify-after"
    cmp -s "$T/verify-before" "$T/verify-after" || fail 'verification changed installed bytes/metadata'
    if grep -v '^show ' "$R/calls"; then fail 'verification mutated systemd'; fi
}
readonly_verify
[ "$status" = 0 ] || fail 'installed/effective policy verification refused'
grep -qx 'linux-av: installed power policy verified' "$T/out" || fail 'missing policy verification success'
for name in scan rootkit; do
    unit=linux-av-$name.service
    wrong=--rootkit; [ "$name" != rootkit ] || wrong=--now
    printf 'ExecStart={ path=/bin/sh ; argv[]=/bin/sh /usr/local/lib/linux-av/bin/av-root av-scan %s ; ignore_errors=no ; status=0/0 }\n' "$wrong" > "$R/override.$unit.ExecStart"
    readonly_verify
    [ "$status" != 0 ] && grep -q 'unexpected effective ExecStart' "$T/out" || fail 'verification accepted swapped scan/rootkit argument'
    rm "$R/override.$unit.ExecStart"
    for pre in '' 'ExecStartPre=garbage' \
        'ExecStartPre={ path=/usr/bin/false ; argv[]=/usr/bin/false ; ignore_errors=no ; status=0/0 }' \
        'ExecStartPre={ path=/usr/local/lib/linux-av/bin/av-guard ; argv[]=/usr/local/lib/linux-av/bin/av-guard ; ignore_errors=yes ; status=0/0 }'; do
        printf '%s' "$pre" > "$R/override.$unit.ExecStartPre"
        readonly_verify
        [ "$status" != 0 ] && grep -q 'unsupported effective ExecStartPre' "$T/out" || fail 'verification accepted unexpected pre-start readback'
    done
    rm "$R/override.$unit.ExecStartPre"
done
echo "ok $layout installed guard and read-only effective-policy success/negative readback"

# Each negative starts from the same exact original layout. Check all unit bytes
# and backups, and require refusal before daemon-reload or any service action.
reset_units() {
    rm -rf -- "$units"
    cp -r "$T/original" "$units"
    rm -f "$R"/override.* "$R/stat-foreign"
    : > "$R/etc/linux-av/power.incomplete"
    : > "$R/calls"
}
unit_snapshot() {
    (cd "$units" && find . -printf '%y %m %U %G %p %l\n' | sort)
    (cd "$units" && find . -type f -print0 | sort -z | xargs -0 sha256sum)
}
refused() {
    unit_snapshot > "$T/before-refusal"
    if /bin/bash "$T/policy-driver" > "$T/out" 2>&1; then fail "accepted $1"; fi
    unit_snapshot > "$T/after-refusal"
    cmp -s "$T/before-refusal" "$T/after-refusal" || fail "wrote units/backups on refusal: $1"
    [ -f "$R/etc/linux-av/power.incomplete" ] || fail "removed retry gate on refusal: $1"
    if grep -v '^show ' "$R/calls"; then fail "service-manager mutation on refusal: $1"; fi
    grep -Eq 'unsupported|unexpected|missing|not loaded|stale|av-guard:|unsafe|symlink|cannot inspect' "$T/out" || fail "unexplained refusal: $1"
}
negatives=0
for name in scan rootkit; do
    unit=linux-av-$name.service
    arg=--now; other=--rootkit
    [ "$name" != rootkit ] || { arg=--rootkit; other=--now; }
    for defect in missing_override no_reset extra_reset duplicate_base wrong_section indented continuation \
        other_checkout shell_prefix command_modifier base_arg override_arg extra_arg unknown_exec environment \
        unexpected_pre duplicate_guard malformed_pre blank_pre later_command later_guard wrong_effective_arg ignore_errors stale fragment unloaded_override \
        foreign_base foreign_override writable_base writable_override writable_parent symlink user group dynamic_user; do
        reset_units
        base=$units/$unit; override=$units/$unit.d/root-owned.conf
        case $defect in
            missing_override) rm "$override" ;;
            no_reset) sed -i '/^ExecStart=$/d' "$override" ;;
            extra_reset) printf 'ExecStart=\n' >> "$override" ;;
            duplicate_base) printf '\n[Service]\nExecStart=%s %s\n' "$legacy" "$arg" >> "$base" ;;
            wrong_section) sed -i 's/^\[Service\]/[Unit]/' "$base" ;;
            indented) sed -i 's/^ExecStart=/ ExecStart=/' "$base" ;;
            continuation) sed -i '/^ExecStart=/s/$/\\/' "$base" ;;
            other_checkout) sed -i 's|/home/atdang/|/home/other/|' "$base" ;;
            shell_prefix) sed -i 's|^ExecStart=/home/|ExecStart=/bin/sh /home/|' "$base" ;;
            command_modifier) sed -i 's|^ExecStart=/home/|ExecStart=-/home/|' "$base" ;;
            base_arg) sed -i "s/ $arg$/ $other/" "$base" ;;
            override_arg) sed -i "s/ $arg$/ $other/" "$override" ;;
            extra_arg) sed -i '/^ExecStart=./s/$/ --path \/root/' "$base" ;;
            unknown_exec) printf '\n[Service]\nExecStartPost=/usr/bin/false' >> "$base" ;;
            environment) printf '\n[Service]\nEnvironmentFile=%s/etc/default/unreviewed\n' "$R" >> "$base" ;;
            unexpected_pre) printf '\n[Service]\nExecStartPre=/usr/bin/false\n' >> "$base" ;;
            duplicate_guard) printf '[Service]\nExecStartPre=/usr/local/lib/linux-av/bin/av-guard\nExecStartPre=/usr/local/lib/linux-av/bin/av-guard\n' > "$units/$unit.d/zz-other.conf" ;;
            malformed_pre) printf 'ExecStartPre=garbage\n' > "$R/override.$unit.ExecStartPre" ;;
            blank_pre) : > "$R/override.$unit.ExecStartPre" ;;
            later_command) printf '[Service]\nExecStart=\nExecStart=/usr/bin/false\n' > "$units/$unit.d/zz-other.conf" ;;
            later_guard) printf '[Service]\nExecStartPre=/usr/bin/false\n' > "$units/$unit.d/zz-other.conf" ;;
            wrong_effective_arg) printf 'ExecStart={ path=/usr/local/lib/linux-av/bin/av-scan ; argv[]=/usr/local/lib/linux-av/bin/av-scan %s ; ignore_errors=no ; status=0/0 }\n' "$other" > "$R/override.$unit.ExecStart" ;;
            ignore_errors) printf 'ExecStartPre={ path=/usr/local/lib/linux-av/bin/av-guard ; argv[]=/usr/local/lib/linux-av/bin/av-guard ; ignore_errors=yes ; status=0/0 }\n' > "$R/override.$unit.ExecStartPre" ;;
            stale) echo yes > "$R/override.$unit.NeedDaemonReload" ;;
            fragment) echo "$R/usr/lib/systemd/system/other.service" > "$R/override.$unit.FragmentPath" ;;
            unloaded_override) echo "$units/$unit.d/05-guard.conf" > "$R/override.$unit.DropInPaths" ;;
            foreign_base) echo "$base" > "$R/stat-foreign" ;;
            foreign_override) echo "$override" > "$R/stat-foreign" ;;
            writable_base) chmod 0664 "$base" ;;
            writable_override) chmod 0666 "$override" ;;
            writable_parent) chmod 0775 "$units/$unit.d" ;;
            symlink) mv "$override" "$T/linked-override"; ln -s "$T/linked-override" "$override" ;;
            user) echo atdang > "$R/override.$unit.User" ;;
            group) echo atdang > "$R/override.$unit.Group" ;;
            dynamic_user) echo yes > "$R/override.$unit.DynamicUser" ;;
        esac
        refused "$layout/$name/$defect"
        negatives=$((negatives+1))
    done
done
[ ! -e "$R/forbidden-probe" ] || fail 'inspected or resolved writable checkout target'
echo "ok $layout $negatives Surface negatives: structure, exact paths/arguments, pre-start hooks, identity, metadata and preserved refusal state"
)
check_layout unguarded
check_layout guarded
