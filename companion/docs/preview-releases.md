# Executable preview releases

Preview packaging targets macOS 15 on Apple Silicon and Intel, Windows 11 on
x86_64, and glibc Linux on x86_64 (Ubuntu 22.04 / glibc 2.35 baseline). Users do
not need Zig. Every download contains Zig 0.17.0, its library tree, immutable
firmware packages, native runner sources and flash tools. Missing resources fail
locally; firmware builds use the bundled compiler with `--system` and do not
download replacements. Linux uses AppImage rather than a sandboxed Flatpak;
Flatpak device and USB-portal integration remains future work.

These are unsigned previews. Read the [download notes](../packaging/preview-notes.md)
for OS launch restrictions. No release has been published merely by adding this
workflow. Current evidence is local Apple Silicon packaging, offline firmware
and runner checks; the other native release lanes must pass in CI before release.

## Building and packaging

Use exactly Zig 0.17.0. On the native host:

```sh
zig build bundle tools -Dbundle \
  -Drelease -Doptimize=safe -Drevision="$(git rev-parse HEAD)" -j2
```

On macOS also pass `-Dmacos-sdk="$(xcrun --show-sdk-path)"`. The release graph
uses baseline CPUs and explicit minimum OS versions, including the native flash
helpers. The installed layouts are `zig-out/Zigmkay.app`, `zig-out/Zigmkay.exe`
and `zig-out/Zigmkay.AppDir`. Linux's Zig `AppRun` resolves the application and
libraries from its own location; the application resolves resources from its
executable. User projects, exports and compiler caches stay in
the existing platform user-storage locations, outside the installation/mount.

Run `zig-out/bin/release package ABSOLUTE_PACKAGE_PATH ABSOLUTE_OUTPUT_DIRECTORY
SOURCE_COMMIT` to create the DMG, portable EXE or AppImage. Windows uses
`release.exe`. Packaging is a developer/CI operation and may acquire pinned
packaging tools and corresponding sources. The installed application never does.
AppImage inputs use [tagged release asset IDs and SHA-256 pins](../packaging/appimage-pins.zon)
(continuous releases delete their assets when they rebuild);
the runtime is supplied with `--runtime-file`, avoiding appimagetool's default
latest-runtime download. Tool pins must be reviewed together with their sources.

Linux packaging requires Ubuntu 22.04 build libraries, `readelf`, `ldd`, `curl`,
`tar`, `xkb-data`, `libx11-data`, and enabled `deb-src` package indexes. It
inspects every shipped ELF executable/shared library, including Zig and helpers;
bundles non-baseline dependencies and SDL native backends, XKB layout and Compose
data and library notices; and rejects GLIBC requirements above 2.35. glibc, its loader and graphics-driver libraries
remain system-provided. Exact installed source package versions are downloaded
into the corresponding-source directory. macOS rejects non-system dynamic
dependencies. Windows inspects ordinary and delay-loaded PE imports for every
shipped executable and DLL against the Windows system-library allowlist.

The DMG contains the application and an Applications shortcut. Application
metadata records version, source revision, architecture and minimum OS. Build
resources have a bundle identity and tool hashes; per-asset JSON adds supported
database, record, timing, metric and generator versions. Package hashes are
computed after packaging. Future signing must reseal hashes of nested executables;
the Windows payload reader currently expects its footer at EOF, so appending an
Authenticode signature requires a reader change before signing.

## Linux launch and device permissions

Use `chmod +x Zigmkay-*.AppImage`, then launch the file. The modern static runtime
does not need a separate libfuse2 package. If the kernel cannot mount FUSE:

```sh
./Zigmkay-*.AppImage --appimage-extract
./squashfs-root/AppRun
```

Both forms use the same persistent user-data directories. Keep the extracted
directory intact. Flashing needs no system rule: the editor copies the UF2 onto
the RPI-RP2 volume that udisks2 mounts for the desktop user. Neither form installs
system rules automatically. To allow a local logged-in user to access the live
companion HID interface (FAFA:00F0), inspect and install the narrowly scoped
[udev rule](../packaging/linux/70-zigmkay.rules):

```sh
sudo install -m 0644 squashfs-root/usr/share/zigmkay/70-zigmkay.rules /etc/udev/rules.d/70-zigmkay.rules
sudo udevadm control --reload-rules
```

Reconnect the keyboard after reloading. The `uaccess` rules grant an active local
session access; remote/headless users need an administrator's explicit device
access policy. macOS retains picotool. Windows and Linux copy onto the BOOTSEL
mass-storage volume with the bundled Zig transfer helper, with no WinUSB setup or
udev rule. It rejects multiple matching devices, verifies USB ancestry plus
`INFO_UF2.TXT`, revalidates the volume identity (Windows: GUID/serial/disk/USB;
Linux: block device, USB device, serial and mount point), checks frozen UF2 bytes
and hash, and writes directly to the verified volume. On Linux an unmounted volume
is mounted once with `udisksctl mount`. Cancellation stops and joins
the helper; discovery and transfer are bounded, with no automatic retry. Copying
completes the transfer; only the existing coherent live firmware handshake
completes flashing. There is no mass-storage byte-for-byte flash read-back.
Version-1 tool and bundle descriptors continue to use picotool; version 2 records
the backend and the executable hashes (the wrapper hash identifies the helper).

## CI and publishing

The [application workflow](../../.github/workflows/companion-application-bundle.yml) preserves
the focused Windows diagnostic/GUI modes and builds four native release targets
on `main`, uploading downloadable packages without publishing. Linux runtime jobs
exercise mounted and extracted AppImages on Ubuntu 22.04 and 24.04.
Pull requests run a faster subset: macOS arm64, Windows and Linux packages, the
macOS representative offline check and the Linux runtime on Ubuntu 24.04. The
`full-ci` label runs the complete `main` set on a PR. A new push cancels the PR's
running checks. Offline checks relocate packages into paths with spaces/Unicode,
deny networking and system Zig/SDK access, use read-only resources and empty
compiler caches, and build firmware/native runners for catalog selectors cold and
warm. Windows uses filesystem ACLs and firewall policy in addition to PATH
isolation.

To tag and publish a companion release from GitHub, run the
[Release Companion](../../.github/workflows/companion-release.yml) workflow on
`main` (optionally supplying a version to update `companion/build.zig.zon`). It
creates and pushes the annotated `companion-v<version>` tag and invokes the
application bundle workflow to build, verify and publish all four platform
artifacts, `SHA256SUMS`, metadata and `corresponding-source.tar.gz` as a GitHub
Release. Manually pushed `companion-vMAJOR.MINOR.PATCH` (stable release) and
`companion-vMAJOR.MINOR.PATCH-preview.N` (prerelease) tags also trigger
publishing. The version after the `companion-` prefix must exactly match
`companion/build.zig.zon` and point to a commit belonging to `main`. Source,
storage, native desktop and packaged-runtime jobs run against that commit. Only
the tagging step and final publish job request `contents: write`; publishing
waits for all required jobs, validates four downloads and their metadata/hashes,
prepares corresponding sources and `SHA256SUMS`, then creates a draft, uploads
assets and publishes the release. All Actions are pinned by commit. Failed gates
never run publishing. A failed draft upload can be resumed; a rerun against an
already published release refuses to replace its assets.

Run `zig build test-practice test-jobs` for focused offline contracts, and `zig build check test` for the
full source suite. Packaging outputs belong in caches. Native Windows driver-free flashing and
desktop/device acceptance need a separately requested hardware task.

References: [AppImage concepts](https://docs.appimage.org/introduction/concepts.html),
[appimagetool](https://github.com/AppImage/appimagetool#usage),
[static runtime](https://github.com/AppImage/type2-runtime),
[picotool driver requirements](https://github.com/raspberrypi/picotool#zadig),
[RP2040 UF2 workflow](https://www.raspberrypi.com/documentation/microcontrollers/pico-series.html#drag-and-drop-a-program-onto-your-pico-series-device),
[Flatpak device permissions](https://docs.flatpak.org/en/latest/sandbox-permissions.html).
