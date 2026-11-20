# Testing and CI

This page lists the test and check tasks, what each one covers, and the GitHub
Actions workflows that run them on every pull request. Run the relevant tasks
locally before you push; none of them touches a connected keyboard.

[Documentation index](../README.md) · [Discord](https://discord.gg/bJCZUtJD65)

## Local tasks

| Task | Covers |
| --- | --- |
| `mise run test` | Everything below marked *test*: core, keyboards, keycodes, companion |
| `mise run check` | Compiles every board and every companion source, including companion firmware builds; runs the keyboard tests |
| `mise run //zigmkay:test` | *test* Processor and protocol tests in [`zigmkay/tests/`](../../zigmkay/tests/) |
| `mise run //keyboards:test` | *test* Compiles every board in `boards.zig`, unique names, keymap regression tests |
| `mise run //zkeycodes:test` | *test* Keycode generation and label tests |
| `mise run //companion:test` | *test* Offline companion tests |
| `mise run //companion:firmware:check` | Every board with synthetic, default and imported companion keymaps |
| `mise run //companion:editor:test` | Offline GUI fixtures: launch, onboarding, tutor, drafts, companion overlay |

The companion has more focused tasks (`jobs:test`, `desktop:check`,
`typing-practice:test`); see the
[companion development guide](../../companion/docs/development.md).

## Writing firmware tests

Processor tests live in `zigmkay/tests/test_processing_*.zig`, one file per
behaviour (tap-hold, permissive hold, combos, autofire, one-shot, encoders,
mouse and media keys, custom functions, ...). They feed timed matrix events
into a processor built for a small test keymap and assert the output commands.
Add a test next to the behaviour you change; known bugs are pinned in
`test_processing_known_bugs.zig`.

## CI workflows

| Workflow | Runs on | What it runs |
| --- | --- | --- |
| [Firmware tests](../../.github/workflows/firmware.yml) | Ubuntu | Core, keyboard and keycode tests with Zig 0.17.0 |
| [Offline source checks](../../.github/workflows/companion-offline-checks.yml) | Ubuntu | Companion `check`, `test` and firmware checks |
| [Native desktop contracts](../../.github/workflows/companion-desktop-checks.yml) | macOS | Native editor build and offline GUI fixtures |
| [Native practice contracts](../../.github/workflows/companion-practice-contracts.yml) | Ubuntu, macOS, Windows | Typing tutor contracts |
| [Companion application bundle](../../.github/workflows/companion-application-bundle.yml) | Linux, macOS, Windows | Assembles the application, checks the Linux runtime, packages and publishes tagged previews |

Every workflow installs exactly Zig 0.17.0. The companion workflows run when files they depend on change; see
their `paths` filters.
