# Keyboard projects and one-way import

A **keyboard** is hardware: a catalog board and PCB revision. Each project is
one **layout** on it, and **My Keyboards** groups the layouts by keyboard. On
first launch, choose **Start from scratch**, **Import from Git** or **Open
folder**. A valid remembered project opens directly. Missing, corrupt and
unsupported saved data stays on disk; My Keyboards lists it as unreadable and
leaves it untouched. No keyboard build or Flash target is exposed before
selection.

**+ Keyboard** shows the catalog grouped by hardware, with PCB revision chips;
confirm the actual revision, because key count cannot identify a PCB and
builds use the wiring of that revision. Firmware selectors that share a PCB
revision are one keyboard: the Leonardo Keycaprio 0.7, for example, is
`lk7`, `keycaprio_colemak_0_7` and `keycaprio_us_intl_0_7`. **New layout**
then starts from a template, a copy of any layout, a blank Base layer or a Git
import, and previews the result on this keyboard before anything is written.
Templates are the firmware default of each selector of the revision, the
builder's own first; in place of its firmware default the LK7 offers its
built-in Rollercole, QWERTY, EurKEY draft and EurKEY Next Mac layouts, which
keep the curated LK7 board identity of earlier projects.
Each created layout gets an independent profile ID and a readable directory.

A copy from other hardware, such as a Keycaprio 0.7 layout on a 0.4, is moved
key by key: by key ID when both boards use the curated LK7 IDs, otherwise by
firmware key index. Keys and combos without a counterpart are left out and
listed, new keys stay unassigned, encoder directions are cut or padded and
callback source stays byte-exact. Transfers do not use key positions yet, so
index matching can move a key to another row; check the preview. The editor,
companion and tutor share catalog key placement. Display hands and thumbs
are independent of processing-side metadata; Dasbob, for example, retains its
firmware's neutral processing sides.

## Key placement

Keys are drawn on a schematic layout made from the board's PCB, so they read
easily and are simple to pick: every key has the same size, finger keys stand
upright one key apart and keep the column stagger of the PCB in quarter
keys. One thumb key per hand stands upright as a reference where the PCB puts
it; the others fan out from it, each turned at most 10 degrees further than
its neighbour, and labels turn with their key. The layouts are ZON
files in [`src/catalog/schematic/`](../src/catalog/schematic/), registered by
selector in [`schematic.zig`](../src/catalog/schematic.zig). A board without
one is drawn linearly, ten keys per row in firmware key-index order.

| Layout | Selectors | Drawn from |
| --- | --- | --- |
| Leonardo Keycaprio, 34 keys | `lk6`, `lk7`, `lk8`, `keycaprio_colemak_0_6`, `keycaprio_colemak_0_7`, `keycaprio_us_intl_0_7` | [Leonardo-KeycapRio](https://github.com/StephanMoeller/Leonardo-KeycapRio) PCB 0.6 at `473f41f` |
| Leonardo Keycaprio, 30 keys | `lk1`, `lk2`, `keycaprio_colemak_0_4` | Leonardo-KeycapRio PCB 0.4 at `473f41f` |
| Clacky Chan | `clacky_chan`, `clackychan_colemak` | [clacky-chan](https://github.com/StephanMoeller/clacky-chan) at `328530c`; thumbs after its photos |
| Tucky Two Times | `tuckytwotimes` | [Tucky-Two-Times](https://github.com/StephanMoeller/Tucky-Two-Times) at `29dedf9` |
| Molekula | `molekula` | [molekula](https://github.com/opendata-nuernberg/molekula) Molekula2 PCB at `78ca099` |
| Dasbob | `dasbob` | [DASBOB](https://github.com/GroooveBob/DASBOB) at `3f49dda` |

Revisions that differ by a few millimetres share one layout; what matters is
their key count. Split boards ship one PCB per half, so the other half is its
mirror. A layout lists every key once with its firmware key index, top-left
corner in key units (y down), clockwise rotation, hand, thumb group and home
row. Key indexes follow each board's keymap, which lists rows from left to
right and then the thumbs; Molekula's were matched through its PCB nets. To
add a board, take its switch positions from the PCB (KiCad or
`production/positions.csv`), straighten each hand onto the grid, and name the
source revision in the file header.

Key IDs do not depend on placement: they stay equal to the key index, and the
LK7 keeps the curated IDs in [`lk7_key_ids.zig`](../src/catalog/lk7_key_ids.zig).
Changing a layout therefore leaves existing projects and their index digest
unchanged.

## Collections

The default location is **My Keyboards** inside the application's project
storage. **Change location** selects another collection directory. Merely
opening onboarding does not create it. Completing creation writes a child
project, verifies reopening, and publishes membership last:

```text
My Keyboards/
  workspace.zon
  .gitignore
  keyboards/
    desk/
      project.zon
      .sources/
      .import/       # present for imported projects
```

`workspace.zon` is optional, version 1:

```zig
.{
    .version = 1,
    .projects = .{
        .{ .id = "desk", .directory = "keyboards/desk" },
        .{ .id = "travel", .directory = "keyboards/travel" },
    },
}
```

Entries have stable IDs and bounded relative directories inside the collection.
Duplicate or overlapping entries, escaping paths, directory links and unknown
versions are refused. Each child retains the existing single-board/profile
schema. Move the complete collection to preserve callbacks and import snapshots.
Standalone projects still open independently.

The editor head reads **Keyboard › Layout**. The keyboard opens My Keyboards;
the layout opens a menu that lists the other layouts of the same keyboard and
offers New layout, Duplicate, Rename, Export Zig source and Show in folder.
Edits save automatically shortly after each change, and Undo and Redo stay
available. Choosing another layout saves the open one first. A failed save is
reported in the head and stops automatic saving until the next edit. Switching
invalidates old job ownership and draft runner use.

My Keyboards groups every known project by hardware: collection members,
remembered profile projects and the legacy per-profile folders next to the
collection, such as `projects/eurmac`. They are listed where they are; listing
never moves or rewrites a project, and unreadable projects stay untouched. An
external project can be explicitly copied into the collection; its original
files remain untouched. Existing directories are never overwritten.

New collections receive a `.gitignore` for local locks, caches, exports and
practice databases. Keep `workspace.zon`, child `project.zon` files, `.sources`
and `.import` in version control. The application does not initialize Git or
make personal collection commits. If another process changes the collection
manifest, reload it before retrying. If membership publication fails after a
project was saved, open that folder with **Open folder**; My Keyboards then
lists it outside the collection.

## Import

**Import from Git** is one page: capture, analyze, compare, create. The new
layout opens in the editor.

1. Paste a public `https://github.com/owner/repository` URL, optionally ending
   in `/tree/<ref>`, or choose a local folder, and click **Capture source**.
   URLs are not fetched while typing. The requested ref, or the default `HEAD`,
   is resolved to an immutable commit before downloading. Authentication and
   private repositories are unsupported.
2. Select a keymap module; `src/keymap.zig` is suggested. **Analyze keymap**
   evaluates its typed data against the application's pinned firmware with Zig
   0.17.0. Repository build scripts and callback handlers are never executed.
3. The found keymap appears next to the chosen keyboard. It is drawn on the
   catalog board with its key count; keys without a counterpart on your
   keyboard are outlined dashed red, and a summary lists the differences in
   keys, layers, combos, callbacks and encoder directions. A keymap that fits
   the target (the pinned Keycaprio 0.6 and 0.7 maps, see the
   [research](design/keyboard-projects-and-import.md)) converts directly; any
   other is converted on its own board and moved like a layout from another
   revision. Check the host-layout hint against the active OS input source;
   import does not change OS input settings.
4. Name the layout and click **Create layout**. It publishes a new collection
   member only after validation and reopening. Going back before this leaves
   the destination unchanged.

The editable result preserves every layer and assignment, transparent versus
explicitly disabled keys, tap/hold/repeat/one-shot actions, modifiers, media and
mouse actions, timings, retro-tapping, ordered combos and encoder directions.
An exported `layer_names` array supplies explicit names; otherwise generated
names can be edited. Import is one-way: subsequent editor exports generate new
Zig and do not rewrite the original repository.

Callbacks retain their entry module and supported literal source closure
byte-for-byte in `.sources`. Their custom IDs and original layer indices are
preserved. Assignments and names remain editable, while index-changing
operations that would break opaque callback code are constrained. A callback
without declared custom IDs cannot be represented by schema 1 and fails with
migration guidance. Dynamic imports, C imports, non-Zig embedded assets, MCU
modules, external packages and incompatible APIs fail instead of producing a
partial conversion. Compiler failures identify a cached `analysis.log`.

Every import, including a callback-free map, retains `.import/source` and
`.import/provenance.zon`. Provenance includes source hashes, the source manifest
and firmware pins, repository/ref/commit when available, selected target,
processing contract and converter version. Git history, repository build
scripts, firmware engines, scanning/GPIO implementations and UF2s are not
project inputs. Exports use the application's existing immutable firmware pin.
Downloads, decompression, archive entries, captured files and subprocess output
are bounded. Archive links and escaping paths are rejected. Network failures
retain the wizard for retry or local-folder import. Git and a separately
installed Zig are unnecessary in bundled applications.

**Try it out** in the editor prepares a native-only processor runner, without
building a UF2. A scored run retains its chosen layout and input mode. Ordinary
OS text practices that chosen layout; it does not identify the physical keyboard
that produced the text. Firmware installation remains an explicit later action.
The companion retains single-device behavior and reports ambiguous connections.
Automatic switching between connected keyboards belongs to the follow-up PR.

## Hardware-free checks

Use exactly the compiler pinned in [`.zigversion`](../.zigversion). The focused
acceptance checks are:

```sh
zig build test -Dtest-filter=import -Dtest-filter=catalog -Dtest-filter=onboarding
zig build test-desktop -Ddesktop
zig build check-firmware check-firmware-defaults -Dfirmware
```

Import tests use pinned local source and loopback HTTP/archive fixtures. Processor
traces cover every key/layer as taps and holds, all combos, and base-layer paired
holds in both release orders. The bundle checker accepts `imports` or `all` and
uses embedded source fixtures with the installed compiler, sources and package
closure, then prepares native tutor runners and firmware for both revisions.
Native UI galleries stay in `.zig-cache/keyboard-onboarding-gallery`.
