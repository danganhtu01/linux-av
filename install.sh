#!/usr/bin/env bash
# install.sh — put `av-scan` and `av-setup` on your PATH by symlinking them out
# of this checkout, so a `git pull` updates them in place. Nothing is copied.
#
#   ./install.sh            # user install -> ~/.local/bin  (no root)
#   sudo ./install.sh -s    # system install -> /usr/local/bin  (all users)
#
# Works the same on Arch, Debian and Ubuntu.
set -euo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREFIX_BIN="${PREFIX:-$HOME/.local}/bin"
while [ $# -gt 0 ]; do
    case "$1" in
        -s|--system) PREFIX_BIN="/usr/local/bin" ;;
        -h|--help)   echo "usage: install.sh [-s|--system]"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac; shift
done

mkdir -p "$PREFIX_BIN"
for tool in av-scan av-setup; do
    chmod +x "$REPO/bin/$tool"
    ln -sfn "$REPO/bin/$tool" "$PREFIX_BIN/$tool"
    echo "linked $PREFIX_BIN/$tool -> $REPO/bin/$tool"
done

case ":$PATH:" in
    *":$PREFIX_BIN:"*) : ;;
    *) echo
       echo "NOTE: $PREFIX_BIN is not on your PATH. Add it, e.g.:"
       echo "  echo 'export PATH=\"$PREFIX_BIN:\$PATH\"' >> ~/.bashrc && source ~/.bashrc" ;;
esac

echo
echo "Done. Next:"
echo "  av-setup all       # install + enable the AV stack (uses sudo)"
echo "  av-scan --status"
echo "  av-scan --now"
