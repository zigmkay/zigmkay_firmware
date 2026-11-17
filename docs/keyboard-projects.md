# Keyboard projects and one-way import

On first launch, choose **Create keyboard**, **Import existing keymap**, or
**Open project or collection**. A valid remembered project opens directly.
Missing, corrupt and unsupported saved data stays on disk; use the welcome
screen to choose another location or recover the original files. No keyboard
build or Flash target is exposed before selection.

Creation offers all 14 firmware selectors with friendly keyboard names, PCB
revisions and the selected firmware's default template. LK7 also offers the
existing QWERTY and EurKEY templates. Confirm the actual hardware and revision;
key count cannot identify a PCB. Each created profile gets an independent ID.
The schematic editor and tutor share catalog geometry. Display hands and thumbs
are independent of processing-side metadata; Dasbob, for example, retains its
firmware's neutral processing sides.

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

Choose **Keyboards** in the toolbar for navigation, **Add keyboard**, or **Add
existing project**. An external project can be explicitly copied into the
collection; its original files remain untouched. Existing directories are never
overwritten. Save unsaved edits before switching, or explicitly discard them.
Switching invalidates old job ownership and draft runner use.

New collections receive a `.gitignore` for local locks, caches, exports and
practice databases. Keep `workspace.zon`, child `project.zon` files, `.sources`
and `.import` in version control. The application does not initialize Git or
make personal collection commits. If another process changes the collection
manifest, reload it before retrying. If membership publication fails after a
project was saved, use **Add existing project** for that new child.

## Import

Use **Source → Keyboard → Review → Create**, then **Open editor** or **Try tutor**.

1. Select a local folder or paste a public `https://github.com/owner/repository`
   URL, optionally ending in `/tree/<ref>`. Click **Inspect source / Retry** to
   fetch or capture it. URLs are not fetched while typing. The requested ref,
   or the default `HEAD`, is resolved to an immutable commit before downloading.
   Authentication and private repositories are unsupported.
2. Select a keymap module. `src/keymap.zig` is suggested; multiple candidate
   modules appear in a selector. Click **Analyze selected module** to evaluate
   its typed data against the application's pinned firmware with Zig 0.17.0.
   Repository build scripts and callback handlers are never executed.
3. Confirm compatible hardware and PCB revision. The initial import family is
   the two pinned Keycaprio maps described in the
   [research](design/keyboard-projects-and-import.md), using Keycaprio 0.6 or 0.7.
   Other catalog boards remain available for new project creation.
4. Review layers, assignments, ordered combos, encoders, retained code and
   constrained operations. Enable **Show every assignment, combo and encoder
   action** for full typed details. Check the host-layout hint against the
   displayed active OS input source. Import does not change OS input settings.
5. Choose a profile name, collection location and unused child directory.
   **Create new project** publishes a new project only after validation and
   reopening. Cancelling before this action leaves the destination unchanged.

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

**Try tutor** asynchronously prepares a native-only processor runner, without
building a UF2. A scored run retains its chosen layout and input mode. Ordinary
OS text practices that chosen layout; it does not identify the physical keyboard
that produced the text. Firmware installation remains an explicit later action.
The companion retains single-device behavior and reports ambiguous connections.
Automatic switching between connected keyboards belongs to the follow-up PR.

## Hardware-free checks

Use exactly the compiler pinned in [`.zigversion`](../.zigversion). The focused
acceptance steps are:

```sh
zig build test-onboarding test-import test-import-processors
zig build test-catalog-defaults test-catalog-processors test-project test-session
zig build test-desktop-onboarding test-desktop-catalog -Ddesktop-dependencies=true
zig build catalog-firmware-check import-firmware-check -Dfirmware-check=true -Dcatalog-check=true -Dimport-check=true
zig build catalog-firmware-check -Dfirmware-check=true -Dcatalog-check=true -Dcatalog-defaults=true
```

Import tests use pinned local source and loopback HTTP/archive fixtures. Processor
traces cover every key/layer as taps and holds, all combos, and base-layer paired
holds in both release orders. The bundle checker accepts `imports` or `all` and
uses embedded source fixtures with the installed compiler, sources and package
closure, then prepares native tutor runners and firmware for both revisions.
Native UI galleries stay in `.zig-cache/keyboard-onboarding-gallery`.
