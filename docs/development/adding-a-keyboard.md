# Adding a keyboard

This page walks through adding a new RP2040 keyboard, or a new keymap for an
existing one, so that it builds, flashes and appears in the companion. It
touches four places: a main file, a keymap file, the board table and the
companion's processing descriptor.

[Documentation index](../README.md) · [Discord](https://discord.gg/bJCZUtJD65)

## 1. Start from a similar board

Copy the closest existing board into your own folder under
`keyboards/my_keyboards/<you>/`:

| If your board is | Start from |
| --- | --- |
| Split, direct-wired switches | [`examples/dasbob/`](../../keyboards/examples/dasbob/) |
| Split with encoders | [`my_keyboards/rollercole/tuckytwotimes.zig`](../../keyboards/my_keyboards/rollercole/tuckytwotimes.zig) |
| Unibody matrix | [`my_keyboards/rollercole/leonardo_keycaprio_0_8.zig`](../../keyboards/my_keyboards/rollercole/leonardo_keycaprio_0_8.zig) |
| Unibody matrix with an encoder | [`my_keyboards/molekula/`](../../keyboards/my_keyboards/molekula/) |

Keeping your changes inside your own `my_keyboards/` folder keeps future
updates from upstream painless.

## 2. The main file

The main file owns the hardware: pin names, the scanner (`matrix` with
`pin_cols`, `pin_rows` and a pin mapping per key index, or `direct_wiring`
with one pin per key), debounce, encoder pins and, for split boards, the UART
and how a half detects that it is the primary side. It picks a loop:

- `zigmkay.loops.GetUnibodyConfigType` for a single controller
- `GetPrimarySideConfigType` and `GetSecondarySideConfigType` for split halves

It imports the keymap as `@import("keymap")`, never by file path, so the same
main file can be built with different keymaps.

## 3. The keymap file

The keymap file declares at least `key_count` and `keymap`, and usually
`sides` (`.L`, `.R` or `.X` per key), `combos` and `custom_functions`. See the
[keymap guide](../keymaps.md).

## 4. Register the board

Add an entry to [`keyboards/boards.zig`](../../keyboards/boards.zig):

```zig
.{ .name = "my_board", .root_source_file = "my_keyboards/me/my_board.zig", .keymap = "my_keyboards/me/my_board_keymap.zig" },
```

Names must be unique; a test checks it. Leave `keymap` null only for examples
that define the keymap inside the main file; the companion skips those.

## 5. Register it with the companion

Every board with a `keymap` must be listed in
[`companion/src/firmware/processing_descriptors.zig`](../../companion/src/firmware/processing_descriptors.zig),
keyed by its main file, with the number of encoder action slots (two per knob)
and where its sides come from:

```zig
.{ .root = "my_keyboards/me/my_board.zig", .encoder_actions = 2 },
```

Use `.sides = .unassigned` if the main file passes no `side_definition`.
Without this entry the companion does not compile; that is deliberate, so a new
main file always gets reviewed.

Optionally, give the board a display name and PCB revision in
[`companion/src/catalog/presentation.zig`](../../companion/src/catalog/presentation.zig)
and a schematic key placement in
[`companion/src/catalog/schematic/`](../../companion/src/catalog/schematic/).
Without a schematic the editor draws the keys linearly, ten per row. See
[Key placement](../../companion/docs/keyboard-projects.md#key-placement).

## 6. Build, test, flash

```sh
mise run //keyboards:build my_board
mise run check     # every board and the companion's firmware checks
mise run test
mise run //keyboards:flash my_board
```

Questions about pin mappings or a new controller? Ask on the
[Discord](https://discord.gg/bJCZUtJD65).
