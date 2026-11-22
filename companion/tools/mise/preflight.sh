#!/usr/bin/env bash
# Verifies the system libraries the native companion build links against.
# Zig fetches everything else; these must come from the operating system.
set -euo pipefail

[ "$(uname -s)" = Linux ] || exit 0

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/probe.c" <<'C'
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-compose.h>
int main(void) { return xkb_context_new(XKB_CONTEXT_NO_FLAGS) == 0; }
C

if ! zig cc "$tmp/probe.c" -lxkbcommon -o "$tmp/probe" 2>"$tmp/err"; then
    cat >&2 <<MSG
error: the xkbcommon development files (headers and libxkbcommon.so) are missing.
The companion links libxkbcommon to read the keyboard layout on Linux. Install:
  Debian/Ubuntu: sudo apt install libxkbcommon-dev
  Fedora:        sudo dnf install libxkbcommon-devel
  Arch:          sudo pacman -S libxkbcommon
Compiler output:
MSG
    sed 's/^/  /' "$tmp/err" >&2
    exit 1
fi
