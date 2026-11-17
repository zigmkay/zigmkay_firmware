# Keyboard onboarding, collections and keymap import

Research date: 2026-10-16. This document proposes implementation work; it does
not describe an onboarding or import UI that has already shipped. A cache-only
Zig conversion experiment verified the two requested source repositories.

Implementation note: this research is retained as historical evidence. See the
[keyboard projects guide](../keyboard-projects.md) for the implemented onboarding,
collections and import flow. Automatic companion switching remains separate.

## Recommended direction

Keep one board/profile per existing `project.zon`, and add a **keyboard
collection** containing several of those projects. The user can keep LK7,
Molekula and additional profiles in one Git repository while the editor edits
one project at a time. The companion selects an immutable running layout from
the device that sends its activation signal. A tutor run explicitly selects
and retains its keyboard/layout context.

Implement source import as a one-way conversion into editable project data,
with original callback code retained as a source snapshot. Subsequent editor
exports generate fresh Zig. There is no requirement to rewrite the original
repository or reconstruct its macros, formatting or file organization.

This reuses the existing model, source bundles, export contracts and native
processor. The substantial new work is onboarding, useful physical geometry,
collections, import tooling and discovery of multiple device identities.

## What exists today

- [Startup](../../apps/desktop/main.zig) creates the curated LK7 QWERTY template
  before trying the remembered project. Its default project directory is
  `qwerty`. The toolbar displays a keyboard name; it does not offer a board
  picker. Only the curated LK7 identity gets the four built-in profile choices.
- [The catalog](../../packages/catalog/src/root.zig) already consumes all 14
  selected firmware entries. [The adapter](../../packages/firmware-adapter/src/catalog_project.zig)
  creates actual default projects, preserves callback sources and resolves
  saved documents to their board contracts. Other-board opening already has
  support in [project file operations](../../packages/desktop/src/project_files.zig).
- [Schema 1](../../packages/project/src/root.zig) has one `board_id`,
  `profile_id`, key index order, layer list, combo list and encoder action list
  per document. [The model](../../packages/desktop/src/model.zig) owns arbitrary
  validated board contracts. Changing keyboard types does not require
  generalizing the action model.
- Only LK7 has curated schematic geometry. The other 13 catalog entries use a
  ten-column index grid with neutral hand metadata. Editing is possible, but
  the grid is a poor keyboard reference and tutor diagram.
- [Profile associations](../../packages/desktop/src/profile_projects.zig) are
  keyed by board/profile and retain absolute local project paths. They are
  preferences, not a portable collection or a history of built layouts.
- Startup freezes one `running_model`, one identity, one label cache and one
  live driver. Editor changes deliberately do not alter that running layout.
- [Discovery](../../packages/session/src/live_adapter.zig) and
  [native HID](../../packages/platform/src/native_hid.zig) reject multiple
  matching devices unless an exact path is selected. The application currently
  supplies no path. A project selector alone cannot solve two connected boards.
- [The session reducer](../../packages/session/src/root.zig) normally needs an
  expected complete identity before the handshake. The bootloader-only
  discovery exception must remain separate from companion verification.
- Tutor labels and geometry already come from a selected project or the single
  verified running project. The application hashes board identity and behavior
  separately from translated character mappings and stops scoring when that
  context changes. Those protections should be retained.

## Firmware inventory and hardware identity

The companion pins firmware commit
`e122f7502df4ad58e831f0b37439085774b670cb` and its package hash in
[build.zig.zon](../../build.zig.zon). The selected PR-head provides the portable
[board inventory](https://github.com/EuroZig/zigmkay_firmware/blob/e122f7502df4ad58e831f0b37439085774b670cb/keyboards/boards.zig)
and [processing descriptors](https://github.com/EuroZig/zigmkay_firmware/blob/e122f7502df4ad58e831f0b37439085774b670cb/keyboards/processing_descriptors.zig)
used below. Firmware `main`, inspected at
`62707ccd47bd601b4d60212c275842db23ac29ce`, has the same 14 names in its
[keyboard build list](https://github.com/EuroZig/zigmkay_firmware/blob/62707ccd47bd601b4d60212c275842db23ac29ce/keyboards/build.zig),
but not the PR-head's extracted inventory API. Keep the existing immutable pin.

| Firmware selectors | Logical keys | Encoder action slots |
| --- | ---: | ---: |
| `clacky_chan`, `clackychan_colemak` | 30 | 0 |
| `keycaprio_colemak_0_4` | 30 | 0 |
| `keycaprio_colemak_0_6` | 34 | 0 |
| `keycaprio_colemak_0_7`, `keycaprio_us_intl_0_7` | 34 | 0 |
| `lk1`, `lk2` | 30 | 0 |
| `lk6`, `lk7` | 34 | 0 |
| `encoder_demo` | 1 | 2 |
| `dasbob` | 36 | 0 |
| `tuckytwotimes` | 30 | 4 |
| `molekula` | 38 | 0 |

Encoder action slots represent directions, not additional physical keys. Yak is
an unselected source example. Molekula's selected configuration has no active
encoder slots; old comments about 40 keys or an encoder are not its current
processing contract. The descriptor says 38 keys.

The 14 selectors are combinations of board roots and default profiles, rather
than 14 distinct physical keyboard designs. Add host catalog metadata for a
display family, PCB revision, geometry and compatible default templates.
Initially map every existing selector explicitly. Do not merge LK7 and another
Keycaprio selector merely because both have 34 keys; GPIO mapping and key order
must be checked independently.

Keep legacy wire/document IDs stable. Curated LK7 uses a literal board ID and
`lk7_*` key IDs, while catalog projects use a selector-derived board ID and
`key-*` IDs. The resolver already supports both. UI grouping must not silently
rewrite existing projects, build identities or saved practice context. A future
identity consolidation needs an explicit migration and a rebuilt firmware.

Processing sides also differ from display hands: a thumb can be neutral for
processing and still be a left-hand thumb in the tutor. Dasbob's processor sides
are all neutral because its entrypoint omitted side ownership. Never fill in
processing sides from a drawing.

## Part 1: onboard every selected keyboard

On first use, show **Create keyboard**, **Open project or collection**, and
**Import existing keymap**. A remembered valid project should reopen directly.
Missing, corrupt or future-version projects must remain untouched; offer a
recovery choice instead of overwriting them with a template.

Creation chooses a keyboard family, PCB revision, starting template and save
location. Populate choices from the selected firmware catalog and host display
metadata, then call `OwnedBoard.init` and `createDefault`. Keep an explicit
minimal template option distinct from an actual firmware default. Give each
new personal profile a valid independent ID; copying a template's profile ID
for every project would collide in the current association registry.

All 14 selectors should be creatable, saveable, reopenable, editable,
exportable and buildable. Show capability distinctions accurately: successful
offline compilation is separate from hardware acceptance. Reuse the existing
guarded project replacement path for dirty edits and pending inspector changes.
Board selection must rebuild board-dependent caches, draft runner bindings and
build plans, and reject stale worker completions from the previous project.

Add curated schematic geometry in logical index order for each distinct layout
family. Prioritize Molekula's 38-key shape and the friends' 34-key Keycaprio,
then cover the remaining roots. Include hands, thumbs, home rows and encoder
placement where supported. Verify index/ID bijections and matching labels in
editor, companion and tutor. Improving coordinates must preserve existing IDs
and the logical processing digest. Keep the indexed fallback available for
future descriptors, with its limitations visible.

### One repository for several keyboards

Use a versioned collection manifest referencing normal project directories:

```text
my-keyboards/
  workspace.zon
  README.md
  .gitignore
  keyboards/
    lk7-main/
      project.zon
      .sources/<digest>/...
    molekula-main/
      project.zon
      .sources/<digest>/...
    lk7-gaming/
      project.zon
      .sources/<digest>/...
```

Proposed manifest shape, not a currently supported file format:

```zig
.{
    .version = 1,
    .projects = .{
        .{ .id = "desk-lk7", .directory = "keyboards/lk7-main" },
        .{ .id = "travel-molekula", .directory = "keyboards/molekula-main" },
        .{ .id = "lk7-gaming", .directory = "keyboards/lk7-gaming" },
    },
}
```

The child document retains board/profile facts. Collection entry IDs identify
membership; firmware profile IDs identify behavior on the wire. Use relative,
bounded paths contained within the collection, reject duplicate membership and
unsupported versions, and leave standalone projects fully usable. Offer **Add
existing project** without relocating or rewriting it automatically. Adding a
project outside the collection requires an explicit portable copy if it is to
travel with the repository.

Commit `workspace.zon`, each `project.zon`, all referenced `.sources` files and
import provenance. Keep locks, absolute startup/device preferences, caches,
build artifacts and practice databases local by default. In particular, do not
ignore `.sources`: they contain the callbacks needed to reproduce the project.
Use the application's pinned compiler/firmware build environment and record its
revision and hash in reproducibility metadata; do not make firmware depend on
the editor or a particular user's collection. A dedicated collection build CLI
can later provide headless builds without copying the application source into
personal repositories.

The editor groups collection entries by keyboard and profile, editing one at a
time. Builds and Flash always capture the selected child and target, never a
global collection-wide board value. Shared callback source can be added later
as explicit refresh inputs; each saved child should retain an immutable source
snapshot so another keyboard's edits cannot change its behavior unexpectedly.

### Route the companion by the device that pressed its button

Introduce a session manager with one connection per matching HID path. Every
connection owns its session reducer, nonce stream, pressed state, labels and
gesture state. Carry a runtime device ID and connection generation with events;
the existing common VID/PID is not a device or board identity. HID paths are
connection locators and must not become portable project IDs. Retain USB serial
metadata when available, while allowing devices without unique serials.

Discovery must collect a bounded identity response before choosing an expected
layout. Resolve the complete board ID, profile ID, behavior digest and dimensions
against locally retained snapshots, then establish a normal verified session.
The identity is already present in the current protocol, so a new wire format
does not appear necessary for this routing. This is a design inference; it
still requires a dedicated discovery state and tests. Do not enable the
bootloader-only relaxed identity mode for overlay display.

Retain immutable snapshots for successful builds and explicit saved-project
bindings, including their source bytes. Index them by the complete identity.
The existing board/profile-to-directory preference cannot resolve an older
running digest once its project has been edited and saved. Unknown firmware
should show an association/mismatch state; it must not display a convenient
draft with the same board name or key count. Older third-party firmware may
need a rebuild before it can provide a canonical companion identity.

Use one overlay with explicit ownership:

- A companion press from Molekula selects Molekula's verified snapshot and state;
  a press from LK7 selects LK7's. Opening either project for editing is independent.
- A quick tap switches to that keyboard and shows its overlay. A subsequent tap
  on the same displayed keyboard hides it.
- A long hold temporarily shows its keyboard and restores the previous visible
  keyboard on release, provided no later activation superseded that hold.
- Releases and delayed reports from an older owner cannot hide or replace the
  current owner's overlay. Tag gestures with ownership generations.
- Disconnect or lost coherence clears that connection's held state. If it owns
  the overlay, hide it. Other healthy sessions continue monitoring independently.

Test interleaved presses/releases, simultaneous holds, rapid taps, stale packets,
same-model duplicate devices, reconnection with a changed path, digest changes,
and an unknown device while another remains live. Explicit Flash must also bind
to a selected connection; automatic monitoring must never initiate a transfer.

### Tutor selection

Offer the same keyboard/profile choices as the editor. Capture the selected
snapshot, translation source and input mode when a run starts. A companion press
on another keyboard may change the free overlay, but it must not silently switch
the tutor's scored context. Pause and restart when the chosen layout actually
changes, retaining the existing behavior/mapping cohort separation.

Ordinary OS text input does not identify the originating physical keyboard.
Describe that mode as practicing a selected layout, rather than claiming all
text came from that device. Verified device events can supply that connection's
highlights. Draft simulation remains a way to test an unflashed Molekula map.
German and US-International maps need the matching host input layout; dead keys,
AltGr, composition and custom callbacks must retain the existing limits on
provable tutor routes.

## Part 2: import the two existing user keymaps

The inspected source snapshots are:

- [US-International source](https://github.com/zigmkay/zigmkay_keycaprio_us_intl/blob/9a3965c07cac85722817ef98da4f56335781a412/src/keymap.zig),
  repository commit `9a3965c07cac85722817ef98da4f56335781a412`.
- [German source](https://github.com/TrackingNina/ninikey_de/blob/9d7aff3b3b63dce75efcb670b606227b9dc3a1a8/src/keymap.zig),
  repository commit `9d7aff3b3b63dce75efcb670b606227b9dc3a1a8`.

| Property | US-International | Ninikey German |
| --- | --- | --- |
| Logical keys / layers | 34 / 6 | 34 / 6 |
| Active two-key combos | 22 | 23 |
| Host layout | US-International | German QWERTZ |
| Callback source closure | `src/keymap.zig` | `src/keymap.zig` |
| Custom IDs referenced by actions | 3, 6, 10, 25, 27 | 3, 6, 10, 25, 27 |
| PCB choices in source build | Keycaprio 0.6 or 0.7 | Keycaprio 0.6 or 0.7 |

Their manifests pin the same older firmware revision
`c060ef3ab2dcc2c44724c1861a972407577fdd8c` and MicroZig 0.17.12. See the
[US manifest](https://github.com/zigmkay/zigmkay_keycaprio_us_intl/blob/9a3965c07cac85722817ef98da4f56335781a412/build.zig.zon)
and [German manifest](https://github.com/TrackingNina/ninikey_de/blob/9d7aff3b3b63dce75efcb670b606227b9dc3a1a8/build.zig.zon).
The research probe compiled their unchanged keymap modules against the
companion's selected newer firmware, using exactly Zig 0.17.0.

Both maps use callbacks for a derived layer, held shortcuts and a custom output
sequence. Preserve the entire entry module to retain its constants and helpers.
The custom-ID list includes values stored in holds, not just explicit signal
combos. Lock the original layer index order while opaque callbacks are attached.
Neither importing key definitions alone nor replacing them with the catalog's
similarly named template preserves personal behavior.

The sources select PCB revision in their
[firmware entrypoint](https://github.com/zigmkay/zigmkay_keycaprio_us_intl/blob/9a3965c07cac85722817ef98da4f56335781a412/src/main.zig).
Require the user's actual revision during import. The cache probe used the
existing `keycaprio_colemak_0_7` contract for both maps: its selector determines
the hardware entrypoint, not a requirement that imported actions use Colemak.
Production onboarding should label this as Keycaprio 0.7 hardware and offer
templates separately. Check the 0.6 mapping independently before selecting it.
Their existing entrypoints do not supply `companion_identity`. Importing a
project therefore does not establish a verified connection to currently flashed
firmware. A later explicit build and Flash can install the converted map with
the application's canonical identity support; offline tutor testing can happen
before that hardware step.

### Conversion pipeline

1. **Select source and target.** Start with an explicitly selected local folder
   or unpacked source bundle. For these repositories, select `src/keymap.zig`,
   the PCB revision, profile name and a new destination directory. Remote URL
   fetching can follow later, recording an immutable commit and content hashes.
2. **Inspect without running upstream build scripts.** Read the manifest and
   capture the literal source-import closure with
   [sources.zig](../../packages/project/src/sources.zig). Display source paths,
   firmware version and unsupported imports. Keep the original repository intact.
3. **Evaluate a supported module contract.** Use an application-owned Zig 0.17.0
   helper that imports only the captured keymap module and known modules such as
   `zigmkay` and `zkeycodes`. Its public contract is dimensions/keymap plus
   optional combos, sides, encoder actions and `custom_functions`. Compiler
   evaluation handles macros and aliases; a regex parser would lose their
   meaning. This compilation is an explicit import action, distinct from passive
   folder inspection, and should be bounded in time, resources and input/output.
4. **Lift typed values.** Reuse
   [adapter.zig](../../packages/project/src/adapter.zig), convert layer indices
   to stable layer IDs, preserve transparent `null` versus explicit `.none`,
   combo ordering, timings, modifier nullability, post-tap behavior and encoder
   slots. Validate key counts, index order and sides against the chosen board;
   dimensions alone cannot establish hardware compatibility.
5. **Preserve callbacks.** Retain byte-exact source bundles and attach
   `custom_functions` through the existing callback ABI. Collect custom IDs from
   taps, holds, one-shots, repeats, combos and encoders. Use conservative layer
   constraints for opaque source. Store source revision, firmware pins, target
   mapping and diagnostics as import provenance outside the firmware identity.
6. **Preview and save.** Show imported counts, host-layout requirements, retained
   code, locked operations and any unsupported behavior. Write only to a new
   selected project, then save, reopen, export and compile a native runner.
   Report unsupported input rather than producing a silently incomplete project.
7. **Continue in the editor.** The converted project becomes authoritative.
   Reimport creates another project or an explicit reviewed replacement. Source
   refresh remains explicit. Fresh editor exports use current pinned firmware;
   existing flashed firmware is not automatically compatible with that identity.

Existing source validation allows only literal imports and a small known-module
set. MCU-coupled callbacks, dynamic imports, embedded non-Zig assets, external
packages, custom board scanning code, or incompatible APIs require an explicit
adapter or a manual migration report. Schema 1 also cannot represent a callback
with no declared custom IDs, even if it changes layers in response to ordinary
events. The two requested maps fit today; arbitrary Zig programs are a wider
contract and must not be advertised as losslessly importable.

### Evidence from the offline conversion experiment

Research inputs and generated projects are under the ignored
`.zig-cache/research/multi-keyboard/` directory. No extra clone/worktree was
created, no original repository was modified and no hardware was accessed.

The cache-only `import_probe.zig` imported both original modules, lifted every
action and combo, captured their original callback source, wrote
`imported-us/project.zon` and `imported-de/project.zon`, reopened both projects
and generated their `export/` directories. It checked typed action/combination
equality, callback bytes and identity stability across save/reopen. Both passed.
These are research outputs, not a shipped importer or personal project migration.

The cache-only `processor_probe.zig` then compiled each generated keymap with its
captured callback module and compared it with the original through the selected
firmware's actual processor. Both tests passed. Traces covered every key on every
layer as quick taps and resolved holds, every active combo, and pairs of base
holds in both release orders. Output commands, active layers and modifiers
matched. This verifies the sampled behavior under the selected firmware; it does
not compare the older firmware engine or certify physical hardware.

Existing checks passed with Zig 0.17.0:

```sh
zig build test-catalog test-project test-session
zig build test-catalog-defaults test-catalog-processors --summary all
```

The second command passed 28 processor tests across all 14 selected boards.
Both forms of the explicit embedded matrix also passed, producing cached UF2s
for every selected board with companion telemetry enabled:

```sh
zig build catalog-firmware-check -Dfirmware-check=true -Dcatalog-check=true
zig build catalog-firmware-check -Dfirmware-check=true -Dcatalog-check=true -Dcatalog-defaults=true
```

Finally, each imported export passed `build-project` with
`-Dfirmware-check=true -Dproject-build=true`, the explicit
`-Dproject-board=keycaprio_colemak_0_7` target and its absolute `export/` path.
Separate prefixes inside the research cache retained a UF2 and a native
`project-runner` executable for each import. No Flash step was run.

## Implementation order and acceptance

1. **Board onboarding and geometry.** Add creation/opening UI backed by the full
   catalog, preserve existing startup projects, separate hardware labels from
   templates, and add schematic metadata for every selected layout. Acceptance:
   every selector completes create/edit/save/reopen/export/build, with Molekula
   and Keycaprio shown correctly in editor and tutor using offline fixtures.
2. **Portable collections.** Add the optional manifest and keyboard/profile
   navigation while preserving schema-1 children. Acceptance: a repository with
   LK7 and Molekula relocates and opens without absolute-path repairs; source
   bundles travel with it; edits/builds never spill into another child.
3. **Device discovery and companion ownership.** Add identity-first discovery,
   per-device sessions, retained snapshots and origin-tagged gestures. Acceptance:
   two fake devices alternate the overlay with correct geometry, layers and
   pressed keys, including stale releases and disconnects. Freeze tutor context
   independently. Keep existing explicit Flash target protections.
4. **One-way import.** Extract the prototype's typed conversion into supported
   application tooling, integrate import preview/provenance and migrate the two
   requested source formats. Acceptance: unchanged pinned inputs preserve all
   typed fields, callback bytes, constrained layer indices and processor traces;
   generated native runners and target firmware compile. Import does not alter
   or execute either source repository's build script.

The first milestone makes Molekula useful without waiting for collection or
import work. Milestones two and three deliver the desired one-repository,
button-selected companion experience. The fourth uses the already demonstrated
conversion path instead of introducing a source-to-source round-trip system.
