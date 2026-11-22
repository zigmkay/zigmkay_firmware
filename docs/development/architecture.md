# Firmware architecture

This page explains how the ZigMkay firmware runs: the main loop, how scanning,
processing and USB output are separated by queues, how split halves and
encoders feed into it, and where custom code and the companion link attach.
Read it before changing anything in [`zigmkay/src/`](../../zigmkay/src/).

[Documentation index](../README.md) · [Discord](https://discord.gg/bJCZUtJD65)

## Design principles

- **No hidden control flow.** No timers or interrupts drive behaviour. One
  sequential loop does everything, and a first-time reader can follow it.
- **The user's code is the top level.** A board's `main()` configures and
  starts the loop. There are no magic function names, `#define`s or
  compile flags; it is all Zig your editor understands.
- **Three legs, joined by queues.** Scanning, processing and USB output only
  talk through queues, so the complex middle leg is tested on the host
  without hardware.
- **Deliberately out of scope:** wireless, RGB and tap dance. ZigMkay targets
  the microcontrollers microzig supports; boards today use the RP2040.

## The loop

[`loops.zig`](../../zigmkay/src/loops.zig) contains the unibody, primary and
secondary loops. Each iteration of the primary loop:

```text
          ┌──────────────┐  MatrixStateChangeQueue  ┌────────────┐  OutputCommandQueue  ┌──────────────┐
switches ─► matrix scan  ├─────────────────────────►│            ├─────────────────────►│ USB executor ├─► host
encoders ─► encoder scan ├──── EncoderEventQueue ──►│ processor  │                      └──────────────┘
UART     ─► split recv   ├─────────────────────────►│            │◄── on_event (custom code)
          └──────────────┘                          └─────┬──────┘
                                                          ▼
                                             companion session (Raw HID)
```

1. **Scan.** The matrix scanner (row/column matrix or direct wiring, with
   debounce) and the encoder scanner push timestamped changes into queues.
2. **Receive.** On a split primary, events from the secondary half arrive over
   UART and join the same queues.
3. **Process.** [`processing.zig`](../../zigmkay/src/processing.zig) decides
   taps and holds (with permissive hold and retro tapping), resolves combos,
   autofire, one-shots and layers, and enqueues output commands.
4. **Send.** The [USB executor](../../zigmkay/src/usb_command_executor.zig)
   turns commands into keyboard (6-key rollover), consumer control, mouse and
   Raw HID reports.
5. **Companion.** The [companion session](companion-protocol.md) reports raw
   key events, layer and modifier state, and handles host commands.

## Split keyboards

The secondary half runs only scanning and forwards matrix and encoder events
to the primary over UART, either a hardware UART or a PIO-based transmitter
([`split_communication.zig`](../../zigmkay/src/split_communication.zig)). The
wire format in [`split_protocol.zig`](../../zigmkay/src/split_protocol.zig) is a
delimiter byte, a message type and a payload. The primary owns the keymap and
USB. Each board decides at startup which half it is, for example by sensing
USB power on a pin.

## Encoders

[`encoder_scanning.zig`](../../zigmkay/src/encoder_scanning.zig) decodes
quadrature steps. Each step fires the `EncoderAction` for its direction, a
`TapDef`, through the processor like any other tap.

## Custom code

`CustomFunctions.on_event` receives every `ProcessorEvent` (tap and hold
enter/exit before and after, and ticks) with the layer state and
output queue. The processor keeps making tap/hold decisions; custom code only
reacts to them.

## Tests

The processor is generic over keymap dimensions and runs on the host, so
[`zigmkay/tests/`](../../zigmkay/tests/) drives it with synthetic matrix events
and checks the output commands. See [Testing and CI](testing-and-ci.md).
