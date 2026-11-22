# Adding a keyboard

This page walks through adding a new RP2040 keyboard so that it builds,
flashes and appears in the companion. A board is a main file and a keymap
file, registered in the board table; to appear in the companion it also needs
a processing binding and display information. For a keymap of your own on an
existing board, see [Use your own keymap](../../keyboards/README.md#use-your-own-keymap).

[Documentation index](../README.md) · [Discord](https://discord.gg/bJCZUtJD65)

## 1. Create the files

For a unibody board with a switch matrix, let the task create them:

```sh
mise run //keyboards:board:new my_board
```

It writes `keyboards/my_keyboards/my_board/main.zig` and `keymap.zig` from the
commented templates in
[`keyboards/tools/templates/`](../../keyboards/tools/templates/) and adds the
board to `keyboards/boards.zig`. `mise run //keyboards:test` compiles the
templates, so what the task creates always builds.

For other boards, copy the closest existing board into your own folder under
`keyboards/my_keyboards/<you>/`:

| If your board is | Start from |
| --- | --- |
| Split, direct-wired switches | [`examples/dasbob/`](../../keyboards/examples/dasbob/) |
| Split with encoders | [`my_keyboards/rollercole/tuckytwotimes.zig`](../../keyboards/my_keyboards/rollercole/tuckytwotimes.zig) |
| Unibody matrix | `board:new`, or [`my_keyboards/rollercole/leonardo_keycaprio_0_8.zig`](../../keyboards/my_keyboards/rollercole/leonardo_keycaprio_0_8.zig) |
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
[keymap guide](../keymaps.md). A keymap is the root of its own module, so it
can import files by path only from its own folder and below.

## 4. Register the board

`board:new` does this step. Otherwise add an entry to
[`keyboards/boards.zig`](../../keyboards/boards.zig):

```zig
.{ .name = "my_board", .root_source_file = "my_keyboards/me/my_board.zig", .keymap = "my_keyboards/me/my_board_keymap.zig" },
```

Names must be unique; a test checks it. Leave `keymap` null only for examples
that define the keymap inside the main file; the companion skips those.

## 5. Register it with the companion

The companion offers a board with a `keymap` once its main file has a
binding in
[`companion/src/firmware/boards.zig`](../../companion/src/firmware/boards.zig),
with the number of encoder action slots (two per knob) and where its sides
come from:

```zig
.{ .root = "my_keyboards/me/my_board.zig", .encoder_actions = 2 },
```

Use `.sides = .unassigned` if the main file passes no `side_definition`.
[`processing_descriptors.zig`](../../companion/src/firmware/processing_descriptors.zig)
turns the bindings into the processing contract. Without a binding the
companion still compiles and runs but does not offer the board, and the
companion test `every firmware board with a keymap has companion data` fails
and names it, so a pull request cannot leave a board out silently.

A board with a binding also needs a display name and PCB revision in
[`companion/src/catalog/presentation.zig`](../../companion/src/catalog/presentation.zig).
Optionally, give it a schematic key placement in
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

To contribute the board, also add it to the
[supported keyboards](../../README.md#supported-keyboards) table, then open a
pull request.

Questions about pin mappings or a new controller? Ask on the
[Discord](https://discord.gg/bJCZUtJD65).
