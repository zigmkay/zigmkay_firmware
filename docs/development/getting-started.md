# Getting started for developers

This page gets a development checkout working: the toolchain, the task runner,
building and testing every package, and flashing a keyboard. Read it before
your first change; the other developer pages assume this setup.

[Documentation index](../README.md) · [Discord](https://discord.gg/bJCZUtJD65)

## Tools

| Tool | Why |
| --- | --- |
| [Zig 0.17.0](https://ziglang.org/download/) | Exactly this version, for firmware, companion, build logic and tests |
| [mise](https://mise.jdx.dev/installing-mise.html) | Selects Zig 0.17.0 and runs every task from the repository root |
| Git | Cloning; the build fetches pinned dependencies such as microzig itself |
| Xcode Command Line Tools (macOS only) | Compiling the companion application from source |

```sh
git clone https://github.com/zigmkay/zigmkay_firmware.git
cd zigmkay_firmware
mise trust --all && mise install
mise exec -- zig version   # must print 0.17.0
mise tasks --all           # list every task
```

You can also run `zig build` directly inside each package if Zig 0.17.0 is on
your `PATH`; the mise tasks are thin wrappers around those steps. A
[`shell.nix`](../../shell.nix) is provided for Nix users.

## Everyday tasks

The repository root is a mise monorepo: run any package's task as
`mise run //<package>:<task>` without changing folders.

| Task | What it does |
| --- | --- |
| `mise run test` | Every offline firmware, keyboard, keycode and companion test |
| `mise run check` | Compiles every board and companion source; runs the keyboard tests, not the companion tests |
| `mise run //zigmkay:test` | Firmware core tests |
| `mise run //keyboards:test` | Compiles every keyboard and runs the keyboard regression tests |
| `mise run //zkeycodes:test` | Keycode generator and layout tests |
| `mise run //keyboards:build <name>` | Builds one keyboard into `keyboards/zig-out/firmware/`; `--keymap <file>` builds another keymap |
| `mise run //keyboards:keymap:new <keyboard> [name]` | Copies a default keymap to the Git-ignored `keyboards/local/<name>/` |
| `mise run //keyboards:board:new <name>` | Creates a new board in `keyboards/my_keyboards/` and registers it |
| `mise run //companion:editor` | Builds and starts the companion editor |
| `mise run //companion:test` | Offline companion tests |

Builds and tests never touch a connected keyboard. Only the flash tasks, the
Raw HID monitor and normal companion startup talk to devices.

## Flashing

`<name>` is a target from [`keyboards/boards.zig`](../../keyboards/boards.zig);
the shell completes it with Tab. Every flash task also takes
`--keymap <file>`, as `build` does. The
[keyboards README](../../keyboards/README.md) lists every keyboard task.

| Task | `zig build` step (in `keyboards/`) | Method |
| --- | --- | --- |
| `mise run //keyboards:flash <name>` | `flash -Dkeyboard=<name>` | Host default: mount on Windows and Linux, picotool on macOS |
| `mise run //keyboards:flash:picotool <name>` | `flash_pt -Dkeyboard=<name>` | picotool, built from source by the build |
| `mise run //keyboards:flash:mount <name> --mount <path>` | `flash_mount -Dkeyboard=<name> -Dflash-mount=<path>` | Copy the UF2 to the mounted `RPI-RP2` drive |
| `mise run //keyboards:udev` | `install-udev-rules` | Linux: install picotool's udev rule (asks for sudo) |

Start the command, then put the keyboard into bootloader mode: hold BOOT while
plugging it in, or hold BOOT and press RESET. A key bound to `core.KC_BOOT`
works too. The command waits for the keyboard, flashes and exits.

On Linux, mount flashing looks for `/run/media/$USER/RPI-RP2` and mounts the
drive with `udisksctl` if needed; pass `--mount /media/$USER/RPI-RP2` on
Ubuntu and Debian. picotool needs the udev rule once; unplug and replug the
keyboard afterwards.

## Inspecting the companion link

On macOS, `mise run //zigmkay:rawhid-monitor` prints the
[companion protocol](companion-protocol.md) reports of a connected keyboard.

## Next steps

- [Repository layout](repository-layout.md)
- [Adding a keyboard](adding-a-keyboard.md)
- [Testing and CI](testing-and-ci.md)
- [Companion development guide](../../companion/docs/development.md)
