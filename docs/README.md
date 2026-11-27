# ZigMkay documentation

This is the entry point to the ZigMkay documentation. It collects the guides for
people who write keymaps, people who add keyboards, and people who work on the
firmware core or the companion application. If something is missing or unclear,
ask on the [ZigMkay Discord](https://discord.gg/bJCZUtJD65) or open an issue.

[Project README](../README.md) · [Discord](https://discord.gg/bJCZUtJD65) · [Contributing](../CONTRIBUTING.md)

## Using ZigMkay

| Guide | What it covers |
| --- | --- |
| [Quick start](../README.md#quick-start) | Install the tools, build and flash a supported keyboard |
| [Supported keyboards](../README.md#supported-keyboards) | Every board target in `keyboards/boards.zig` |
| [Keymap guide](keymaps.md) | Key types, layers, combos, encoders, custom code |
| [Companion README](../companion/README.md) | The visual editor, live overlay, tray and typing tutor |
| [Typing practice](../companion/docs/typing-practice.md) | Adaptive 6-stage typing tutor, Test keys mode, local progress & input sources |

## Developing ZigMkay

| Guide | What it covers |
| --- | --- |
| [Getting started](development/getting-started.md) | Zig 0.17.0 and mise, building, testing, flashing |
| [Repository layout](development/repository-layout.md) | The root package, `zigmkay/`, `keyboards/`, `zkeycodes/`, `companion/` |
| [Adding a keyboard](development/adding-a-keyboard.md) | Board table, main file, keymap, companion descriptor |
| [Architecture](development/architecture.md) | Scan, process, send; split halves, encoders, custom code |
| [Companion protocol](development/companion-protocol.md) | The Raw HID messages between keyboard and host |
| [Testing and CI](development/testing-and-ci.md) | Test tasks, what they check, and the GitHub workflows |

## Companion internals

The companion keeps its own developer documentation next to its source:

- [Companion development guide](../companion/docs/development.md): package map,
  native GUI builds, test tasks, application assembly
- [Keyboard projects](../companion/docs/keyboard-projects.md)
- [Compatibility status](../companion/docs/compatibility.md)
- [Preview releases](../companion/docs/preview-releases.md)
- [Editor design](../companion/docs/design/editor.md)

## Getting help

- [Discord](https://discord.gg/bJCZUtJD65) for questions and discussion
- [GitHub issues](https://github.com/zigmkay/zigmkay_firmware/issues) for bugs
  and feature requests
