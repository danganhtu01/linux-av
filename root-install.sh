#!/bin/sh
# exempt: GNU-ONLY OVH (Ubuntu, GNU coreutils), run as root through /usr/local/sbin/ovh-root-run
# root-install.sh: install linux-av's root-owned copy on OVH from this tree, as root, through /usr/local/sbin/ovh-root-run
# (a tree step of linux-av@<commit>; C-10). OC-T-0046, R-3377: his words 2026-11-05, "Stop the antivirus scans jobs now.
# Resume it after the fix is live, which could be later." This is the fix; a separate card starts the timer.
# The runner checks this file's SHA-256 and each listed file's before it runs anything:
# sha256 9d03d30d10adb02e44325a39652079ccdc1d55fef134d8839c9a6a88a56bb3bd bin/av-scan
# sha256 1ee5629599004961efafe99e43c791ae1b0d18e50f606f3b4d17733f6a57c747 lib/common.sh
# sha256 ae1283589ae0b920d1f72dbb72d74b1668e8312d36b9b7f8ca876317dd396684 systemd/av-scan.service
# What it writes, all root:root:
#   /usr/local/lib/linux-av/bin/av-scan     0755  (the old one kept once as av-scan.before-R-3377)
#   /usr/local/lib/linux-av/lib/common.sh   0644  (the old one kept once as common.sh.before-R-3377)
#   /etc/systemd/system/linux-av-scan.service.d/limits.conf   0644  MemoryHigh/MemoryMax
#   /etc/systemd/system/linux-av-scan.service.d/30-time-limit.conf   0644  TimeoutStartSec=12h30min
#   /etc/needrestart/conf.d/linux-av.conf   0644  needrestart never restarts linux-av-* (a restart waits for a whole scan)
# What it reads and never writes (OC-T-0083):
#   /etc/systemd/system/linux-av-scan.service.d/R-3377-cpu-cap.conf   OVH's CPU cap drop-in for the scan; it must be
#   a regular file (not a link), owned by root, not group- or other-writable, with both lines set, or nothing is installed
# Then systemctl daemon-reload, and a read-back of the unit's TimeoutStartUSec, CPUQuotaPerSecUSec, CPUWeight, MemoryHigh and
# MemoryMax. It starts, stops, enables and disables nothing.
# A second run writes the same bytes and keeps the first backups.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 022
die() { echo "root-install: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "not root"
[ "$(hostname)" = OVH ] || die "this card is for OVH, not $(hostname)"
here=$(pwd)
for f in bin/av-scan lib/common.sh systemd/av-scan.service; do [ -f "$here/$f" ] && [ ! -L "$here/$f" ] || die "$f missing beside the script"; done
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
# OC-T-0083: OVH's CPU cap for linux-av-scan.service comes from R-3377-cpu-cap.conf, which this script never writes (limits.conf
# holds memory only). If that drop-in is gone or edited, the scan falls back to the base unit's CPU bounds without a word, so
# refuse before anything is rendered, kept or put: it must be a regular file and not a link, owned by root, not writable by
# group or others (the folder is already root-only), and set CPUQuota= and CPUWeight= to a value (an empty one resets it).
cap=/etc/systemd/system/linux-av-scan.service.d/R-3377-cpu-cap.conf
[ ! -L "$cap" ] || die "$cap is a link; nothing was installed"
[ -f "$cap" ] || die "$cap is missing or not a regular file; nothing was installed"
perm=$(stat -c '%u %A' "$cap")
[ "${perm%% *}" = 0 ] || die "$cap is not owned by root (uid ${perm%% *}); nothing was installed"
case ${perm#* } in ?????[!w]??[!w]?) ;; *) die "$cap is writable by group or others (${perm#* }); nothing was installed" ;; esac
grep -q '^CPUQuota=[[:space:]]*[^[:space:]]' "$cap" || die "$cap has no CPUQuota= line with a value; nothing was installed"
grep -q '^CPUWeight=[[:space:]]*[^[:space:]]' "$cap" || die "$cap has no CPUWeight= line with a value; nothing was installed"
# OC-T-0067: everything is rendered and checked in $t first, and only then is anything kept or put, so a failure
# while preparing changes nothing installed (run card 23989 replaced av-scan and common.sh, then stopped).
t=$(mktemp -d /run/linux-av-root-install.XXXXXXXX)
trap 'case $t in /run/linux-av-root-install.?*) rm -rf --one-file-system -- "$t" ;; esac' EXIT
# OC-T-0067, R-3377: render memory limits without activation. CPU values remain
# solely in OVH's R-3377-cpu-cap.conf. Pin config to an empty private file; defaults and
# explicit AV_SCAN_MEMORY_* environment overrides match the timer renderer.
# --render-scan-limits only prints the memory drop-in (render_scan_limits in bin/av-scan). It never calls
# systemctl and never starts a scan.
# Run it through bash, not as a program: ovh-root-run copies this tree without file modes, so bin/av-scan has
# no exec bit here, and /run, where ovh-root-run places the tree, is mounted noexec on OVH (run card 23989
# stopped at this line with exit 126, Permission denied). Its shebang is #!/usr/bin/env bash, so bash and not
# sh. Run the copy in $here, not the one in $dst: AV_HOME comes from the script's own path and the renderer
# reads "$AV_HOME/systemd/av-scan.service", which this script never installs.
: > "$t/av.env"
AV_CONFIG="$t/av.env" bash "$here/bin/av-scan" --render-scan-limits > "$t/limits.conf"
[ -s "$t/limits.conf" ] || die "the memory drop-in rendered empty"
printf '%s\n' '# OC-T-0046, R-3377: a scan never runs longer than this (av-scan stops clamscan at AV_SCAN_TIMEOUT, 12h)' '[Service]' 'TimeoutStartSec=12h30min' > "$t/30-time-limit.conf"
# The single quotes are meant: the line is Perl for needrestart, written as it stands.
# shellcheck disable=SC2016
printf '%s\n' '# OC-T-0046, R-3377: never restart linux-av units after an upgrade. linux-av-scan is a oneshot whole-root scan,' \
  '# so a restart waits for the whole scan: on 2026-11-04 it held unattended-upgrade and apt'"'"'s lock for 20 hours.' \
  '$nrconf{override_rc}->{qr(^linux-av-)} = 0;' > "$t/linux-av.conf"
perl -c "$t/linux-av.conf" >/dev/null 2>&1 || die "needrestart's new conf does not parse"
keep "$dst/bin/av-scan"
keep "$dst/lib/common.sh"
put "$here/lib/common.sh" 0644 "$dst/lib/common.sh"
put "$here/bin/av-scan" 0755 "$dst/bin/av-scan"
put "$t/limits.conf" 0644 /etc/systemd/system/linux-av-scan.service.d/limits.conf
put "$t/30-time-limit.conf" 0644 /etc/systemd/system/linux-av-scan.service.d/30-time-limit.conf
put "$t/linux-av.conf" 0644 /etc/needrestart/conf.d/linux-av.conf
systemctl daemon-reload
echo "read back:"
sha256sum "$dst/bin/av-scan" "$dst/lib/common.sh" /etc/systemd/system/linux-av-scan.service.d/limits.conf
echo "TimeoutStartUSec=$(systemctl show linux-av-scan.service -p TimeoutStartUSec --value)"
# OC-T-0083: the effective bounds as systemd now holds them (CPU from R-3377-cpu-cap.conf, memory from limits.conf), one Name=value per line.
systemctl show linux-av-scan.service -p CPUQuotaPerSecUSec -p CPUWeight -p MemoryHigh -p MemoryMax
echo "timer: $(systemctl is-active linux-av-scan.timer 2>/dev/null) (this card leaves it as it was)"
echo "root-install: done"
