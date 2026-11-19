# README screenshots

These images capture the actual native macOS application on the PR branch.
No UI mockups or generated illustrations are used in the repository README.

| File | Capture |
| --- | --- |
| [editor.png](editor.png) | Editor with a selected home-row tap/hold action, four layers, native OS keyboard palette and Build/Flash toolbar |
| [companion.png](companion.png) | Transparent companion in light appearance, explicitly labeled as an offline draft |
| [companion-dark.png](companion-dark.png) | The same native overlay in dark appearance; the README selects it for dark mode |
| [tray.png](tray.png) | macOS keyboard menu-bar icon with its native resident menu open |

Captured with exactly Zig 0.17.0, after `mise run editor:build`, using:

```sh
mise run editor -- -- --light-companion
```

This explicit preview disables keyboard monitoring and automatic preparation.
The editor restores the existing saved project for display; no project was
edited or saved, and no Build or Flash action was invoked. Existing prepared
inputs account for the enabled Build/Flash buttons. Their presence is not a
recording of a hardware transfer.

The macOS `screencapture` utility captured the editor and companion by native
window ID (`-x -o -l <id>`). Overlay PNGs preserve the window's actual transparency.
The tray image is a direct screen-region capture including the icon and open
menu. Only app content appears in these assets. Window IDs and screen positions
vary by session; discover them before recapturing. Theme changes and selecting
a key for inspection do not modify the project.

Tutor images come from the native `--native-tutor-frames 16` fixture, which
renders real UI with deterministic typed input rather than personal results.
The [typing practice guide](../../typing-practice.md) describes the screens.

Capture and conversion outputs belong in `.zig-cache/`; only selected README
assets are committed here. Do not replace a native screenshot with a visual
study or imply that offline sample data came from a connected keyboard.
