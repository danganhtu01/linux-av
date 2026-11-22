#!/usr/bin/env bash
# Root-only, disposable chroot. No host install, service call, scan or payload.
set -euo pipefail
[ "$EUID" = 0 ] || { echo 'skip root-power: requires root in a disposable container'; exit 0; }
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf --one-file-system -- "$T"' EXIT
R=$T/root
fail() { echo "FAIL root-power: $*" >&2; exit 1; }
mkdir -p "$R"; chmod 0755 "$R"
# Copy OS tools and their loaders to the private root, without bind mounts.
copy_binary() {
    local path=$1 dep
    mkdir -p "$R/${path%/*}"
    cp -L "$path" "$R/$path"
    while read -r dep; do
        [ -f "$dep" ] || continue
        mkdir -p "$R/${dep%/*}"; cp -L "$dep" "$R/$dep"
    done < <(ldd "$path" 2>/dev/null | awk '/=> \/|^[[:space:]]*\// {for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}')
}
for tool in /bin/sh /bin/bash /usr/bin/env; do copy_binary "$tool"; done
for tool in id stat readlink hostname mktemp mkdir cp mv install rm sed grep cmp sort cut wc sha256sum date dirname getent cat sleep tr flock seq sync ln chmod timeout; do
    copy_binary "$(command -v "$tool")"
done
mkdir -p "$R/usr/sbin" "$R/etc/systemd/system" "$R/etc/cron.daily" "$R/run" "$R/root" "$R/release" "$R/sys/class/power_supply" "$R/dev" "$R/proc/1/fd"
chmod 0700 "$R/root"
# Regular empty file is sufficient for these synthetic shell checks.
: > "$R/dev/null"
: > "$R/proc/1/cmdline"
mkdir -p "$R/proc/self/fd"
# No proc mount: synthetic identity for the installer-inherited lock descriptor.
ln -s /run/linux-av-policy.lock "$R/proc/self/fd/9"
printf 'root:x:0:0:root:/root:/bin/bash\n' > "$R/etc/passwd"
printf 'root:x:0:\n' > "$R/etc/group"
printf 'ID=debian\n' > "$R/etc/os-release"
cat > "$R/usr/sbin/hostname" <<'STUB'
#!/bin/sh
echo Surface
STUB
cp "$REPO/tests/fixtures/policy-systemctl" "$R/usr/sbin/systemctl"
chmod 0755 "$R/usr/sbin/hostname" "$R/usr/sbin/systemctl"
for dir in bin lib systemd; do cp -r "$REPO/$dir" "$R/release/$dir"; done
cp "$REPO/root-install-power.sh" "$R/installer"
chmod 0600 "$R/installer"
# Simulate a caller-owned checkout; only pinned private snapshots may execute.
chown -R 1000:1000 "$R/release"
mkdir -p "$R/etc/systemd/system/linux-av-scan.service.d" "$R/etc/systemd/system/linux-av-rootkit.service.d"
printf '[Service]\nExecStart=/home/atdang/.cache/os-config/repos/danganhtu01/linux-av/bin/av-scan --now\nNice=10\n' > "$R/etc/systemd/system/linux-av-scan.service"
printf '[Service]\nExecStart=/home/atdang/.cache/os-config/repos/danganhtu01/linux-av/bin/av-scan --rootkit\n' > "$R/etc/systemd/system/linux-av-rootkit.service"
printf '[Service]\nExecStart=\nExecStart=/usr/local/lib/linux-av/bin/av-scan --now\n' > "$R/etc/systemd/system/linux-av-scan.service.d/root-owned.conf"
printf '[Service]\nExecStart=\nExecStart=/usr/local/lib/linux-av/bin/av-scan --rootkit\n' > "$R/etc/systemd/system/linux-av-rootkit.service.d/root-owned.conf"
printf '[Service]\nCPUQuota=37%%\nCPUWeight=20\nMemoryMax=3G\n' > "$R/etc/systemd/system/linux-av-scan.service.d/R-3377-cpu-cap.conf"
printf '[Service]\nExecStartPre=/usr/local/lib/linux-av/bin/av-guard\n' > "$R/etc/systemd/system/linux-av-scan.service.d/05-guard.conf"
printf '[Service]\nExecStartPre=/usr/local/lib/linux-av/bin/av-guard\n' > "$R/etc/systemd/system/linux-av-rootkit.service.d/05-guard.conf"
printf '#!/bin/sh\n# inert packaged daily fixture\nexit 0\n' > "$R/etc/cron.daily/rkhunter"
chmod 0755 "$R/etc/cron.daily/rkhunter"
mkdir -p "$R/etc/default"
printf 'INERT_FIXTURE=yes\n' > "$R/etc/default/check-fixture"
printf '[Service]\nExecStart=/usr/bin/true\nEnvironmentFile=/etc/default/check-fixture\n' > "$R/etc/systemd/system/chkrootkit.service"
run() { chroot "$R" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root /bin/sh -c 'cd /release && /bin/sh /installer' > "$T/out" 2>&1; }
# Pin mismatch must leave the destination and policy untouched.
printf '\n' >> "$R/release/bin/av-power"
if run; then fail 'pin mismatch accepted'; fi
grep -q 'pin mismatch' "$T/out" || { cat "$T/out"; fail 'wrong refusal'; }
[ ! -e "$R/usr/local/lib/linux-av" ] || fail 'pin refusal wrote installed tree'
cp "$REPO/bin/av-power" "$R/release/bin/av-power"
# Active cron is returned by the shared systemctl fixture. An already-running
# affected package job must time out with dispatch disabled before any permanent
# code is copied. The fixture process census remains synthetic.
mkdir -p "$R/proc/22/fd"
printf '/bin/sh\0/etc/cron.daily/rkhunter\0' > "$R/proc/22/cmdline"
if run; then fail 'already-running cron package job accepted'; fi
grep -q 'already running' "$T/out" || { cat "$T/out"; fail 'wrong running-cron refusal'; }
grep -q 'timed out' "$T/out" || fail 'missing bounded drain timeout'
grep -qx '# linux-av cron migration disabled' "$R/etc/cron.daily/rkhunter" || fail 'timeout re-enabled legacy dispatch'
[ ! -e "$R/usr/local/lib/linux-av" ] || fail 'running-cron refusal wrote permanent code'
rm -rf "$R/proc/22"
printf 'active\n' > "$R/override.linux-av-scan.service.ActiveState"
if run; then fail 'active scanner accepted'; fi
grep -q 'quiesce' "$T/out" || fail 'scanner quiescence protection lost'
rm "$R/override.linux-av-scan.service.ActiveState"
chmod 0664 "$R/etc/default/check-fixture"
if run; then fail 'writable systemd environment input accepted'; fi
grep -q 'unsafe owner/mode' "$T/out" || { cat "$T/out"; fail 'environment-file audit missing'; }
[ ! -e "$R/etc/systemd/system/linux-av-power.service" ] || fail 'preflight refusal wrote policy'
chmod 0644 "$R/etc/default/check-fixture"
run || { cat "$T/out"; fail 'install failed'; }
[ ! -e "$R/etc/linux-av/power.incomplete" ] || fail 'successful install retained incomplete marker'
L=$R/usr/local/lib/linux-av
for rel in bin/av-root bin/av-guard bin/av-power bin/av-scan bin/av-setup lib/common.sh lib/reports.sh lib/root-policy.sh; do
    cmp "$L/$rel" "$REPO/$rel" || fail "wrong permanent bytes: $rel"
    case $rel in bin/*) mode=755 ;; *) mode=644 ;; esac
    [ "$(stat -c '%u %g %a' "$L/$rel")" = "0 0 $mode" ] || fail "wrong ownership/mode: $rel"
done
grep -qx 'ExecStart=/bin/sh /usr/local/lib/linux-av/bin/av-root av-scan --now' "$R/etc/systemd/system/linux-av-scan.service" || fail 'scan base not migrated'
grep -qx 'ExecStart=/bin/sh /usr/local/lib/linux-av/bin/av-root av-scan --rootkit' "$R/etc/systemd/system/linux-av-rootkit.service" || fail 'rootkit base not migrated'
grep -qx 'ExecStart=/bin/sh /usr/local/lib/linux-av/bin/av-root av-scan --now' "$R/etc/systemd/system/linux-av-scan.service.d/root-owned.conf" || fail 'override not migrated'
grep -qx 'ExecStart=/bin/sh /usr/local/lib/linux-av/bin/av-root av-scan --rootkit' "$R/etc/systemd/system/linux-av-rootkit.service.d/root-owned.conf" || fail 'rootkit override not migrated'
grep -qx 'ExecStartPre=/usr/local/lib/linux-av/bin/av-guard' "$R/etc/systemd/system/linux-av-scan.service.d/05-guard.conf" || fail 'guard lost'
grep -qx 'CPUQuota=37%' "$R/etc/systemd/system/linux-av-scan.service.d/R-3377-cpu-cap.conf" || fail 'CPU cap lost'
grep -qx 'MemoryMax=3G' "$R/etc/systemd/system/linux-av-scan.service.d/R-3377-cpu-cap.conf" || fail 'memory limit lost'
cmp "$R/etc/cron.daily/rkhunter.linux-av-power-original" "$R/etc/cron.daily/rkhunter.before-OC-T-0139" || fail 'cron original/backup differ'
if grep -R -E '/release|@POWER@' "$R/etc/systemd/system" "$R/etc/cron.daily"; then fail 'checkout path persisted'; fi
if grep -E '^(start|stop|restart|enable|disable|kill) ' "$R/calls"; then fail 'activation during install'; fi
echo 'ok root permanent copy, supported unit migration, limits, guard, cron and no activation'
# Idempotence includes first backups; fixture checks actual metadata and bytes.
snapshot() { (cd "$R" && find usr/local/lib/linux-av etc var -type f -print0 | sort -z | xargs -0 sha256sum); }
same_snapshot() {
    if ! cmp -s "$1" "$2"; then
        diff -u "$1" "$2" >&2 || true
        fail "$3"
    fi
}
snapshot > "$T/first"
run || { cat "$T/out"; fail 'second install failed'; }
snapshot > "$T/second"
same_snapshot "$T/first" "$T/second" 'repeat changed installed bytes/backups'
echo 'ok root upgrade idempotence with cron active'
# Read-only rerun contract: verified bytes and metadata stay unchanged, and only
# systemctl show calls occur. No staging, logs, reload or service changes.
verify_policy() {
    chroot "$R" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
        /bin/sh /usr/local/lib/linux-av/bin/av-root av-setup power-policy-verify > "$T/out" 2>&1
}
policy_metadata() { (cd "$R" && find usr/local/lib/linux-av etc run var -printf '%y %m %U %G %T@ %C@ %p %l\n' | sort); }
readonly_check() {
    snapshot > "$T/verify-before"; policy_metadata > "$T/meta-before"; : > "$R/calls"
    if verify_policy; then status=0; else status=$?; fi
    snapshot > "$T/verify-after"; policy_metadata > "$T/meta-after"
    same_snapshot "$T/verify-before" "$T/verify-after" 'verifier wrote installed bytes'
    same_snapshot "$T/meta-before" "$T/meta-after" 'verifier wrote metadata/directories'
    if grep -v '^show ' "$R/calls"; then fail 'verifier changed service manager'; fi
}
: > "$R/etc/linux-av/power.incomplete"
readonly_check; [ "$status" != 0 ] || fail 'incomplete installation verified'
rm "$R/etc/linux-av/power.incomplete"
readonly_check
[ "$status" = 0 ] || { cat "$T/out"; fail 'installed policy verification failed'; }
[ "$(cat "$T/out")" = $'av-guard: ok\nlinux-av: installed power policy verified' ] || fail 'wrong verifier success contract'
printf 'active\n' > "$R/override.linux-av-power.service.ActiveState"
readonly_check
[ "$status" = 0 ] || fail 'read-only verifier required inactive guardian'
rm "$R/override.linux-av-power.service.ActiveState"
for path in "$R/etc/linux-av/power.units" "$R/etc/cron.daily/rkhunter" \
    "$R/etc/cron.daily/rkhunter.linux-av-power-original" "$R/etc/systemd/system/linux-av-power.service"; do
    cp -p "$path" "$T/saved-policy"
    printf '\n# inert mismatch\n' >> "$path"
    readonly_check; [ "$status" != 0 ] || fail "mismatched policy accepted: $path"
    cp -p "$T/saved-policy" "$path"
done
printf 'yes\n' > "$R/override.linux-av-power.service.NeedDaemonReload"
readonly_check; [ "$status" != 0 ] || fail 'stale loaded policy accepted'
rm "$R/override.linux-av-power.service.NeedDaemonReload"
printf 'ExecStart={ path=/usr/bin/false ; argv[]=/usr/bin/false ; ignore_errors=no ; status=0/0 }\n' > "$R/override.linux-av-power.service.ExecStart"
readonly_check; [ "$status" != 0 ] || fail 'effective command mismatch accepted'
rm "$R/override.linux-av-power.service.ExecStart"
echo 'ok root read-only installed/effective-policy success, mismatches and no service changes'
# Inert inherited settings must not select user config, paths, binaries or state.
mkdir -p "$R/caller/.config/linux-av"
printf 'AV_ROOT=/caller\n' > "$R/caller/av.env"
printf 'AV_ROOT=/caller\n' > "$R/caller/.config/linux-av/av.env"
chown -R 1000:1000 "$R/caller"
chroot "$R" /usr/bin/env -i PATH=/caller HOME=/caller XDG_CONFIG_HOME=/caller/.config AV_CONFIG=/caller/av.env \
    BASH_ENV=/caller/av.env ENV=/caller/av.env AV_HOME=/caller AV_ROOT=/caller AV_POWER_UNITS_FILE=/caller/units AV_POWER_STATE_DIR=/caller/state \
    _AV_COMMON_SH=1 /bin/sh /usr/local/lib/linux-av/bin/av-root av-power --check > "$T/out" 2>&1 || { cat "$T/out"; fail 'inherited env affected root check'; }
[ "$(cat "$T/out")" = 'av-guard: ok' ] || { cat "$T/out"; fail 'unexpected config/startup output'; }
[ ! -e "$R/caller/state" ] || fail 'inherited state used'
echo 'ok root launcher ignores inherited config and control paths'
# Ownership/type defects contain no payload and never run a scanner.
check_refused() {
    if chroot "$R" /bin/sh /usr/local/lib/linux-av/bin/av-root av-power --check > "$T/out" 2>&1; then fail "unsafe path accepted: $1"; fi
    grep -q 'av-guard:' "$T/out" || { cat "$T/out"; fail "wrong ownership refusal: $1"; }
}
for path in "$L/bin/av-power" "$L/bin/av-root" "$L/lib/common.sh" "$L/lib/reports.sh" "$L/lib/root-policy.sh" "$L/systemd/av-power.conf" \
    "$R/etc/linux-av/power.units" "$R/etc/systemd/system/linux-av-power.service" \
    "$R/etc/systemd/system/clamav-daemon.service.d" "$R/etc/cron.daily/rkhunter.linux-av-power-original"; do
    chmod g+w "$path"; check_refused "$path"; chmod g-w "$path"
    chown 1000 "$path"; check_refused "$path"; chown 0 "$path"
done
printf 'AV_ENGINE=clamscan\n' > "$R/etc/linux-av/av.env"
chmod 0664 "$R/etc/linux-av/av.env"; check_refused config; chmod 0644 "$R/etc/linux-av/av.env"
mv "$R/etc/linux-av/av.env" "$R/etc/linux-av/av.env.saved"
ln -s av.env.saved "$R/etc/linux-av/av.env"; check_refused 'config link'
rm "$R/etc/linux-av/av.env"; mv "$R/etc/linux-av/av.env.saved" "$R/etc/linux-av/av.env"
mkdir -p "$R/run/linux-av-power/pending"
chmod 0777 "$R/run/linux-av-power/pending"; check_refused pending; chmod 0755 "$R/run/linux-av-power/pending"
echo 'ok root ownership checks cover code, config, units, drop-in parents, cron and runtime state'
# A new distro cron script is retained on upgrade.
printf '#!/bin/sh\n# inert updated package fixture\nexit 0\n' > "$R/etc/cron.daily/rkhunter"
run || { cat "$T/out"; fail 'package cron upgrade failed'; }
grep -q 'updated package fixture' "$R/etc/cron.daily/rkhunter.linux-av-power-original" || fail 'new package cron lost'
# A later unit override is detected by effective command read-back.
printf '[Service]\nExecStart=/usr/bin/false\n' > "$R/etc/systemd/system/linux-av-power.service.dummy"
mkdir -p "$R/etc/systemd/system/linux-av-power.service.d"
mv "$R/etc/systemd/system/linux-av-power.service.dummy" "$R/etc/systemd/system/linux-av-power.service.d/99-override.conf"
if run; then fail 'effective guardian override accepted'; fi
grep -q 'unexpected effective ExecStart' "$T/out" || { cat "$T/out"; fail 'read-back did not catch override'; }
echo 'ok package cron upgrade and effective systemd read-back refusal'
