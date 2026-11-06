#!/bin/sh
# exempt: GNU-ONLY OVH (Ubuntu, GNU coreutils), run as root through /usr/local/sbin/ovh-root-run
# root-install.sh: install linux-av's root-owned copy on OVH from this tree, as root, through /usr/local/sbin/ovh-root-run
# (a tree step of linux-av@<commit>; C-10). OC-T-0046, R-3377: his words 2026-11-05, "Stop the antivirus scans jobs now.
# Resume it after the fix is live, which could be later." This is the fix; a separate card starts the timer.
# The runner checks this file's SHA-256 and each listed file's before it runs anything:
# sha256 ddada5600bebface1d99887844c10b7eecfebb4a0b0f7364382f02fc38672511 bin/av-scan
# sha256 42dc28761f42c91e28253a01f2379d9ef7104365e089326512d21be62768918a lib/common.sh
# What it writes, all root:root:
#   /usr/local/lib/linux-av/bin/av-scan     0755  (the old one kept once as av-scan.before-R-3377)
#   /usr/local/lib/linux-av/lib/common.sh   0644  (the old one kept once as common.sh.before-R-3377)
#   /etc/systemd/system/linux-av-scan.service.d/30-time-limit.conf   0644  TimeoutStartSec=12h30min
#   /etc/needrestart/conf.d/linux-av.conf   0644  needrestart never restarts linux-av-* (a restart waits for a whole scan)
# Then systemctl daemon-reload. It starts, stops, enables and disables nothing.
# A second run writes the same bytes and keeps the first backups.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 022
die() { echo "root-install: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "not root"
[ "$(hostname)" = OVH ] || die "this card is for OVH, not $(hostname)"
here=$(pwd)
for f in bin/av-scan lib/common.sh; do [ -f "$here/$f" ] && [ ! -L "$here/$f" ] || die "$f missing beside the script"; done
dst=/usr/local/lib/linux-av
for d in /usr/local/lib "$dst" "$dst/bin" "$dst/lib" /etc/systemd/system/linux-av-scan.service.d /etc/needrestart/conf.d; do
  [ -d "$d" ] && [ ! -L "$d" ] || die "$d is not a folder (or is a link)"
  [ "$(stat -c '%u %A' "$d")" = "0 drwxr-xr-x" ] || die "$d is not root-owned 0755: $(stat -c '%U:%G %A' "$d")"
done
# put SRC MODE DEST: write DEST.new beside DEST, then rename over it (no link followed: the folders are root-only)
put() {
  [ ! -L "$3" ] || die "$3 is a link"
  if [ -f "$3" ] && cmp -s "$1" "$3" && [ "$(stat -c '%u %g %a' "$3")" = "0 0 ${2#0}" ]; then echo "unchanged: $3"; return 0; fi
  rm -f -- "$3.new"
  install -o root -g root -m "$2" "$1" "$3.new"
  mv -f -- "$3.new" "$3"
  echo "written: $3 ($(sha256sum < "$3" | cut -c1-64))"
}
keep() {
  [ -e "$1.before-R-3377" ] && return 0
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  cp -p -- "$1" "$1.before-R-3377" || die "could not keep $1.before-R-3377"
  echo "kept: $1.before-R-3377"
}
keep "$dst/bin/av-scan"
keep "$dst/lib/common.sh"
put "$here/lib/common.sh" 0644 "$dst/lib/common.sh"
put "$here/bin/av-scan" 0755 "$dst/bin/av-scan"
t=$(mktemp -d /run/linux-av-root-install.XXXXXXXX)
trap 'case $t in /run/linux-av-root-install.?*) rm -rf --one-file-system -- "$t" ;; esac' EXIT
printf '%s\n' '# OC-T-0046, R-3377: a scan never runs longer than this (av-scan stops clamscan at AV_SCAN_TIMEOUT, 12h)' '[Service]' 'TimeoutStartSec=12h30min' > "$t/30-time-limit.conf"
put "$t/30-time-limit.conf" 0644 /etc/systemd/system/linux-av-scan.service.d/30-time-limit.conf
# The single quotes are meant: the line is Perl for needrestart, written as it stands.
# shellcheck disable=SC2016
printf '%s\n' '# OC-T-0046, R-3377: never restart linux-av units after an upgrade. linux-av-scan is a oneshot whole-root scan,' \
  '# so a restart waits for the whole scan: on 2026-11-04 it held unattended-upgrade and apt'"'"'s lock for 20 hours.' \
  '$nrconf{override_rc}->{qr(^linux-av-)} = 0;' > "$t/linux-av.conf"
perl -c "$t/linux-av.conf" >/dev/null 2>&1 || die "needrestart's new conf does not parse"
put "$t/linux-av.conf" 0644 /etc/needrestart/conf.d/linux-av.conf
systemctl daemon-reload
echo "read back:"
sha256sum "$dst/bin/av-scan" "$dst/lib/common.sh"
echo "TimeoutStartUSec=$(systemctl show linux-av-scan.service -p TimeoutStartUSec --value)"
echo "timer: $(systemctl is-active linux-av-scan.timer 2>/dev/null) (this card leaves it as it was)"
echo "root-install: done"
