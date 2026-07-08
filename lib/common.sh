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
for _cfg in \
    "${AV_CONFIG:-}" \
    "$XDG_CONFIG_HOME/linux-av/av.env" \
    "/etc/linux-av/av.env" \
    "$AV_HOME/config/av.env"
do
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
: "${AV_ENGINE:=auto}"                                        # auto | clamdscan | clamscan
: "${AV_LOG_DIR:=$XDG_STATE_HOME/linux-av}"
: "${AV_QUARANTINE:=$AV_LOG_DIR/quarantine}"
: "${AV_LOG_FILE:=$AV_LOG_DIR/av-scan.log}"
: "${AV_TIMER_NAME:=linux-av-scan}"                           # scan-timer unit basename
: "${AV_ROOTKIT_TIMER_NAME:=linux-av-rootkit}"                # rootkit-timer unit basename
: "${AV_TIMER_BOOT_DELAY:=1min}"                              # OnBootSec for installed timers
: "${AV_COLOR:=auto}"                                         # auto | always | never
export AV_SCAN_PATHS AV_EXCLUDE_DIRS AV_ENGINE AV_LOG_DIR AV_QUARANTINE \
       AV_LOG_FILE AV_TIMER_NAME AV_ROOTKIT_TIMER_NAME AV_TIMER_BOOT_DELAY AV_COLOR

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
    if [ -n "${AV_LOG_FILE:-}" ]; then
        mkdir -p "$(dirname "$AV_LOG_FILE")" 2>/dev/null || true
        printf '%s %-5s %s\n' "$ts" "$lvl" "$*" >>"$AV_LOG_FILE" 2>/dev/null || true
    fi
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

# Re-exec self through sudo when not already root (used by av-setup).
reexec_root() {
    [ "$(id -u)" -eq 0 ] && return 0
    have sudo || die "not root and sudo not found"
    log_warn "escalating with sudo ..."
    exec sudo -E "$0" "$@"
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
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        AV_DISTRO_ID="${ID:-unknown}"; like="${ID_LIKE:-}"
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
