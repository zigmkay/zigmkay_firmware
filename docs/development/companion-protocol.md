# Companion protocol

This page specifies the Raw HID protocol between a ZigMkay keyboard and a host
application such as the ZigMkay Companion. It is implemented in
[`zigmkay/src/companion.zig`](../../zigmkay/src/companion.zig); that file is
the authority if the two ever disagree.

[Documentation index](../README.md) · [Discord](https://discord.gg/bJCZUtJD65)

## Transport

The keyboard exposes a vendor-defined Raw HID interface next to its keyboard,
consumer control and mouse interfaces. Every report is 32 bytes in both
directions, and byte 0 is the message id. Protocol version: **1**.

The keyboard sends nothing until the host sends `connect`, so a keyboard
without a running companion behaves exactly like one without the feature.

## Host to keyboard

| Id | Command | Effect |
| --- | --- | --- |
| `0x10` | connect | Start streaming; the keyboard answers with `hello` and `state` |
| `0x11` | disconnect | Stop streaming |
| `0x12` | enter bootloader | Reboot into the RP2040 USB bootloader, for flashing |

## Keyboard to host

Byte 1 of every message except `hello` is a sequence number that wraps at 255.

| Id | Message | Layout |
| --- | --- | --- |
| `0x20` | hello | `[1]` protocol version, `[2]` key count, `[3]` layer count, `[4..20]` keymap id |
| `0x21` | state | `[1]` seq, `[2]` top layer, `[3]` modifiers, `[4..6]` active layers as bits (little endian), `[6..22]` pressed keys as bits by key index |
| `0x22` | key | `[1]` seq, `[2]` pressed, `[3]` key index, `[4]` layer, `[5]` modifiers |
| `0x23` | signal | `[1]` seq, `[2]` signal (1 log toggle, 2 overlay toggle, 3 shutdown), `[3]` pressed |

## When messages are sent

- `key` reports raw matrix changes as they happen, before tap/hold decisions
  delay them.
- `state` follows `connect`, every layer or modifier change, and any moment
  when key events were dropped because the host stopped reading.
- `signal` comes from keys bound to `core.KC_COMPANION`,
  `core.KC_SHUTDOWN_COMPANION` or the reserved `CUSTOM_ID_COMPANION_*` ids (as
  tap or hold), after the tap/hold decision.

A host that sees a gap in the sequence numbers can send `connect` again to
resynchronise.

## Keymap identity

The 16-byte keymap id in `hello` comes from
`CustomFunctions.companion_keymap_id`. Tools that generate keymaps set it;
all zeros means unknown.

## Trying it

On macOS, `mise run //zigmkay:rawhid-monitor` connects to a keyboard and
prints its reports ([`rawhid_monitor.zig`](../../zigmkay/tools/rawhid_monitor.zig)).
How the companion uses the stream is described in the
[companion development guide](../../companion/docs/development.md).
