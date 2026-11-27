#!/usr/bin/env bash
# Verifies the system libraries the native companion build links against.
# Zig fetches everything else; these must come from the operating system.
# SDL and ztray load libdbus at runtime, so no D-Bus headers or pkg-config.
set -euo pipefail

[ "$(uname -s)" = Linux ] || exit 0

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
missing=()

# probe <name> <debian> <fedora> <arch> <c source> <compiler flags...>
probe() {
    local name=$1 deb=$2 fed=$3 arch=$4 src=$5
    shift 5
    printf '%s\n' "$src" > "$tmp/$name.c"
    if ! zig cc "$tmp/$name.c" "$@" -o "$tmp/$name" 2>"$tmp/$name.err"; then
        missing+=("$name|$deb|$fed|$arch")
    fi
}

probe xkbcommon libxkbcommon-dev libxkbcommon-devel libxkbcommon \
    $'#include <xkbcommon/xkbcommon.h>\n#include <xkbcommon/xkbcommon-compose.h>\nint main(void) { return xkb_context_new(XKB_CONTEXT_NO_FLAGS) == 0; }' \
    -lxkbcommon

[ ${#missing[@]} -eq 0 ] && exit 0

deb=() fed=() arch=()
for entry in "${missing[@]}"; do
    IFS='|' read -r name d f a <<<"$entry"
    deb+=("$d") fed+=("$f") arch+=("$a")
    echo "error: $name not found" >&2
    [ -f "$tmp/$name.err" ] && sed 's/^/  /' "$tmp/$name.err" >&2
done
cat >&2 <<MSG
The native companion build needs these system packages. Install them with:
  Debian/Ubuntu: sudo apt install ${deb[*]}
  Fedora:        sudo dnf install ${fed[*]}
  Arch:          sudo pacman -S ${arch[*]}
MSG
exit 1
