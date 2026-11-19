<div align="center">

# Zigmkay Companion

**Make your keyboard yours. Learn it as you go.**

A native visual editor, an on-demand keyboard companion, and a typing tutor
for programmable keyboards running [Zigmkay firmware](https://github.com/zigmkay/zigmkay_firmware).
Written in Zig.

[Get started](#get-started-with-mise) · [Companion](#your-layout-one-hotkey-away) · [Editor](#program-your-keyboard-visually) · [Tutor](#try-your-layout-with-the-typing-tutor) · [Development](#development)

</div>

![Zigmkay editor showing a split keyboard, four layers, a tap/hold key inspector, and Build and Flash controls](docs/screenshots/overview/editor.png)

Choose what a key does when tapped or held, see the layout while you work,
and try it out in a typing test. The editor and companion share a
resident desktop application, accessible from its little keyboard tray icon.

*All images below are real native macOS application captures. The companion
is shown offline; tutor exercises use deterministic sample input.
[Capture details](docs/screenshots/overview/README.md).*

## Get started with mise

Run Zigmkay from source with [mise](https://mise.jdx.dev/getting-started), or use
an unsigned executable preview once published. The [preview release workflow](docs/preview-releases.md)
packages macOS DMGs, a portable Windows EXE and a Linux AppImage with Zig and the
offline runtime included. Native Windows and Linux release acceptance runs in CI;
device acceptance remains separate. See [compatibility status](docs/compatibility.md).

Install [mise](https://mise.jdx.dev/installing-mise.html) and Git, then:

```sh
git clone https://github.com/conlorz/zigmkay_companion.git
cd zigmkay_companion
mise trust
mise install
mise exec -- zig version    # must print 0.17.0
mise run editor
```

Mise selects exactly **Zig 0.17.0** and assembles the complete application.
The developer build may download pinned dependencies and compile tools. The
assembled application bundles its compiler, firmware sources and Flash tools;
it runs and builds offline without this checkout. On macOS, compiling the
application from source needs Xcode Command Line Tools (`xcode-select --install`).

For the companion in the background, start this instead:

```sh
mise run companion
```

It starts with its windows hidden. Use the tray icon to open the editor or show
the companion. Normal startup automatically monitors compatible keyboards.
Firmware transfer starts only when you explicitly choose **Flash**.

## Your layout, one hotkey away

Forgot where a symbol lives? Bring up a transparent, passive overlay of your
keyboard. With a verified connection, it follows the running profile's layers,
modifiers and pressed keys. It stays out of pointer interaction so you can keep
working in your current application.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/overview/companion-dark.png">
  <img src="docs/screenshots/overview/companion.png" alt="Transparent Zigmkay companion overlay showing the split layout, home-row modifiers and layer holds" width="880">
</picture>

Program a key's tap or hold action as **Show / hide companion** (reserved signal
`255`). In the default mode, a quick tap toggles the overlay; a longer press
shows it while held and restores its previous visibility on release. Dedicated
hold-only and toggle-only modes are available for development and testing.

The overlay uses the verified running layout. Losing the connection clears its
visibility; editor changes remain a draft until built and flashed. The screenshot
above shows the explicitly labeled offline draft view.

## Program your keyboard visually

The physical keyboard, layer list and OS keyboard palette live in one window.
Every key has two halves: click the upper half to choose what it types and the
lower half to choose what it does while held. Press the key on your computer's
keyboard, search for an action, or drag an OS keyboard key onto either half.
Changes apply at once, with undo/redo available afterward.

- **Tap, hold and autofire without modes:** the key type follows from what you
  set; tune tapping terms and autofire delays, and combine key chords with
  left/right modifiers.
- **Layers and one-shots:** add, duplicate and name layers, use layer holds,
  and distinguish inherited assignments from keys that do nothing.
- **More than letters:** assign media controls, mouse actions, companion signals,
  combos and encoder actions.
- **Your own Zig:** preserve callback source snapshots, attach external source,
  and refresh it explicitly when it changes.
- **Projects and profiles:** save and reopen projects, switch profiles, and
  export source for firmware builds. The catalog contains 14 board entries;
  individual hardware acceptance is tracked separately.

### Build and Flash from the same window

**Build**, **Flash** and optional **Auto-build** sit in the editor toolbar shown
above. The installed application includes everything needed to build firmware
and run the tutor offline. Startup does not download or prepare packages.

Click **Flash** to build the current project if needed, request BOOTSEL, transfer
the verified UF2, and wait for reconnection. If BOOTSEL is not discovered, the
editor prompts for manual entry. Progress stays in the message bar; errors open
details. Auto-build compiles edits without starting a transfer.

[Build and Flash details](docs/development.md#editor-build-and-flash) explain
bundling, supported source bindings and current limits.

## A little tray icon, always within reach

Close the editor window and keep the resident application available. The tray
menu opens the editor, shows or hides the companion, reports device status,
adjusts editor zoom, and lets you explicitly bind a saved editor project to the
live companion. **Quit Zigmkay** exits the resident application.

<p align="center">
  <img src="docs/screenshots/overview/tray.png" alt="Native macOS keyboard tray icon and Zigmkay menu with Open Editor, Show Companion, device status, zoom and Quit" width="360">
</p>

## Try your layout with the typing tutor

Choose **Open tutor** in the editor. Before a test, the tutor shows your
keyboard's layout and highlights each key you press, so you can check a freshly
flashed layout key by key. Start an English typing test of 1, 3, 5 or 10
sentences, or one of three short Zig lessons, and see your words per minute and
accuracy. The tutor saves nothing between sessions.

![Typing tutor highlighting the next character and the key to tap](docs/screenshots/typing-practice/tutor.png)

The [typing practice guide](docs/typing-practice.md) covers the controls, the
keyboard guide and input sources. Text input measures output and timing; it
cannot prove which finger or physical route you used.

## Development

Use this checkout and the pinned compiler; no private plans or sibling
repositories are required. Start with the offline checks:

```sh
mise run check
mise run test
```

The [development guide](docs/development.md) covers the package map, native GUI
builds, explicit offline startup, test tasks, application assembly and further
design/implementation docs. Builds, tests and explicit offline startup do not
access keyboards. See [compatibility status](docs/compatibility.md) for the
remaining platform and hardware acceptance work.

## License

Zigmkay companion is free software: you can redistribute it and/or modify it
under the terms of the **GNU General Public License as published by the Free
Software Foundation, either version 2 of the License, or (at your option) any
later version** (`GPL-2.0-or-later`). See [LICENSE](LICENSE) for the version 2
text.

The application compiles in the zigmkay firmware, which is licensed under GPL
version 2 only. Builds that include it are therefore distributed under GPL
version 2. Imported dependencies retain their own license notices; see
[NOTICE](NOTICE).
