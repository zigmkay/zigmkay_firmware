# zigmkay: the firmware core

`zigmkay` is the firmware library that every board in [`keyboards/`](../keyboards/)
links. It scans the switch matrix and encoders, talks to the other half of a
split keyboard, decides taps, holds and combos, and sends USB HID reports. It
also builds the host tools that flash a UF2 and watch the companion link.

This page is a map for reading or changing the core. For writing keymaps, see
the [keymap guide](../docs/keymaps.md); for the design, see
[Architecture](../docs/development/architecture.md).

## Module map

`src/root.zig` is the package root and re-exports the public modules below.

| File | What it does |
| --- | --- |
| `core.zig` | Shared types: `KeyDef` (`tap_only`, `hold_only`, `tap_hold`, `tap_with_autofire`, `none`), `TapDef`, `HoldDef`, `Combo2Def`, `EncoderAction`, `Modifiers`, `LayerActivations`, `ProcessorEvent` and `CustomFunctions` (`on_event`). Defines the queues and the reserved keycodes and custom IDs (`KC_BOOT`, `KC_PRINT_STATS`, `KC_COMPANION`, `CUSTOM_ID_COMPANION_*`). |
| `generic_queue.zig` | `GenericQueue(T, capacity)`: a fixed-size array queue with no allocation; `peek_all` lets the processor look ahead. |
| `loops.zig` | The main loops. `GetUnibodyConfigType`, `GetPrimarySideConfigType` and `GetSecondarySideConfigType` take a board's comptime config and return a runner (`run_unibody`, `run_primary`, `run_secondary`). |
| `matrix_scanning.zig` | Debounced key scanning, either direct wiring (one pin per key) or a row/column matrix in `col2row` or `row2col` direction. Emits `MatrixStateChange` events. |
| `encoder_scanning.zig` | Polling quadrature decoder per encoder; a detent step emits the clockwise or counter-clockwise action index. |
| `processing.zig` | `CreateProcessorType`: the keymap engine. Resolves layers, tap/hold with permissive hold, combos, one-shots, retro tapping, autofire and encoder actions, calls `on_event`, and turns all of it into output commands. |
| `combo.zig` | `Options` helpers that build two-key `Combo2Def` values (`Combo_Tap`, `Combo_Custom`, `Combo_Tap_HoldMod`). |
| `macros.zig` | Short constructors for `KeyDef`s used in keymaps: `T`, `MED`, `MS`, `SIG`, `MO`, `AF`, layer-tap and home-row modifier helpers. |
| `split_protocol.zig` | Wire format between halves: a delimiter byte plus a 2-byte message for key presses, releases and encoder steps; send and receive helpers with a byte queue. |
| `split_communication.zig` | `UartClient`: hardware UART, or a PIO UART transmitter for boards without a free UART pin pair (transmit only). |
| `usb_if.zig` | The USB device: keyboard, consumer (media), mouse and 32-byte Raw HID interfaces on microzig's polled RP2040 driver (VID `0xFAFA`, PID `0x00F0`). |
| `usb_command_executor.zig` | Drains the output command queue into HID reports, at most one command per 10 ms, and resets to the USB bootloader for `KC_BOOT`. |
| `companion.zig` | The Raw HID companion session: silent until the host sends `connect`, then streams hello, state, key and signal reports. See the [companion protocol](../docs/development/companion-protocol.md). |
| `stats_collector.zig` | Counts main loop iterations per second; `KC_PRINT_STATS` types the lowest and highest scan rate. |
| `string_printing.zig` | Types an ASCII string as key presses (used by `KC_PRINT_STATS`). |
| `microzig_app_stub.zig` | An empty `app` module for microzig; nothing in the repository imports it at the moment. |

## Main loop data flow

A unibody board and the primary half of a split board run the same loop in
`loops.zig`, once per iteration:

```
matrix scanner ─┐
encoder scanner ┼─▶ MatrixStateChangeQueue / EncoderEventQueue
UART (secondary)┘                │
                                 ├─▶ companion key events (raw presses, before tap/hold)
                                 ▼
                     processor.Process(now) ──▶ OutputCommandQueue
                                 │                      │
                companion state update        UsbCommandExecutor ──▶ USB HID
                                                         │
                   Raw HID in/out ◀──────────▶ companion.Session
```

1. Read the time since boot, scan the matrix and encoders, and on a split
   primary decode bytes from the secondary into the same queues.
2. Report new matrix changes to the companion session as they happen.
3. `Process` handles encoder events, then repeatedly looks at the head of the
   matrix queue and decides what it is: it may wait for more events or time
   before deciding a tap/hold or combo, and dequeues only what it decided.
   It ends with the autofire tick.
4. The companion session records the new layer and modifier state.
5. The USB executor polls USB and sends the next queued command.
6. A Raw HID report from the host is handed to the session (which may ask for
   the bootloader); the session's next report is sent if the endpoint is free.

The secondary half only scans and forwards its events over UART; it has no
keymap. The queues hold 250 entries each; there are no interrupts or
allocations in the loop.

## Host tools

`build_utils.install_tools` builds these for the host and installs them, so a
dependent package can use them with `dependency.artifact(...)`:

| Tool | Source | Purpose |
| --- | --- | --- |
| `flash_picotool` | [`tools/flash_picotool.zig`](tools/flash_picotool.zig) | Wraps picotool: rejects a UF2 without the RP2040 family ID, waits for a BOOTSEL device, loads, verifies and reboots. Interactive without options; a managed mode with hashes, budgets, target filters and cancellation serves the companion. |
| `flash_mount` | [`tools/flash_mount.zig`](tools/flash_mount.zig) | Waits for the bootloader volume (absolute mount point, or volume label, default `RPI-RP2`) and writes `firmware.uf2` onto it. |
| `rawhid-monitor` | [`tools/rawhid_monitor.zig`](tools/rawhid_monitor.zig) | macOS only: connects to a keyboard's Raw HID interface and prints the companion reports, decoded with `companion.zig`. Run it with `mise run //zigmkay:rawhid-monitor`. |

## Build

- [`build.zig`](build.zig) exposes the `zigmkay` module, the `test` step and the
  tools, and re-exports the flash helpers from `build_utils.zig`.
- [`build_utils.zig`](build_utils.zig) holds the reusable build logic:
  - `add_test_steps` adds one test binary per `test_*` file in a directory;
  - `addFlashSteps` gives a board package its `flash`, `flash_pt` and
    `flash_mount` steps, the `-Dflash-mount=<path|label>` option and, on Linux,
    `install-udev-rules`. `flash` uses the mount flasher on Windows and Linux
    and picotool elsewhere;
  - `addFlash`, `addPicotoolFlash`, `addMountFlash` and `addUdevRulesInstall`
    are the single steps for packages that want their own layout;
  - `install_tools` builds the host tools above.
- [`build.zig.zon`](build.zig.zon) pins microzig and picotool by URL and hash.
  picotool is lazy: only builds that configure a picotool step fetch and
  compile it.

## Tests

[`tests/`](tests/) holds host-side unit tests, one binary per `test_*.zig`
file. Most cover the processor (`test_processing_*.zig`: tap/hold, permissive
hold, combos, one-shots, retro tapping, autofire, encoders, media and mouse
keys, custom functions, dead keys) through `test_processing_helpers.zig`.
Others cover the queues, the split protocol, the companion session and struct
sizes; `test_compile_all.zig` references every declaration of the host-safe
modules, and `test_processing_known_bugs.zig` holds regression tests for bugs fixed earlier.

```sh
mise run //zigmkay:test     # from the repository root
cd zigmkay && zig build test
```

The tests need no keyboard. `mise run test` at the root runs them together with
the keyboard, keycode and companion tests.

## See also

- [Architecture](../docs/development/architecture.md)
- [Companion protocol](../docs/development/companion-protocol.md)
- [Keymap guide](../docs/keymaps.md)
- [Keyboards](../keyboards/README.md)
- [ZigMkay Discord](https://discord.gg/bJCZUtJD65)
