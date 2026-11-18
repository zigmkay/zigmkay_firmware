# Editor design reference

Date: 2026-11-18. This is the reference the native editor and companion are
compared against. The mockups in [editor/](editor/) are hand-written SVG
studies with illustrative data, not DVUI screenshots. Each has a PNG render
next to it. The tutor has its own [design reference](typing-practice-packages.md).

The goal is an editor a new user understands without documentation. Keys show
symbols rather than words, every layer has one color that appears wherever the
layer does, and the top bar follows the order of work: open, build, flash.

## Screens

| # | Screen | Mockup | Native code |
|---|---|---|---|
| 1 | Editor, keys view, dark | [01-editor-dark](editor/01-editor-dark.svg) | `editor_frame.zig`, `toolbar_ui.zig`, `layer_ui.zig`, `keyboard_ui.zig`, `host_palette_ui.zig`, `inspector_ui.zig` |
| 2 | Editor, keys view, light | [02-editor-light](editor/02-editor-light.svg) | same |
| 3 | Keycap anatomy, symbols and layer palette | [03-keycaps](editor/03-keycaps.svg) | `labels.zig`, `keycap_symbols.zig`, `icon_resources.zig`, `ui.zig` |
| 4 | Companion overlay, dark and light | [04-companion](editor/04-companion.svg) | `companion_ui.zig` |
| 5 | Combos | [05-combos](editor/05-combos.svg) | `combo_ui.zig` |
| 6 | Encoders | [06-encoders](editor/06-encoders.svg) | `encoder_ui.zig` |
| 7 | Callbacks | [07-callbacks](editor/07-callbacks.svg) | `callback_ui.zig` |
| 8 | Open / Export | [08-open-export](editor/08-open-export.svg) | `paths_ui.zig` |
| 9 | Build and Flash activity | [09-build-flash](editor/09-build-flash.svg) | `toolbar_ui.zig`, `flash_ui.zig` |
| 10 | My Keyboards (superseded by 13) | [10-keyboards](editor/10-keyboards.svg) | `onboarding_ui.zig` |
| 11 | Editor head: Keyboard › Layout breadcrumb and layout menu | [11-editor-head](editor/11-editor-head.svg) | `toolbar_ui.zig`, `layout_menu.zig` |
| 12 | Export Zig source | [12-export](editor/12-export.svg) | `paths_ui.zig` |
| 13 | My Keyboards: hardware and its layouts | [13-my-keyboards](editor/13-my-keyboards.svg) | `onboarding_ui.zig`, `keyboards_ui.zig`, `library.zig` |
| 14 | First launch, no keyboards yet | [14-first-launch](editor/14-first-launch.svg) | `keyboards_ui.zig`, `keyboard_preview.zig` |
| 15 | New layout with preview | [15-new-layout](editor/15-new-layout.svg) | `new_layout_ui.zig`, `new_layout.zig`, `layout_transfer.zig` |
| 16 | Import from Git with comparison | [16-import-compare](editor/16-import-compare.svg) | `import_ui.zig`, `import_compare.zig`, `layout_transfer.zig` |
| 17 | Add keyboard from the catalog | [17-add-keyboard](editor/17-add-keyboard.svg) | `catalog_ui.zig` |

## Canvas and grid

The editor draws on a fixed 1536 × 1056 design canvas that is scaled to fit
the window (`geometry.fitScale`). All coordinates below are canvas units.

- Outer margin 16, gap between panels 12, panel corner radius 12, panel
  padding 20.
- Top bar: 0–64. Status row: 64–100, separated by a 1-unit border line.
- Columns from y = 112 to 1044: layers 16–256 (240 wide), center 268–1068
  (800), inspector 1080–1520 (440).
- Center column: keyboard panel 112–640 (528 high), OS keyboard 652–1044 (392).
  Keys on the canvas grow until the geometry fills the panel width.
- Layers column: layer list on top; the Try it out and Callbacks cards sit at
  the bottom of the same column (87 high each), so the center column belongs
  to the keyboard.
- Content inside a panel is centered on both axes; the keyboard canvas uses
  the full panel width minus padding, and keys keep their geometry's aspect.

## Tokens

| Token | Dark | Light | Use |
|---|---|---|---|
| bg | `#15171B` | `#EEF0F3` | Window background |
| panel | `#1E2126` | `#FFFFFF` | Panels, cards |
| control | `#2A2E35` | `#F2F4F7` | Buttons, inputs, list rows |
| border | `#383D46` | `#D8DDE4` | Panel and control borders |
| keycap | `#272B32` | `#F8F9FB` | Keycap faces |
| text | `#EDEFF2` | `#1F2329` | Primary text and legends |
| muted | `#9AA3B0` | `#667180` | Secondary text, hold legends |
| accent | `#3B82F6` | `#2563EB` | Primary actions, selection outside the keyboard |
| danger | `#F06B73` | `#DC2626` | Failures and destructive actions |

Text uses Inter (embedded): regular for body text, SemiBold for headings.
Sizes: panel title 19, body 14, secondary 12, keycap legend 22 (fitted).

### Layer palette

Each layer position has one color. It appears as the key borders on the
canvas, the layer row chip, the inspector preview border, layer-hold
indicators (`▤2`), the companion's key borders and title dot, and the fill of
pressed keys in the companion.

| Layer | Dark | Light |
|---|---|---|
| 0 (base) | `#EF4444` red | `#DC2626` |
| 1 | `#3B82F6` blue | `#2563EB` |
| 2 | `#F59E0B` amber | `#D97706` |
| 3 | `#22C55E` green | `#16A34A` |
| 4 | `#A855F7` purple | `#9333EA` |
| 5 | `#14B8A6` teal | `#0D9488` |
| 6 | `#EC4899` pink | `#DB2777` |
| 7 | `#A16207` brown | `#854D0E` |
| 8 | `#94A3B8` slate | `#475569` |

Tests keep borders at about 3:1 contrast on keycaps and panels and keep any
two layer colors at least CIE76 ΔE 30 apart.

## Keycaps

- Face: `keycap`; border 1.5 in the edited layer's color mixed 65 % into the
  face. Corner radius 12 % of the key width.
- Selected: border 2.5 in the full layer color and the face tinted 22 % toward
  it. Focus outside the canvas uses `accent`.
- Main legend (tap) centered in the upper part, 22 units before fitting. The
  hold legend sits below in `muted` at 70 % size. There is no "Hold" word on
  the canvas: the position says it; the inspector spells it out.
- Transparent keys draw the legend they fall through to, in `muted`, on a
  `panel` face with a faint border.
- Keyboard symbols are icons, never font glyphs: ⌫ ⌦ ⎋ ⇥ ⇪ ↩ ␣ ⇧ ⌃ ⌥ ⌘,
  Windows, arrows, ↖ ↘ ⇞ ⇟, print screen, pause, menu, power, media, mouse
  buttons and wheel, and the companion signals. Insert and Scroll Lock stay
  `ins` and `scr`. Letters stay uppercase; other layout output is text.
- Layer holds draw the layers icon and the layer number in that layer's color.
- Modifier order follows the host: `⌃⌥⇧⌘` on macOS, `Ctrl+⇧+Alt+⊞` elsewhere.

## Editor (screens 1 and 2)

Top bar, left to right: the Zigmkay wordmark; the breadcrumb
**Keyboard › Layout ▾** (the keyboard opens My Keyboards, the layout opens the
layout menu of screen 11); the save state ("Saved", "Edited", "Saving…" or
"Save failed"); then the work flow **Build › Flash**, filled with `accent`;
then Undo, Redo and the theme toggle. Saving is automatic, so there is no
Save button. Export Zig source moved into the layout menu (screen 12).

Status row: status dot, current message, a hint when building, the Auto-build
switch and Details on the right.

Layers: one 48-high row per layer with a colored number badge and the name.
The selected row is tinted with its color and outlined in it. Duplicate and
delete appear as icon buttons on the row. Renaming happens in place below the
list for the selected layer.

Keyboard panel: the edited layer as a chip in its color, the board name in
`muted`, and a Keys / Combos / Encoders segmented control on the right. The
geometry fidelity note moves to a small muted line at the bottom.

OS keyboard: a compact host keyboard whose keys draw the same symbols as the
canvas; Shift and Option toggles on the right of its header.

Inspector: title with Copy and Paste; a keycap preview in the layer color
next to the spelled-out action ("⌫ Backspace", "Hold: L ⇧ Shift"); the key id,
layer and selection count in `muted`; the assignment state; then the mode,
Tap and Hold cards, timing, advanced fields and the search, and the
Unassign / Inherit / Cancel / Apply footer.

## Companion (screen 4)

A transparent, borderless overlay. Every key has an opaque face (`keycap` at
93 % alpha) and a 2-unit border in the shown layer's color, so text behind the
overlay never competes with legends. Pressed keys fill with the layer color
and draw white legends. A pill at the top left shows a dot in the layer color,
the layer name and the label source ("Verified running profile" or "Draft ·
device offline"). Tutor guidance keeps its amber target and cyan hold fills.

## Secondary screens (5–10)

Combos, Encoders, Callbacks and Open / Export open as centered modal drawers
on a dimmed editor, 900 wide with 28 padding, with a title, one sentence of
explanation, the content and a footer with the primary action on the right.
Encoder actions are labeled clockwise or counter-clockwise only where the
board definition says so; other slots read "Action slot N". Build and Flash
activity opens from Details below the status row. My Keyboards replaces the
editor with a full-window collection view.

## Keyboards, layouts and onboarding (decided 2026-11-18)

Two flows were studied ([option A](editor/flow/option-a-keyboard-layouts.png),
[option B](editor/flow/option-b-layout-first.png)). **Option A is chosen**,
plus the import comparison step (B3) from option B. Screens 11 to 17 draw the
result in the editor style; screen 10 is superseded.

- Abstraction: a **keyboard** is hardware (catalog board and PCB revision,
  with its geometry); it holds several **layouts**. Today each collection
  project is one board plus one layout; the home screen groups projects by
  board and revision, so the project schema does not need to change.
- Home screen "My Keyboards" (A1): hardware list on the left with geometry
  thumbnails, the selected keyboard's layouts as cards with a base-layer
  preview on the right, a badge for the layout running on the connected
  keyboard, "+ New layout", "+ Keyboard" (catalog) and "Import from Git".
  On first launch, with no keyboards, the three entry cards of B1 (start from
  scratch, import from Git, open folder) fill the empty state.
- New layout (A2): one page, not a wizard. Start from a template, a duplicate
  of an existing layout, blank, or Git import; a live preview shows the result
  on exactly this keyboard with key, layer and combo counts.
- Import (B3): after analysis, the found keymap and the target keyboard are
  shown side by side. Keys without a counterpart are outlined dashed red, and a
  summary lists differences in keys, layers, combos, callbacks and encoders
  before anything is created. This matters for moving layouts between
  Leonardo Keycaprio revisions (for example 0.4 → 0.7, which differ in keys).
- Editor head (A3): a breadcrumb **Keyboard › Layout ▾** replaces the
  Keyboards button, the profile dropdown and Open / Export. The layout menu
  switches layouts and offers New, Duplicate, Rename, Export Zig source and
  Show in folder. Build › Flash stays; saving is automatic with undo.
- The legacy profile dropdown (four built-in LK7 templates with per-profile
  project folders) becomes "New layout from template".
- Key placement (2026-11-18): a board with a spatial layout in
  `src/catalog/spatial/` is drawn at its measured switch positions, turned
  keys included; Molekula uses the Molekula2 PCB placement. `lk7` keeps the
  hand-written grid in `src/catalog/lk7_physical_layout.zig`. Every other
  board is drawn linearly, ten keys per row in key-index order, without
  invented splits or stagger. See
  [Spatial layouts](../keyboard-projects.md#spatial-layouts).

## Status

Implemented (2026-11-18): symbol icons on every keycap, Inter, the layer
palette with colored key borders, transparent-key fall-through, the companion
faces and title pill, the top bar work flow, the status row, the layers column
with the Try it out and Callbacks cards, the keyboard panel header and
segmented control, the enlarged OS keyboard and the inspector header with its
keycap preview and spelled-out action.

Implemented (2026-11-18, screens 11–17): the Keyboard › Layout breadcrumb with
its layout menu and automatic saving, the Export Zig source sheet, My
Keyboards with hardware and layout cards, the first-launch entry cards, the
catalog page, New layout with its preview, and the Git import comparison.

Open: the inspector body (Behaviour label, Tap and Hold cards, category chips
and result rows as drawn) and the secondary screens 5–7 and 9 still use their
earlier layout. Copying an outside project into the collection has no control
on My Keyboards yet. Boards without a spatial layout are drawn linearly, and
revision transfers still match by key index. Compare native
screenshots against these mockups when changing them:
`--offline-status-frames 24` renders editor scenes (scene 2 shows the export
sheet, scene 3 the layout menu) and `--offline-onboarding-frames 24` renders
My Keyboards, the catalog, New layout and the import comparison offscreen to
`.zig-cache/` without capturing the desktop.
