#!/usr/bin/env bash
# bootstrap.sh — one-shot rollout for a single box: (clone →) install tools →
#                install+enable the AV stack → optionally install a scan timer.
#
# Run this ON EACH BOX (Arch / Debian / Ubuntu). It is idempotent.
#
#   # from inside a checkout you already have:
#   ./bootstrap.sh
#
#   # from scratch on a fresh box (clones first):
#   REPO_URL=https://github.com/atdang/linux-av.git ./bootstrap.sh
#   ./bootstrap.sh --repo git@github.com:atdang/linux-av.git
#
# Useful flags:
#   --repo <url>     git remote to clone from (or set REPO_URL)
#   --dir  <path>    where to clone/expect the checkout   (default: ~/linux-av)
#   --system         install the commands to /usr/local/bin for all users (root)
#   --timer <ms>     also install a persistent systemd scan timer, every <ms>
#   --full           scan the WHOLE box (/), all users + mounts, not just $HOME
#                    (writes /etc/linux-av/av.env and targets the timer at /)
#
# Example — every box, daily whole-system scan:
#   sudo REPO_URL=<url> ./bootstrap.sh --system --full --timer 86400000
set -euo pipefail

REPO_URL="${REPO_URL:-}"
TARGET_DIR="${TARGET_DIR:-$HOME/linux-av}"
SYSTEM=0; TIMER_MS=""; SCAN_ALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)   REPO_URL="$2"; shift ;;
        --dir)    TARGET_DIR="$2"; shift ;;
        --system) SYSTEM=1 ;;
        --timer)  TIMER_MS="$2"; shift ;;
        --full)   SCAN_ALL=1 ;;
        -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next}{exit}' "$0"; exit 0 ;;
        *) echo "unknown arg: $1 (try --help)" >&2; exit 1 ;;
    esac; shift
done

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. Locate or fetch the checkout ---------------------------------------
SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SELF_DIR/bin/av-scan" ]; then
    REPO="$SELF_DIR"; say "using checkout at $REPO"
elif [ -f "$TARGET_DIR/bin/av-scan" ]; then
    REPO="$TARGET_DIR"; say "updating existing checkout at $REPO"
    git -C "$REPO" pull --ff-only 2>/dev/null || true
elif [ -n "$REPO_URL" ]; then
    command -v git >/dev/null || die "git not installed"
    say "cloning $REPO_URL -> $TARGET_DIR"
    git clone "$REPO_URL" "$TARGET_DIR"
    REPO="$TARGET_DIR"
else
    die "not inside a checkout and no --repo/REPO_URL given"
fi

# --- 2. Put av-scan / av-setup on PATH -------------------------------------
say "installing commands"
if [ "$SYSTEM" -eq 1 ]; then sudo "$REPO/install.sh" --system; else "$REPO/install.sh"; fi
AVSCAN="$REPO/bin/av-scan"      # call by path — PATH may not be refreshed in this shell

# --- 3. Install packages + enable services (per distro; re-execs via sudo) --
say "installing + enabling the AV stack (av-setup all)"
"$REPO/bin/av-setup" all

# --- 4. Whole-box config (optional) ----------------------------------------
TIMER_PATHS="${AV_SCAN_PATHS:-$HOME}"   # $HOME here = the human's, before sudo
if [ "$SCAN_ALL" -eq 1 ]; then
    say "configuring WHOLE-BOX scanning (/), system-wide"
    sudo mkdir -p /etc/linux-av
    printf '# written by bootstrap.sh --full\nAV_SCAN_PATHS="/"\n' | sudo tee /etc/linux-av/av.env >/dev/null
    TIMER_PATHS="/"
fi

# --- 5. Scan timer (optional) ----------------------------------------------
if [ -n "$TIMER_MS" ]; then
    say "installing systemd scan timer every ${TIMER_MS}ms, target: $TIMER_PATHS"
    sudo env AV_SCAN_PATHS="$TIMER_PATHS" "$AVSCAN" --install-timer "$TIMER_MS"
fi

say "done on $(hostname). Verify:  av-scan --status   (open a new shell if 'av-scan' isn't found yet)"
[ "$SCAN_ALL" -eq 1 ] || say "NOTE: default scans only \$HOME. Re-run with --full (and as root) to cover the whole box."
