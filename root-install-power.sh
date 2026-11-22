#!/bin/sh
# OC-T-0139: run ONLY a separately SHA-256 verified, root-private copy of this
# installer, with env -i, from a verified release tree (see README Surface).
# Unlike OVH's separate installers this supports Arch/Debian/Ubuntu. No package
# transaction, scan, baseline, or unit activation. Existing OVH installers and
# their hostname/CPU-cap safeguards remain separate and unchanged.
# The release runner pins this script externally. These pins cover ALL inputs
# copied/loaded by it; a private snapshot is checked before any input executes.
# sha256 44835afa77069f9bb88ecf18715c57f87ed9e8c020e2b5eafee1acea0c82ddbb bin/av-guard
# sha256 5b2ebf4ec09cfd53b7e7fe19ec77d7f5cea5f1d68155163c6e283360ef7847d8 bin/av-root
# sha256 41b6ec0e3f6382bf37136e9b9b2f9408cb04251c39cb8e341aeee7be6e2adff4 bin/av-power
# sha256 63d881cc652f56f0f8a2cbde92f526d613b8ddd9a6bb7937dff1311563f27fbd bin/av-scan
# sha256 102290fb3004dbd3ec4c888d9a4cc89bc07f3ce76362ff49f8c5c763109db3ef bin/av-setup
# sha256 f1591638d4096e18fb6e43ab8bb3bd2ea1e8c888f2576ff6f94195228ba0cee5 lib/common.sh
# sha256 a35b9f810543a712f838525deefa997515a140dcf4b97fae4923dfa1b1f0bf60 lib/reports.sh
# sha256 112756bc23b4f963f9339135366992b1aa3f51f4b3cbd6c049d3a5f4e64bb02f lib/root-policy.sh
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
sound /etc/linux-av/power.units
quiescent() {
    state=$(systemctl show "$1" -p ActiveState --value) || [ "$state" = inactive ] || fail "cannot inspect $1"
    case $state in inactive|failed) ;; *) fail "$1 is $state; quiesce in a separately authorized maintenance step" ;; esac
}
for unit in linux-av-power.service linux-av-scan.service linux-av-rootkit.service \
    linux-av-scan.timer linux-av-rootkit.timer clamav-daemon.service clamav-daemon.socket \
    clamav-clamonacc.service chkrootkit.service rkhunter.service aidecheck.service dailyaidecheck.service \
    linux-av-aide-init.service cron.service crond.service chkrootkit.timer rkhunter.timer aidecheck.timer dailyaidecheck.timer; do
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
while read -r hash rel; do
    if [ -f "$dst/$rel" ] && ! cmp -s "$t/$rel" "$dst/$rel" && [ ! -e "$dst/$rel.before-OC-T-0139" ]; then
        cp -p -- "$dst/$rel" "$dst/$rel.before-OC-T-0139" || fail "backup failed: $rel"
    fi
done < "$t/pins"
install -d -o root -g root -m 0755 "$dst" "$dst/bin" "$dst/lib" "$dst/systemd"
while read -r hash rel; do
    case $rel in bin/*) mode=0755 ;; *) mode=0644 ;; esac
    if [ -f "$dst/$rel" ] && cmp -s "$t/$rel" "$dst/$rel" && [ "$(stat -c '%u %g %a' "$dst/$rel")" = "0 0 ${mode#0}" ]; then continue; fi
    rm -f -- "$dst/$rel.new"
    install -o root -g root -m "$mode" "$t/$rel" "$dst/$rel.new"
    mv -f -- "$dst/$rel.new" "$dst/$rel"
done < "$t/pins"
/bin/sh "$dst/bin/av-root" av-setup power-policy
printf '%s\n' 'root-install-power: done; activation remains a separate operator step'
