# Keymap guide

This guide explains how a ZigMkay keymap is written: the key types, layers,
combos, encoders and the custom code hook. Everything here is plain Zig from
the [`zigmkay` core](../zigmkay/src/core.zig); the companion editor produces the
same structures when you edit visually.

[Documentation index](README.md) · [Discord](https://discord.gg/bJCZUtJD65)

## Layers and keys

A keymap is `[N][M]?KeyDef`: N layers of M keys. Key indexes run in the order
the board's main file maps them to pins. Each entry is one of:

| Entry | Meaning |
| --- | --- |
| `null` | Transparent: use the key from the next active layer below |
| `.none` | The key does nothing on this layer |
| `.tap_only` | Sends a `TapDef` when tapped |
| `.hold_only` | Applies a `HoldDef` while held |
| `.tap_hold` | Tap or hold, decided by the tapping term |
| `.tap_with_autofire` | Repeats the tap while held |

Layer 0 is always active. Holds activate further layers; the highest active
layer wins.

## Taps

A `TapDef` can carry any of:

- `key_press`: a `KeyCodeFire` with a keycode and optional `tap_modifiers`
  (for example `AltGr+7`). Set `dead = true` for a dead key; ZigMkay sends a
  space after it so the character appears on its own.
- `one_shot`: a `HoldDef` that stays armed for the next key, for one-shot
  modifiers or layers.
- `media_key`: next/previous track, mute, volume up and down.
- `mouse_action`: left, right, middle, buttons 4 and 5, wheel in four directions.
- `custom`: an id handed to your `on_event` callback.

## Holds and tap-hold

A `HoldDef` combines `hold_modifiers`, an optional `hold_layer` and an optional
`custom` id, so one hold can switch a layer and add modifiers at once. Held
modifiers add to modifiers that are already held.

`tap_hold` takes a `tapping_term`. Permissive hold is always on: press a
tap-hold key, tap another key, release the first key, all within the term, and
ZigMkay chooses the hold. That keeps fast Shift-while-typing reliable. With
`retro_tapping = true`, releasing the key fires its tap if no other key was
pressed while holding; combined with a tapping term of 0 ms this gives instant
layer switches that still type Enter on release.

## Autofire

`tap_with_autofire` repeats its tap while held, after `initial_delay` and then
every `repeat_interval`. It is meant for arrows and motions where you want fast
repeat on some keys only. Autofire keys cannot also hold.

## Combos

A `Combo2Def` names two key indexes, a layer, a `timeout` and a `KeyDef`. The
combo can do anything a key can: tap, hold, tap-hold or autofire. From
[`shared_keymap_3x5_2.zig`](../keyboards/my_keyboards/rollercole/shared_keymap_3x5_2.zig):

```zig
pub const combos = [_]core.Combo2Def{
    Combo_Tap(.{ 1, 2 }, L_BASE, dk.J),
    Combo_Tap_HoldMod(.{ 11, 12 }, L_BASE, dk.Z, .{ .right_ctrl = true, .right_alt = true }),
    Combo_Tap(.{ 24, 25 }, L_BASE, BOOT),
    // ...
};
```

Combos are limited to two keys. A combo only fires on its own layer.

## Encoders

A rotary encoder is wired in the board's main file with
`EncoderPinConfig`; each step in a direction fires that direction's
`EncoderAction`, which holds a `TapDef` (a key, media key, mouse action or
custom id). Knob *n* uses slot 2*n* for clockwise and
2*n* + 1 for counter-clockwise. See
[`molekula/main.zig`](../keyboards/my_keyboards/molekula/main.zig) and
[`encoder_demo.zig`](../keyboards/my_keyboards/rollercole/encoder_demo.zig).

## Special keys

| Key | Effect |
| --- | --- |
| `core.KC_BOOT` | Reboots into the RP2040 USB bootloader for flashing |
| `core.KC_COMPANION` | Toggles the companion overlay on the host |
| `core.KC_SHUTDOWN_COMPANION` | Asks the companion application to quit |
| `core.KC_PRINT_STATS` | Types processing statistics |

## Custom code

Set `custom_functions = &core.CustomFunctions{ .on_event = myHandler }` in the
board configuration. The handler receives every `ProcessorEvent` with the layer
state and the output queue, so it can switch layers or send keys:

- `OnTapEnterBefore`, `OnTapEnterAfter`, `OnTapExitBefore`, `OnTapExitAfter`
- `OnHoldEnterBefore`, `OnHoldEnterAfter`, `OnHoldExitBefore`, `OnHoldExitAfter`
- `Tick` on every loop iteration

ZigMkay still makes the tap/hold decision; your code only runs in the case it
cares about. [`test_processing_custom_functions.zig`](../zigmkay/tests/test_processing_custom_functions.zig)
has worked examples.

## Keycodes

`zkeycodes` provides HID keycodes (`keycodes.layouts.keycodes.kcf`) and locale
layouts generated from QMK, such as `keycodes.layouts.danish`, `german` or
`us_international`. Using the locale names means `dk.LCBR` types `{` on a
Danish host layout. See the [zkeycodes README](../zkeycodes/README.md).
