# Keyboards

This package holds every keyboard ZigMkay builds: the board table, each
board's main file and default keymap, and the recipe that turns them into a
UF2 file for the RP2040. Start here to build or flash a keyboard, to keep a
keymap of your own, or to add a new keyboard.

[Keymap guide](../docs/keymaps.md) · [Adding a keyboard](../docs/development/adding-a-keyboard.md) · [Discord](https://discord.gg/bJCZUtJD65)

## Tasks

Run every task from the repository root; mise selects Zig 0.17.0. `<keyboard>`
is a name from [`boards.zig`](boards.zig), such as `lk8`, and the shell
completes it with Tab.

| Task | What it does |
| --- | --- |
| `mise run //keyboards:build <keyboard> [--keymap <file>]` | Builds `keyboards/zig-out/firmware/zigmkay_firmware.uf2` |
| `mise run //keyboards:flash <keyboard> [--keymap <file>]` | Builds and flashes with the host default: the mounted drive on Windows and Linux, picotool on macOS |
| `mise run //keyboards:flash:picotool <keyboard> [--keymap <file>]` | Builds and flashes with picotool, which the build compiles from source |
| `mise run //keyboards:flash:mount <keyboard> [--mount <path>] [--keymap <file>]` | Builds and copies the UF2 to the mounted `RPI-RP2` drive |
| `mise run //keyboards:test` | Compiles every keyboard and the board template, and runs the keyboard tests |
| `mise run //keyboards:udev` | Linux: installs picotool's udev rule (asks for sudo) |
| `mise run //keyboards:keymap:new <keyboard> [name]` | Copies the keyboard's default keymap to `keyboards/local/<name>/` |
| `mise run //keyboards:board:new <name>` | Creates `keyboards/my_keyboards/<name>/` for a new board and adds it to `boards.zig` |

`--keymap` builds another keymap file instead of the keyboard's own. Give it
relative to `keyboards/`, such as `local/lk8/keymap.zig`, or as an absolute
path.

```sh
mise run //keyboards:build lk8
mise run //keyboards:flash molekula
mise run //keyboards:flash:mount lk8 --mount /media/$USER/RPI-RP2
mise run //keyboards:keymap:new lk8 travel
mise run //keyboards:build lk8 --keymap local/travel/keymap.zig
```

To flash, start the command, then put the keyboard into bootloader mode: hold
BOOT while plugging it in, or hold BOOT and press RESET. A key bound to
`core.KC_BOOT` works too. The command waits for the keyboard, flashes and
exits. Builds and tests never touch a connected keyboard. More on mount paths
and picotool is in
[Getting started](../docs/development/getting-started.md#flashing).

## Use your own keymap

Keep your keymap in `keyboards/local/`. Git ignores that folder, so your
keymap never shows up as a change and an upstream update never conflicts with
it.

1. Copy the default keymap of your keyboard:

   ```sh
   mise run //keyboards:keymap:new lk8          # keyboards/local/lk8/keymap.zig
   mise run //keyboards:keymap:new lk8 travel   # keyboards/local/travel/keymap.zig
   ```

   Files the keymap imports by path come along into the same folder, such as
   `keymap_shared.zig` for the `keycaprio_*` and `clackychan_colemak`
   keymaps. The task never overwrites an existing folder.

2. Edit `keyboards/local/<name>/keymap.zig`. The
   [keymap guide](../docs/keymaps.md) explains layers, tap-hold keys, combos,
   encoders and custom code. Keep `key_count`: it must match the keys of the
   board's main file, or the build stops with an error.

3. Build and flash it:

   ```sh
   mise run //keyboards:build lk8 --keymap local/lk8/keymap.zig
   mise run //keyboards:flash lk8 --keymap local/lk8/keymap.zig
   ```

Your copy does not follow later changes to the default keymap; compare it with
the original, named in the output of `keymap:new`, when you update. Inside
`keyboards/`, the same build is
`zig build -Dkeyboard=lk8 -Dkeymap=local/lk8/keymap.zig`.

Prefer clicking to typing? The [companion](../companion/README.md) edits,
builds and flashes keymaps visually and keeps its own layouts; it does not read
`keyboards/local/`.

## Add a new keyboard

```sh
mise run //keyboards:board:new my_board
```

This creates two files from the commented templates in
[`tools/templates/`](tools/templates/), a unibody RP2040 board with a switch
matrix, and adds `my_board` to `boards.zig`:

| File | What to change |
| --- | --- |
| `my_keyboards/my_board/main.zig` | The GPIO pins, `pin_cols` and `pin_rows`, `pin_mappings` (one column and row per key index), the diode direction and debounce |
| `my_keyboards/my_board/keymap.zig` | `key_count`, the layers, `sides` and the combos |
| `boards.zig` | Already done: `.{ .name = "my_board", .root_source_file = "my_keyboards/my_board/main.zig", .keymap = "my_keyboards/my_board/keymap.zig" }` |

Then build it, check every board and flash it:

```sh
mise run //keyboards:build my_board
mise run //keyboards:test
mise run //keyboards:flash my_board
```

For a split keyboard, copy [`examples/dasbob/`](examples/dasbob/) instead: it
shows the UART link and how each half finds out that it is the primary side.
Encoders are wired as in [`my_keyboards/molekula/`](my_keyboards/molekula/).
Then add the `boards.zig` line yourself. The
[developer guide](../docs/development/adding-a-keyboard.md) explains the main
file in more detail.

A new board lives in `my_keyboards/`, not in `local/`, because a board is
hardware that others can build too. In `boards.zig` it gets every task, Tab
completion and the compile check of `mise run //keyboards:test`, without extra
options, and it is ready for a pull request as it is.

### Into the companion and upstream

The companion compiles and runs without the new board, but leaves it out until
the board has companion data, and `mise run test` names such boards. To offer
it in the companion and to contribute it:

1. Add a binding for the main file to
   [`companion/src/firmware/boards.zig`](../companion/src/firmware/boards.zig):
   where its sides come from and its encoder action slots, two per knob.

   ```zig
   .{ .root = "my_keyboards/my_board/main.zig", .encoder_actions = 0 },
   ```

   Use `.sides = .unassigned` if the main file passes no `side_definition`.
2. Add its display name, PCB revision, template and host layout to
   [`companion/src/catalog/presentation.zig`](../companion/src/catalog/presentation.zig).
3. Optionally, add a schematic key placement to
   [`companion/src/catalog/schematic/`](../companion/src/catalog/schematic/);
   without one the editor draws the keys in a line.
4. Add a row to the supported keyboards table in the
   [root README](../README.md#supported-keyboards).
5. Run `mise run test`, then open a pull request.

Questions about pins or a controller? Ask on the
[Discord](https://discord.gg/bJCZUtJD65).

## Layout

```text
keyboards/
├── boards.zig        the board table: name, main file, keymap file
├── build.zig         -Dkeyboard, -Dkeymap, the flash steps, keymap-new, board-new
├── mise.toml         the tasks above
├── my_keyboards/     contributors' boards, one folder per owner or board
├── examples/         starter boards, such as dasbob
├── tools/            scaffold.zig (keymap:new, board:new) and its templates
├── tests/            keymap regression tests
└── local/            your personal keymaps; ignored by Git, created by keymap:new
```
