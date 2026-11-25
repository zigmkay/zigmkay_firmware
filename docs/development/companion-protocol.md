# Companion protocol

This page specifies the Raw HID protocol between a ZigMkay keyboard and a host
application such as the ZigMkay Companion. It is implemented in
[`zigmkay/src/companion.zig`](../../zigmkay/src/companion.zig); that file is
the authority if the two ever disagree.

[Documentation index](../README.md) · [Discord](https://discord.gg/bJCZUtJD65)

## Transport

The keyboard exposes a vendor-defined Raw HID interface next to its keyboard,
consumer control and mouse interfaces. Every report is 32 bytes in both
directions, and byte 0 is the message id. Protocol version: **2**. Version 2
added `decision` and the `signal` source; a version 1 keyboard never sends
decisions, pads the source byte with zero, and hosts accept both.

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
| `0x23` | signal | `[1]` seq, `[2]` signal (1 log toggle, 2 overlay toggle, 3 shutdown), `[3]` pressed, `[4]` source (1 the key's tap action, 2 its hold action; 0 unknown) |
| `0x24` | decision | `[1]` seq, `[2]` key index, `[3]` outcome (1 tap, 2 hold, 3 retro tap), `[4]` reason (see below), `[5..7]` ms from the press to the decision (u16 little endian, saturating), `[7]` the other key index or `0xFF`, `[8..10]` the key's tapping term in ms (u16 little endian), `[10]` layer the key was taken from, `[11]` flags (bit 0: first key of a combo) |

## When messages are sent

- `key` reports raw matrix changes as they happen, before tap/hold decisions
  delay them.
- `state` follows `connect`, every layer or modifier change, and any moment
  when key events were dropped because the host stopped reading.
- `signal` comes from keys bound to `core.KC_COMPANION`,
  `core.KC_SHUTDOWN_COMPANION` or the reserved `CUSTOM_ID_COMPANION_*` ids (as
  tap or hold), after the tap/hold decision. A tap signal is pressed and
  released as the tap action starts and ends, a hold signal for as long as the
  hold lasts. Hosts toggle on a tap's press and follow a hold, so one key can
  toggle the overlay with its tap and show it momentarily with its hold.
  Unknown source values, including the `0` of keyboards that predate the
  byte, leave the choice to the host; the companion then toggles on a press
  shorter than 250 ms and shows it while held otherwise.
- `decision` reports how every tap/hold key resolved. It comes after the `key`
  reports of its press and of the keys that decided it, and before the
  signals and state the decision causes.

A host that sees a gap in the sequence numbers can send `connect` again to
resynchronise.

## Decision reasons

| Reason | Outcome | Meaning |
| --- | --- | --- |
| 1 | tap | The key was released within its tapping term |
| 2 | hold | The tapping term elapsed while the key was held |
| 3 | hold | Permissive hold: another key on the other side, or one without a side, was pressed and released within the term; it is the other key |
| 4 | tap | Another key on the same side was pressed and released within the term; it is the other key |
| 5 | retro tap | A hold with retro tapping was released with nothing in between, so the key typed its tap after all |

The processor retro-taps only when the release is already queued as the
tapping term passes; a hold decided in an earlier scan is released without a
tap and without a retro tap report.

## Keymap identity

The 16-byte keymap id in `hello` comes from
`CustomFunctions.companion_keymap_id`. Tools that generate keymaps set it;
all zeros means unknown.

## Trying it

On macOS, `mise run //zigmkay:rawhid-monitor` connects to a keyboard and
prints its reports ([`rawhid_monitor.zig`](../../zigmkay/tools/rawhid_monitor.zig)).
How the companion uses the stream is described in the
[companion development guide](../../companion/docs/development.md).
