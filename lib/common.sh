#!/usr/bin/env bash
# lib/common.sh — shared helpers for the linux-av toolkit.
#
# Sourced by bin/av-scan and bin/av-setup. Everything here is written to work
# identically on Arch, Debian and Ubuntu; where the distros differ we detect the
# family once (av_detect_distro) and branch on $AV_FAMILY.
#
# Nothing here hard-codes an absolute path to the repo: callers resolve their own
# location and export AV_HOME, and every tunable is an env var with a sane
# default so the same checkout works for any user on any box.

# Guard against being sourced twice.
[ -n "${_AV_COMMON_SH:-}" ] && return 0
_AV_COMMON_SH=1

# systemd services and cron run with a minimal environment — often no $HOME or
# $USER. Scripts here use `set -u`, so derive sane values up front, otherwise the
# first reference (e.g. $HOME below) aborts with "HOME: unbound variable".
: "${HOME:=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)}"
: "${HOME:=/root}"
: "${USER:=$(id -un 2>/dev/null || echo root)}"
export HOME USER

# ---------------------------------------------------------------------------
# 0. Resolve AV_HOME (repo root) if the caller did not already.
#    We follow symlinks so `av-scan` works when installed as a symlink in PATH.
# ---------------------------------------------------------------------------
if [ -z "${AV_HOME:-}" ]; then
    _src="${BASH_SOURCE[0]}"
    while [ -L "$_src" ]; do
        _dir="$(cd -P "$(dirname "$_src")" && pwd)"
        _src="$(readlink "$_src")"
        [ "${_src#/}" = "$_src" ] && _src="$_dir/$_src"
    done
    AV_HOME="$(cd -P "$(dirname "$_src")/.." && pwd)"
fi
export AV_HOME

# ---------------------------------------------------------------------------
# 1. Load user config (optional). First match wins.
#    Override with AV_CONFIG=/path/to/av.env.
# ---------------------------------------------------------------------------
: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"
if [ "${EUID:-$(id -u)}" = 0 ]; then
    _av_configs=(/etc/linux-av/av.env)
else
    _av_configs=(
    "${AV_CONFIG:-}" \
    "$XDG_CONFIG_HOME/linux-av/av.env" \
    "/etc/linux-av/av.env" \
    "$AV_HOME/config/av.env"
    )
fi
for _cfg in "${_av_configs[@]}"; do
    if [ -n "$_cfg" ] && [ -f "$_cfg" ]; then
        # shellcheck disable=SC1090
        . "$_cfg"
        AV_CONFIG_LOADED="$_cfg"
        break
    fi
done

# ---------------------------------------------------------------------------
# 2. Tunables — every one overridable via env or the config file above.
# ---------------------------------------------------------------------------
: "${AV_SCAN_PATHS:=$HOME}"                                   # space-separated list
: "${AV_EXCLUDE_DIRS:=/proc /sys /dev /run /var/lib/clamav}"  # never descend into these
: "${AV_EXCLUDE_PATTERNS=node_modules target .cache __pycache__ .venv .tox .gradle .claude/worktrees}"
: "${AV_EXCLUDE_FSTYPES=autofs cifs smb3 smbfs nfs nfs4 9p ceph glusterfs afs fuse fuse.*}"
: "${AV_MOUNTINFO:=/proc/self/mountinfo}"                     # read without probing mounts
: "${AV_SCAN_TIMEOUT:=12h}"                                  # 0 disables the scan time limit
: "${AV_POWER_SUPPLY_DIR:=/sys/class/power_supply}"             # synthetic sysfs in tests
: "${AV_POWER_POLL_INTERVAL:=1}"                              # seconds between runtime power checks
: "${AV_FULL_EVERY:=7d}"                                     # full-scan interval (seconds or d/h/m)
: "${AV_SCAN_MEMORY_HIGH=2G}"                                # empty omits the unit directive
: "${AV_SCAN_MEMORY_MAX=3G}"
: "${AV_ENGINE:=auto}"                                        # auto | clamdscan | clamscan
: "${AV_LOG_DIR:=$XDG_STATE_HOME/linux-av}"
: "${AV_QUARANTINE:=$AV_LOG_DIR/quarantine}"
: "${AV_LOG_FILE:=$AV_LOG_DIR/av-scan.log}"
: "${AV_TIMER_NAME:=linux-av-scan}"                           # scan-timer unit basename
: "${AV_ROOTKIT_TIMER_NAME:=linux-av-rootkit}"                # rootkit-timer unit basename
: "${AV_TIMER_BOOT_DELAY:=1min}"                              # OnBootSec for scan/rootkit timers
: "${AV_AIDE_BOOT_DELAY:=15min}"                              # OnBootSec drop-in for the AIDE check
: "${AV_COLOR:=auto}"                                         # auto | always | never
: "${AV_ROOT=}"                                                # tests only; preserve the root launcher's readonly empty value
: "${AV_QUIET_REPORTS:=1}"                                     # 0 = leave chkrootkit/AIDE/rkhunter mail settings alone
: "${AV_RKHUNTER_DAILY:=1}"                                    # 0 = leave rkhunter's daily run and weekly update off/as is
: "${AV_AIDE_INIT_UNIT:=linux-av-aide-init}"                   # systemd unit that builds the AIDE baseline
: "${AV_AIDE_INIT_TIMEOUT:=4h}"                                # RuntimeMaxSec of that unit
export AV_SCAN_PATHS AV_EXCLUDE_DIRS AV_ENGINE AV_LOG_DIR AV_QUARANTINE \
       AV_LOG_FILE AV_TIMER_NAME AV_ROOTKIT_TIMER_NAME AV_TIMER_BOOT_DELAY \
       AV_AIDE_BOOT_DELAY AV_COLOR AV_ROOT AV_QUIET_REPORTS AV_RKHUNTER_DAILY \
       AV_AIDE_INIT_UNIT AV_AIDE_INIT_TIMEOUT AV_EXCLUDE_FSTYPES AV_MOUNTINFO AV_SCAN_TIMEOUT \
       AV_EXCLUDE_PATTERNS AV_FULL_EVERY AV_SCAN_MEMORY_HIGH AV_SCAN_MEMORY_MAX
export AV_POWER_SUPPLY_DIR AV_POWER_POLL_INTERVAL

# ---------------------------------------------------------------------------
# 3. Logging (colored to stderr, plain to $AV_LOG_FILE).
# ---------------------------------------------------------------------------
_av_use_color() {
    case "$AV_COLOR" in
        always) return 0 ;;
        never)  return 1 ;;
        *)      [ -t 2 ] ;;
    esac
}
if _av_use_color; then
    _C_RED=$'\033[31m'; _C_YEL=$'\033[33m'; _C_GRN=$'\033[32m'
    _C_DIM=$'\033[2m';  _C_RST=$'\033[0m'
else
    _C_RED=; _C_YEL=; _C_GRN=; _C_DIM=; _C_RST=
fi

_av_log() { # level color message...
    local lvl="$1" col="$2"; shift 2
    local ts; ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '%s%s %-5s%s %s\n' "$col" "$ts" "$lvl" "$_C_RST" "$*" >&2
    AV_REPORT_WRITTEN=0
    if [ -n "${AV_LOG_FILE:-}" ]; then
        mkdir -p "$(dirname "$AV_LOG_FILE")" 2>/dev/null || true
        if printf '%s %-5s %s\n' "$ts" "$lvl" "$*" 2>/dev/null >>"$AV_LOG_FILE"; then
            AV_REPORT_WRITTEN=1
        fi
    fi
    return 0
}
log_info() { _av_log INFO "$_C_GRN" "$@"; }
log_warn() { _av_log WARN "$_C_YEL" "$@"; }
log_err()  { _av_log ERROR "$_C_RED" "$@"; }
die()      { log_err "$@"; exit 1; }

# ---------------------------------------------------------------------------
# 4. Small helpers.
# ---------------------------------------------------------------------------
have()      { command -v "$1" >/dev/null 2>&1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "must run as root (try: sudo $0 $*)"; }
# AV_ROOT is a path prefix for the test suite only. A root run with it set would
# edit files under the prefix while systemctl, aideinit and rkhunter --propupd act
# on the real system, so it is refused as root. The permanent launcher also
# clears this test-only selector before starting a root command.
av_refuse_root_prefix() { # euid
    [ -n "${AV_ROOT:-}" ] || return 0
    [ "$1" -eq 0 ] || return 0
    die "AV_ROOT=$AV_ROOT is for tests only; unset it (it is refused when running as root)"
}
av_refuse_root_prefix "${EUID:-$(id -u)}"

# OC-T-0139 / R-4089. Only system batteries count (not a mouse/UPS marked
# scope=Device). An empty power_supply class is normal on a mains-only server.
# With a battery, require positive external power and reject discharging even
# when a stale adapter says online. Names (AC, ACAD, ADP1, BAT0...) are immaterial.
av_on_mains() {
    local supply type scope present status online battery=0 external=0 uncertain=0
    local root="${AV_POWER_SUPPLY_DIR:-/sys/class/power_supply}"
    [ -d "$root" ] && [ -r "$root" ] && [ -x "$root" ] || return 1
    for supply in "$root"/*; do
        [ -e "$supply" ] || continue
        scope=; read -r scope 2>/dev/null < "$supply/scope" || true
        [ "$scope" != Device ] || continue
        type=; read -r type 2>/dev/null < "$supply/type" || true
        case "$type" in
            Battery|UPS)
                present=; read -r present 2>/dev/null < "$supply/present" || true
                [ "$present" != 0 ] || continue
                battery=1
                if [ "$type" = UPS ]; then
                    online=; read -r online 2>/dev/null < "$supply/online" || true
                    [ "$online" != 1 ] || external=1
                fi
                status=; read -r status 2>/dev/null < "$supply/status" || true
                case "$status" in
                    Discharging) return 1 ;;
                    Charging|Full|'Not charging') ;;
                    *) uncertain=1 ;;
                esac ;;
            Mains|USB|USB_*|USB-*|Wireless|BrickID)
                online=; read -r online 2>/dev/null < "$supply/online" || true
                [ "$online" != 1 ] || external=1 ;;
            *) uncertain=1 ;;
        esac
    done
    if [ "$battery" = 0 ]; then [ "$uncertain" = 0 ]; else
        [ "$external" = 1 ] && [ "$uncertain" = 0 ]
    fi
}

# Freeze before descending so a scanner/timeout/worker cannot fork out of the
# snapshot. /proc follows descendants even when GNU timeout creates a new group.
# KILL is deliberate: a TERM-resistant scanner must not continue on battery.
av_power_stop_tree() {
    local pid="$1" child task children=""
    kill -STOP "$pid" 2>/dev/null || return 0
    for task in /proc/"$pid"/task/*/children; do
        read -r children 2>/dev/null < "$task" || true
        for child in $children; do av_power_stop_tree "$child"; done
    done
    kill -KILL "$pid" 2>/dev/null || true
}

# Run a shell function or command with a separate supervisor. No dependency on
# systemd for foreground jobs. Return 75 for deferred/cancelled work, never clean.
av_power_run() (
    av_on_mains || { log_warn "scan deferred: mains power is not confirmed"; return 75; }
    local state worker="" watcher="" rc=0
    state="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/av-power.XXXXXX")" || return 2
    trap '[ -z "$watcher" ] || av_power_stop_tree "$watcher"; [ -z "$worker" ] || av_power_stop_tree "$worker"; rm -rf -- "$state"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    ( av_on_mains || exit 75; "$@" ) & worker=$!
    (
        while kill -0 "$worker" 2>/dev/null; do
            if ! av_on_mains; then
                : > "$state/cancelled"
                av_power_stop_tree "$worker"
                exit
            fi
            /bin/sleep "${AV_POWER_POLL_INTERVAL:-1}"
        done
    ) & watcher=$!
    wait "$worker"; rc=$?
    # Reap the monitor as well, so no pending poll keeps a pipe/terminal alive.
    av_power_stop_tree "$watcher"; wait "$watcher" 2>/dev/null || true; watcher=""
    worker=""
    if [ -e "$state/cancelled" ]; then
        log_warn "scan cancelled: mains power lost; completion stamps unchanged"
        return 75
    fi
    return "$rc"
)

av_power_wait() {
    until av_on_mains; do /bin/sleep "${AV_POWER_POLL_INTERVAL:-1}"; done
}

# ---------------------------------------------------------------------------
# 5. Distro detection.  Sets:
#      AV_DISTRO_ID     e.g. arch | debian | ubuntu
#      AV_FAMILY        arch | debian     (the only branch we ever switch on)
#      AV_PKG_MGR       pacman | apt
#      av_pkg_install   function that installs packages for this box
# ---------------------------------------------------------------------------
av_detect_distro() {
    AV_DISTRO_ID="unknown"; local like=""
    if [ -r "${AV_ROOT:-}/etc/os-release" ]; then
        AV_DISTRO_ID=$(sed -n -E "s/^ID=[\"']?([a-zA-Z0-9_-]+)[\"']?$/\\1/p" "${AV_ROOT:-}/etc/os-release")
        like=$(sed -n -E "s/^ID_LIKE=[\"']?([a-zA-Z0-9_ -]+)[\"']?$/\\1/p" "${AV_ROOT:-}/etc/os-release")
    fi
    case "$AV_DISTRO_ID $like" in
        *arch*)            AV_FAMILY="arch";   AV_PKG_MGR="pacman" ;;
        *debian*|*ubuntu*) AV_FAMILY="debian"; AV_PKG_MGR="apt"    ;;
        *) # last-ditch guess by which package manager exists
           if have pacman; then AV_FAMILY="arch"; AV_PKG_MGR="pacman"
           elif have apt-get; then AV_FAMILY="debian"; AV_PKG_MGR="apt"
           else AV_FAMILY="unknown"; AV_PKG_MGR="unknown"; fi ;;
    esac
    export AV_DISTRO_ID AV_FAMILY AV_PKG_MGR
}

# Distro-agnostic package install.
av_pkg_install() {
    case "$AV_PKG_MGR" in
        pacman) pacman -S --needed --noconfirm "$@" ;;
        apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        *)      die "unsupported package manager on $AV_DISTRO_ID" ;;
    esac
}

# Map a logical component to the package name(s) on this distro.
# Usage: av_pkg_names clamav | rkhunter | chkrootkit | aide | audit
av_pkg_names() {
    case "$1" in
        clamav)     case "$AV_FAMILY" in
                        arch)   echo "clamav" ;;
                        debian) echo "clamav clamav-daemon clamav-freshclam" ;;
                    esac ;;
        aide)       case "$AV_FAMILY" in
                        arch)   echo "aide" ;;
                        debian) echo "aide aide-common" ;;
                    esac ;;
        audit)      case "$AV_FAMILY" in
                        arch)   echo "audit" ;;
                        debian) echo "auditd" ;;
                    esac ;;
        rkhunter)   echo "rkhunter" ;;
        chkrootkit) echo "chkrootkit" ;;   # NB: AUR on Arch — see README
        *)          echo "$1" ;;
    esac
}

# Locate the clamd control socket (differs by build/config; overridable).
av_clamd_socket() {
    if [ -n "${AV_CLAMD_SOCKET:-}" ]; then echo "$AV_CLAMD_SOCKET"; return; fi
    local s
    for s in /run/clamav/clamd.ctl /run/clamav/clamd.sock \
             /var/run/clamav/clamd.ctl /run/clamav/clamd.socket; do
        [ -S "$s" ] && { echo "$s"; return; }
    done
    echo ""   # none found -> caller falls back to standalone clamscan
}
