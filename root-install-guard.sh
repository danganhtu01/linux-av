#!/bin/sh
# exempt: GNU-ONLY OVH (Ubuntu, GNU coreutils), run as root through /usr/local/sbin/ovh-root-run
# root-install-guard.sh: make OVH's two root units (linux-av-scan.service, linux-av-rootkit.service) run and source only files that
# only root can change, as root, through /usr/local/sbin/ovh-root-run (a tree step of linux-av@<commit>; C-10). OC-T-0037.
# Gap 1: the base unit files still say ExecStart=/usr/local/bin/av-scan, a link into a checkout a user can write; only the drop-in
# root-owned.conf pointed them at the root-owned copy, so losing it fell back to the user's file. Gap 2: nothing checked ownership
# at start. This closes both: it installs bin/av-guard, which each unit runs as ExecStartPre= and which refuses to start the unit
# unless every file the unit runs or sources, and every folder above it, is root-owned and not writable by anyone else.
# The runner checks this file's SHA-256 and the listed file's before it runs anything, and this script checks the same line itself
# before it reads or writes anything else (defence in depth). The line below is the only one that may start with the hash word:
# sha256 20a73f712d58be113db050b53281c9124d22a8bf9f7d895818f644e3f24286b9 bin/av-guard
# What it writes, all root:root (both backups are made before anything else is written; a second run writes the same bytes and
# keeps the first backups):
#   /usr/local/lib/linux-av/bin/av-guard                                   0755
#   /etc/systemd/system/linux-av-scan.service.d/05-guard.conf              0644  ExecStartPre=/usr/local/lib/linux-av/bin/av-guard
#   /etc/systemd/system/linux-av-rootkit.service.d/05-guard.conf           0644  the same
#   /etc/systemd/system/linux-av-scan.service                              0644  only its ExecStart line changes
#   /etc/systemd/system/linux-av-rootkit.service                           0644  only its ExecStart line changes
#   <unit file>.before-OC-T-0037  the old unit file, kept once
# The ExecStart line changes from /usr/local/bin/av-scan to /usr/local/lib/linux-av/bin/av-scan (same arguments). root-owned.conf
# stays as it is, and so does the /usr/local/bin/av-scan link. It reads each live unit file (their other lines are OVH's own).
# It refuses, having written nothing, unless the folders it writes into and the unit files it rewrites are not links, are owned
# by root and are not writable by group or others, and every file it will write is absent or a regular file, and each unit's
# ExecStart line is the old one or the new one. Then systemctl daemon-reload; a read-back of ExecStartPre and ExecStart of both
# units, refused unless systemd holds exactly the guard (errors not ignored) and av-scan with its argument; and one run of the
# installed guard, so the card shows at once whether this host passes it. It starts, stops, enables, disables and restarts nothing.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 022
base=
die() { echo "root-install-guard: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "not root"
[ "$(hostname)" = OVH ] || die "this card is for OVH, not $(hostname)"
here=$(pwd)
# The pin: this file's header holds exactly one line the runner takes for a pin, and it names bin/av-guard. The file it names
# must match before anything else is read from the tree or written.
[ -f "$0" ] && [ ! -L "$0" ] || die "cannot read my own header from $0; nothing was installed"
pins=$(grep -a -E '^[[:space:]]*#[[:space:]]*sha256' "$0" || true)
printf '%s\n' "$pins" | grep -Eqx '# sha256 [0-9a-f]{64} bin/av-guard' || die "my header has no pin line for bin/av-guard; nothing was installed"
[ "$(printf '%s\n' "$pins" | grep -c '')" = 1 ] || die "my header has more than one pin line; nothing was installed"
pin=$(printf '%s\n' "$pins" | cut -d' ' -f3)
[ -f "$here/bin/av-guard" ] && [ ! -L "$here/bin/av-guard" ] || die "bin/av-guard missing beside the script; nothing was installed"
[ "$(sha256sum < "$here/bin/av-guard" | cut -c1-64)" = "$pin" ] || die "bin/av-guard: SHA-256 differs from the pin in my header; nothing was installed"
lib=/usr/local/lib/linux-av
dst=$base$lib
units=$base/etc/systemd/system
# sound KIND PATH: PATH is a folder or a file (KIND), not a link, owned by root and not writable by group or others, or nothing is installed.
sound() {
    [ ! -L "$2" ] || die "$2 is a link; nothing was installed"
    case $1 in folder) [ -d "$2" ] ;; *) [ -f "$2" ] ;; esac || die "$2 is missing or is not a $1; nothing was installed"
    s=$(stat -c '%u %A' "$2")
    [ "${s%% *}" = 0 ] || die "$2 is not owned by root (uid ${s%% *}); nothing was installed"
    case ${s#* } in ?????[!w]??[!w]?) ;; *) die "$2 is writable by group or others (${s#* }); nothing was installed" ;; esac
}
for d in "$base/usr/local/lib" "$dst" "$dst/bin" "$units" "$units/linux-av-scan.service.d" "$units/linux-av-rootkit.service.d"; do
    sound folder "$d"
done
for u in linux-av-scan.service linux-av-rootkit.service; do
    sound file "$units/$u"
done
for f in "$dst/bin/av-guard" "$units/linux-av-scan.service.d/05-guard.conf" "$units/linux-av-rootkit.service.d/05-guard.conf" \
    "$units/linux-av-scan.service.before-OC-T-0037" "$units/linux-av-rootkit.service.before-OC-T-0037"; do
    [ ! -L "$f" ] || die "$f is a link; nothing was installed"
    [ ! -e "$f" ] || [ -f "$f" ] || die "$f is not a regular file; nothing was installed"
done
# The units and the drop-in are rendered and checked in $t first, and only then is anything kept or put.
t=$(mktemp -d "$base/run/linux-av-root-install-guard.XXXXXXXX")
trap 'case $t in */run/linux-av-root-install-guard.?*) rm -rf --one-file-system -- "$t" ;; esac' EXIT
# render UNIT ARG: UNIT as it is now, with its one ExecStart= line pointing at the root-owned copy. Only that line may change.
render() {
    old="ExecStart=/usr/local/bin/av-scan $2"
    new="ExecStart=$lib/bin/av-scan $2"
    [ "$(grep -c '^ExecStart=' "$units/$1" || true)" = 1 ] || die "$units/$1 does not hold exactly one ExecStart= line; nothing was installed"
    grep -qxF -e "$old" -e "$new" "$units/$1" || die "$units/$1: its ExecStart= line is neither '$old' nor '$new'; nothing was installed"
    sed "s|^$old\$|$new|" "$units/$1" > "$t/$1"
}
render linux-av-scan.service --now
render linux-av-rootkit.service --rootkit
printf '%s\n' '# OC-T-0037: the unit starts only if av-guard finds every file it runs or sources root-owned and not writable by others.' \
    '[Service]' "ExecStartPre=$lib/bin/av-guard" > "$t/05-guard.conf"
# put SRC MODE DEST: write DEST.new beside DEST, then rename over it (no link followed: the folders are root-only)
put() {
    if [ -f "$3" ] && cmp -s "$1" "$3" && [ "$(stat -c '%u %g %a' "$3")" = "0 0 ${2#0}" ]; then echo "unchanged: $3"; return 0; fi
    rm -f -- "$3.new"
    install -o root -g root -m "$2" "$1" "$3.new"
    mv -f -- "$3.new" "$3"
    echo "written: $3 ($(sha256sum < "$3" | cut -c1-64))"
}
# keep FILE: FILE's first copy, once (the units were checked above to be regular files, not links)
keep() {
    [ -e "$1.before-OC-T-0037" ] && return 0
    cp -p -- "$1" "$1.before-OC-T-0037" || die "could not keep $1.before-OC-T-0037"
    echo "kept: $1.before-OC-T-0037"
}
# Both backups come first, so a backup that cannot be made leaves nothing written.
for u in linux-av-scan.service linux-av-rootkit.service; do
    cmp -s "$t/$u" "$units/$u" || keep "$units/$u"
done
put "$here/bin/av-guard" 0755 "$dst/bin/av-guard"
put "$t/05-guard.conf" 0644 "$units/linux-av-scan.service.d/05-guard.conf"
put "$t/05-guard.conf" 0644 "$units/linux-av-rootkit.service.d/05-guard.conf"
for u in linux-av-scan.service linux-av-rootkit.service; do
    put "$t/$u" 0644 "$units/$u"
done
systemctl daemon-reload
# exec_fields NAME: each NAME={ ... } line of systemctl show as "NAME path | argv | ignore_errors", so one line is what was meant.
exec_fields() { sed -n "s/^$1={ path=\(.*\) ; argv\[\]=\(.*\) ; ignore_errors=\([a-z]*\) ; .*/$1 \1 | \2 | \3/p"; }
echo "read back:"
for pair in "linux-av-scan.service --now" "linux-av-rootkit.service --rootkit"; do
    u=${pair%% *}
    a=${pair#* }
    shown=$(systemctl show "$u" -p ExecStartPre -p ExecStart) || die "systemctl show $u failed"
    got_pre=$(printf '%s\n' "$shown" | exec_fields ExecStartPre)
    got_run=$(printf '%s\n' "$shown" | exec_fields ExecStart)
    echo "$u: $got_pre"
    echo "$u: $got_run"
    [ "$got_pre" = "ExecStartPre $lib/bin/av-guard | $lib/bin/av-guard | no" ] || die "systemd holds the wrong ExecStartPre for $u (wanted the guard, errors not ignored)"
    [ "$got_run" = "ExecStart $lib/bin/av-scan | $lib/bin/av-scan $a | no" ] || die "systemd holds the wrong ExecStart for $u (wanted $lib/bin/av-scan $a)"
done
sha256sum "$dst/bin/av-guard"
"$dst/bin/av-guard" || die "av-guard refuses on this host (its line is above); the units now run it, so the next scan would not start"
echo "root-install-guard: done"
