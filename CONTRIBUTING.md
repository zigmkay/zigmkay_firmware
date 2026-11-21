# Contributing to ZigMkay

Thank you for helping. ZigMkay welcomes new keyboards, firmware features and
fixes, companion improvements, documentation and bug reports. This page covers
the ground rules; the [developer documentation](docs/README.md) covers the how.

Not sure where to start, or want to discuss an idea first? Ask on the
[ZigMkay Discord](https://discord.gg/bJCZUtJD65).

## Before you start

1. Set up a checkout with Zig 0.17.0 and mise:
   [Getting started for developers](docs/development/getting-started.md).
2. Find where your change belongs:
   [Repository layout](docs/development/repository-layout.md).
3. For a new board, follow [Adding a keyboard](docs/development/adding-a-keyboard.md).
   For companion work, read the [companion development guide](companion/docs/development.md).

## Ground rules

- **Zig only.** First-party code, build logic, tools, generators and tests are
  written in Zig. Ask before introducing another language.
- **Exactly Zig 0.17.0.** CI checks the version; do not work around a
  dependency by changing compilers.
- **Pinned dependencies.** External dependencies are pinned to an immutable
  revision and hash in `build.zig.zon`.
- **Builds and tests stay offline.** No test or build step may access a
  keyboard. Flashing is always an explicit action.
- **Keep personal boards in your folder.** Board and keymap files go under
  `keyboards/my_keyboards/<you>/`.
- **English** for code, comments, diagnostics, documentation and commit
  messages.

## Pull requests

1. Make focused commits with clear messages.
2. Add or update tests for behaviour you change; processor changes get a test
   in `zigmkay/tests/`.
3. Run the checks:

   ```sh
   mise run test
   mise run check
   ```

4. Update the documentation when behaviour, tasks or supported boards change.
5. Open the pull request against `main` and describe what you tested, including
   any testing on real hardware.

CI runs the [firmware and companion workflows](docs/development/testing-and-ci.md#ci-workflows)
on every pull request.

## Reporting bugs

Open an [issue](https://github.com/zigmkay/zigmkay_firmware/issues) with the
board target, your keymap (or the relevant part), the Zig version, your host OS
and what you expected to happen.

## AI-assisted contributions

AI-assisted changes are held to the same standard as any other: a human
reviews and tests them before they are merged. See [AI_USAGE.md](AI_USAGE.md).

## License

By contributing you agree that your contribution is licensed under
`GPL-2.0-or-later`, the licence of this repository. See [LICENSE](LICENSE).
