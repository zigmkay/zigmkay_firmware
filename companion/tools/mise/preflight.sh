#!/usr/bin/env bash
# Verifies the system libraries the native companion build links against.
# Zig fetches everything else; these must come from the operating system.
# Pass `--desktop` to also check the GUI/tray dependencies (dbus-1, pkg-config).
set -euo pipefail

[ "$(uname -s)" = Linux ] || exit 0

desktop=false
for arg in "$@"; do
    case "$arg" in
        --desktop) desktop=true ;;
        *)
            echo "usage: $0 [--desktop]" >&2
            exit 2
            ;;
    esac
done

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

if $desktop; then
    # ztray links dbus-1 through Zig's pkg-config lookup; its headers live outside /usr/include.
    if command -v pkg-config >/dev/null; then
        # shellcheck disable=SC2046
        probe dbus-1 libdbus-1-dev dbus-devel dbus \
            $'#include <dbus/dbus.h>\nint main(void) { DBusError e; dbus_error_init(&e); return 0; }' \
            $(pkg-config --cflags --libs dbus-1 2>/dev/null || echo -ldbus-1)
    else
        missing+=("pkg-config|pkgconf|pkgconf-pkg-config|pkgconf")
        # Still probe dbus-1 so a fresh system gets every missing package in one command.
        probe dbus-1 libdbus-1-dev dbus-devel dbus \
            $'#include <dbus/dbus.h>\nint main(void) { DBusError e; dbus_error_init(&e); return 0; }' \
            -I/usr/include/dbus-1.0 -I/usr/lib/dbus-1.0/include -I/usr/lib64/dbus-1.0/include -I/usr/lib/x86_64-linux-gnu/dbus-1.0/include -ldbus-1
    fi
fi

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
