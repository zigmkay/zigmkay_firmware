# Repository layout

This page maps the repository: the five Zig packages, what each owns, and how
they depend on each other. Use it to find where a change belongs before you
open an editor.

[Documentation index](../README.md) · [Discord](https://discord.gg/bJCZUtJD65)

## Overview

```text
zigmkay_firmware/
├── build.zig, build.zig.zon   root package (zigmkay_firmware)
├── mise.toml                  monorepo tasks and the Zig 0.17.0 pin
├── zigmkay/                   firmware core library and host tools
├── keyboards/                 board table, board main files and keymaps
├── zkeycodes/                 keycode generator and generated locale layouts
├── companion/                 ZigMkay Companion desktop application
└── .github/workflows/         CI
```

Every package has its own `build.zig`, `build.zig.zon` and `mise.toml`.
Packages refer to each other by relative path, so one checkout always builds
consistently. External dependencies are pinned by URL and hash.

## Packages

### Root: `zigmkay_firmware`

[`build.zig`](../../build.zig) exposes the `zigmkay` module, the core test step
and, on macOS, `rawhid-monitor`. It also re-exports the board table
(`keyboards`), microzig and `addFlashSteps`, so other packages, such as the
companion, can build and flash firmware without duplicating build logic.

### `zigmkay/`: firmware core

The library every keyboard imports as `@import("zigmkay")`. It pins
[microzig](https://github.com/ZigEmbeddedGroup/microzig) and picotool in
[`zigmkay/build.zig.zon`](../../zigmkay/build.zig.zon).

| Path | Contents |
| --- | --- |
| `src/core.zig` | Types: `KeyDef`, `TapDef`, `HoldDef`, combos, queues, layers, special keycodes |
| `src/processing.zig` | The processor: tap/hold decisions, combos, autofire, one-shots, layers |
| `src/loops.zig` | Unibody, primary and secondary main loops and their configuration types |
| `src/matrix_scanning.zig`, `src/encoder_scanning.zig` | Matrix or direct-wired switches; quadrature encoders |
| `src/split_communication.zig`, `src/split_protocol.zig` | UART and PIO UART link between halves |
| `src/usb_if.zig`, `src/usb_command_executor.zig` | USB HID interfaces and the executor that sends reports |
| `src/companion.zig` | Raw HID [companion protocol](companion-protocol.md) |
| `src/macros.zig`, `src/combo.zig` | Helper constructors for keys and combos |
| `tests/` | Processing and protocol tests that run on the host |
| `tools/` | `flash_picotool`, `flash_mount`, `rawhid_monitor` |

### `keyboards/`: boards and keymaps

| Path | Contents |
| --- | --- |
| [`boards.zig`](../../keyboards/boards.zig) | Every build target: name, main file, keymap file |
| `build.zig` | `-Dkeyboard=<name>`, `-Dkeymap=<path>`, the UF2 output, flash steps, and a test step that compiles every board |
| `my_keyboards/<owner>/` | Main files and keymaps of contributors' boards |
| `examples/` | Starter boards such as `dasbob` |
| `tools/` | `scaffold.zig` and its templates, behind `keymap:new` and `board:new` |
| `local/` | Personal keymaps from `keymap:new`; git-ignored and never bundled |
| `tests/` | Keymap regression tests |

The [keyboards README](../../keyboards/README.md) lists every task.

### `zkeycodes/`: keycodes

Generates Zig keycode tables from QMK's HJSON layout definitions. The generated
files in `keycodes/` are committed; keymaps import them as
`@import("zkeycodes")`. See the [zkeycodes README](../../zkeycodes/README.md).

### `companion/`: desktop application

The ZigMkay Companion: editor, live overlay, tray and typing tutor. It depends
on the root package by path and compiles the selected boards' firmware from the
same checkout. Its own documentation lives in
[`companion/docs/`](../../companion/docs/development.md).

## Dependency direction

```text
companion ──► zigmkay_firmware (root) ──► keyboards ──► zigmkay, zkeycodes
                                     └──► zigmkay ──► microzig, picotool
```

The firmware never depends on the companion.
