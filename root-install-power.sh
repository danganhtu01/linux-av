#!/bin/sh
# OC-T-0139: run ONLY a separately SHA-256 verified, root-private copy of this
# installer, with env -i, from a verified release tree (see README Surface).
# Unlike OVH's separate installers this supports Arch/Debian/Ubuntu. No package
# transaction, scan, baseline, or unit activation. Existing OVH installers and
# their hostname/CPU-cap safeguards remain separate and unchanged.
# The release runner pins this script externally. These pins cover ALL inputs
# copied/loaded by it; a private snapshot is checked before any input executes.
# sha256 20a73f712d58be113db050b53281c9124d22a8bf9f7d895818f644e3f24286b9 bin/av-guard
# sha256 febff35d3765fd8c4b29d6f09d2f88e7c8013cdaa6765c341e626b33a21f3b14 bin/av-root
# sha256 41b6ec0e3f6382bf37136e9b9b2f9408cb04251c39cb8e341aeee7be6e2adff4 bin/av-power
# sha256 63d881cc652f56f0f8a2cbde92f526d613b8ddd9a6bb7937dff1311563f27fbd bin/av-scan
# sha256 13bc3d95921adfed9c6aacf24dfe086a475395457a2c0c66bba3b24e818e3d3b bin/av-setup
# sha256 8d730e8f4405b4e80b7a97c9c38ecfe0440bec818e23557754244fdeb747aa1d lib/common.sh
# sha256 a35b9f810543a712f838525deefa997515a140dcf4b97fae4923dfa1b1f0bf60 lib/reports.sh
# sha256 8db19d6c2442cc7477d46e8b4fe1175e3bbda535cde26049781747f19b4b3c00 lib/root-policy.sh
# sha256 0c48256a3148b363c0f4e4e69d8e4af65d97cf2edb2ff3eaa7bf80ce26efa7bc systemd/av-power.service
# sha256 41455f962a29df522a72a14c92bc9aad8655f0cf59a5f3ed337fbc58ab539aa9 systemd/av-power.conf
# sha256 f63f123c07e3fb672e6fef8317a6a398681d7f8c091916bb72355806cc9fd626 systemd/av-scan.service
# sha256 002098433b8c2064ce3b0f45b12a6018a5d680dfea5224cc4c54d9568297401e systemd/av-rootkit.service
# sha256 62f4350a76997f522135fb5b593fcab8d9e745fdb828ba865ea1a0f674dea736 systemd/av-scan.timer
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 022
unset ENV BASH_ENV CDPATH
fail() { echo "root-install-power: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail 'root required'
[ "$#" = 0 ] || fail 'takes no arguments; run from the release tree'
# Check every ancestor, rejecting links, foreign owners, and writable paths.
sound() {
    path=$1 cur=/ rest=${1#/}
    while :; do
        [ ! -L "$cur" ] || fail "symlink: $cur"
        if [ -e "$cur" ]; then
            perm=$(stat -c '%u %A' "$cur")
            [ "${perm%% *}" = 0 ] || fail "not root-owned: $cur"
            case ${perm#* } in ?????[!w]??[!w]?) ;; *) fail "writable: $cur" ;; esac
            [ -f "$cur" ] || [ -d "$cur" ] || fail "not regular: $cur"
            [ "$cur" = "$path" ] || [ -d "$cur" ] || fail "not a directory: $cur"
        fi
        [ -n "$rest" ] || break
        cur=${cur%/}/${rest%%/*}
        case $rest in */*) rest=${rest#*/} ;; *) rest= ;; esac
    done
}
# The script/header is itself part of the trusted root boundary. Never read a
# manifest from a writable checkout and never re-open an input after checking it.
[ ! -L "$0" ] || fail 'installer is a symlink'
self=$(readlink -f -- "$0")
sound "$self"
[ -f "$self" ] || fail 'installer must be a regular file'
sound /run
src=$(pwd -P)
dst=/usr/local/lib/linux-av
sound "$dst"
for dir in bin lib systemd; do sound "$dst/$dir"; done
sound /etc/systemd/system
# Preserve the OVH cap precondition when upgrading an OVH installation.
if [ "$(hostname)" = OVH ]; then
    cap=/etc/systemd/system/linux-av-scan.service.d/R-3377-cpu-cap.conf
    sound "$cap"
    [ -f "$cap" ] || fail 'OVH CPU cap missing; use the OVH deployment card'
    grep -q '^CPUQuota=[[:space:]]*[^[:space:]]' "$cap" || fail 'OVH CPUQuota missing'
    grep -q '^CPUWeight=[[:space:]]*[^[:space:]]' "$cap" || fail 'OVH CPUWeight missing'
fi
# Do not race a running guardian, scan or timer while replacing the permanent
# files. The operator arranges a maintenance window; this installer stops none.
sound /etc/linux-av/power.release.sha256
sound /etc/linux-av/power.release.sha256.before-OC-T-0139
[ ! -d /etc/linux-av/power.release.sha256 ] && [ ! -d /etc/linux-av/power.release.sha256.before-OC-T-0139 ] || fail 'release manifest destination is a directory'
sound /etc/linux-av/power.units
quiescent() {
    state=$(systemctl show "$1" -p ActiveState --value) || [ "$state" = inactive ] || fail "cannot inspect $1"
    case $state in inactive|failed) ;; *) fail "$1 is $state; quiesce in a separately authorized maintenance step" ;; esac
}
for unit in linux-av-power.service linux-av-scan.service linux-av-rootkit.service \
    linux-av-scan.timer linux-av-rootkit.timer clamav-daemon.service clamav-daemon.socket \
    clamav-clamonacc.service chkrootkit.service rkhunter.service aidecheck.service dailyaidecheck.service \
    linux-av-aide-init.service chkrootkit.timer rkhunter.timer aidecheck.timer dailyaidecheck.timer; do
    quiescent "$unit"
done
if [ -f /etc/linux-av/power.units ]; then
    while IFS= read -r unit; do
        case $unit in ''|*[!a-zA-Z0-9_:@.-]*) fail 'invalid existing unit inventory' ;; esac
        case $unit in *.service|*.socket) ;; *) fail 'invalid existing unit suffix' ;; esac
        quiescent "$unit"
        case $unit in *.service) quiescent "${unit%.service}.timer" ;; esac
    done < /etc/linux-av/power.units
fi
t=$(mktemp -d /run/linux-av-root-power.XXXXXXXX)
trap 'rm -rf --one-file-system -- "$t"' EXIT HUP INT TERM
mkdir "$t/bin" "$t/lib" "$t/systemd"
pins=$(sed -n 's/^# sha256 //p' "$self")
[ "$(printf '%s\n' "$pins" | wc -l)" = 13 ] || fail 'expected exactly 13 pinned inputs'
printf '%s\n' "$pins" > "$t/pins"
while read -r hash rel extra; do
    [ -z "$extra" ] || fail 'invalid pin'
    case $rel in
        bin/av-guard|bin/av-root|bin/av-power|bin/av-scan|bin/av-setup|lib/common.sh|lib/reports.sh|lib/root-policy.sh|systemd/av-power.service|systemd/av-power.conf|systemd/av-scan.service|systemd/av-rootkit.service|systemd/av-scan.timer) ;;
        *) fail "unlisted input: $rel" ;;
    esac
    [ -f "$src/$rel" ] && [ ! -L "$src/$rel" ] || fail "missing/linked input: $rel"
    cp -- "$src/$rel" "$t/$rel"
    [ "$(sha256sum < "$t/$rel" | cut -c1-64)" = "$hash" ] || fail "pin mismatch: $rel"
    sound "$dst/$rel"; sound "$dst/$rel.before-OC-T-0139"
    [ ! -d "$dst/$rel" ] && [ ! -d "$dst/$rel.before-OC-T-0139" ] || fail "directory destination: $rel"
done < "$t/pins"
[ "$(cut -d' ' -f2 "$t/pins" | sort -u | wc -l)" = 13 ] || fail 'duplicate input pin'
# All syntax and hashes checked before any installed write, and all backups
# completed before replacing code. Private staging works even on noexec /run.
for rel in bin/av-root bin/av-guard; do /bin/sh -n "$t/$rel"; done
for rel in bin/av-power bin/av-scan bin/av-setup lib/common.sh lib/reports.sh lib/root-policy.sh; do
    /usr/bin/env -i PATH="$PATH" /bin/bash --noprofile --norc -p -n "$t/$rel"
done
# cron/crond may remain active. Disable raw package routes before draining old
# jobs, with the pinned snapshot and exclusive lock, before installing code.
sound /etc/linux-av/power.incomplete
[ ! -e /etc/linux-av/power.incomplete ] || [ -f /etc/linux-av/power.incomplete ] || fail 'policy incomplete marker is not regular'
sound /run/linux-av-policy.lock
[ ! -e /run/linux-av-policy.lock ] || [ -f /run/linux-av-policy.lock ] || fail 'policy lock is not regular'
exec 9>>/run/linux-av-policy.lock
flock -n -x 9 || fail 'policy/cron work in progress'
/bin/sh "$t/bin/av-guard" --cron-disable || fail 'could not disable legacy cron dispatch'
/bin/sh "$t/bin/av-guard" --cron-wait || fail 'legacy cron drain failed; dispatch disabled; retry after jobs finish'
while read -r hash rel; do
    if [ -f "$dst/$rel" ] && ! cmp -s "$t/$rel" "$dst/$rel" && [ ! -e "$dst/$rel.before-OC-T-0139" ]; then
        cp -p -- "$dst/$rel" "$dst/$rel.before-OC-T-0139" || fail "backup failed: $rel"
    fi
done < "$t/pins"
if [ -f /etc/linux-av/power.release.sha256 ] && ! cmp -s "$t/pins" /etc/linux-av/power.release.sha256 && [ ! -e /etc/linux-av/power.release.sha256.before-OC-T-0139 ]; then
    cp -p /etc/linux-av/power.release.sha256 /etc/linux-av/power.release.sha256.before-OC-T-0139 || fail 'release manifest backup failed'
fi
install -d -o root -g root -m 0755 /etc/linux-av
# Persistent across failure/reboot: queued cron must not run partial new policy.
: > /etc/linux-av/power.incomplete
install -d -o root -g root -m 0755 "$dst" "$dst/bin" "$dst/lib" "$dst/systemd"
while read -r hash rel; do
    case $rel in bin/*) mode=0755 ;; *) mode=0644 ;; esac
    if [ -f "$dst/$rel" ] && cmp -s "$t/$rel" "$dst/$rel" && [ "$(stat -c '%u %g %a' "$dst/$rel")" = "0 0 ${mode#0}" ]; then continue; fi
    rm -f -- "$dst/$rel.new"
    install -o root -g root -m "$mode" "$t/$rel" "$dst/$rel.new"
    mv -f -- "$dst/$rel.new" "$dst/$rel"
done < "$t/pins"
if ! cmp -s "$t/pins" /etc/linux-av/power.release.sha256 || [ "$(stat -c '%u %g %a' /etc/linux-av/power.release.sha256)" != '0 0 644' ]; then
    rm -f /etc/linux-av/power.release.sha256.new
    install -o root -g root -m 0644 "$t/pins" /etc/linux-av/power.release.sha256.new
    mv -f /etc/linux-av/power.release.sha256.new /etc/linux-av/power.release.sha256
fi
/bin/sh "$dst/bin/av-root" av-setup power-policy
printf '%s\n' 'root-install-power: done; activation remains a separate operator step'
