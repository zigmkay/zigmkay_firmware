# Development guide

Start with the [README](../README.md#get-started-with-mise) for installation.
This checkout contains the editor, resident companion, native UI, utilities and
tests. First-party implementation uses exactly Zig 0.17.0; imported C bridges
retain their existing scope. Follow [AGENTS.md](../AGENTS.md) when contributing.

## CI and Windows finalization diagnostics

All four workflows run automatically on pull requests and on pushes to `main`.
Feature-branch pushes do not duplicate the pull-request runs. Full application
verification covers macOS and Windows, including relocated offline builds and
the GUI build/practice smoke test, without device access.

The **Self-contained application** workflow also supports manual dispatch:

- `diagnostic`: Windows-only manifest publication, runner protection, cache reuse
  and cleanup using fixture artifacts, without firmware compilation. The run
  preserves its executable, PDB, log and output artifacts for three days.
- `gui`: Windows-only offline GUI build/practice verification, without repeating
  the catalog's cold/warm build matrix.
- `full`: the complete macOS/Windows bundle matrix.

Build the small diagnostic locally with
`zig build build-finalization-diagnostic -Dfinalization-diagnostic-only=true`.
Run `zig-out/bin/diagnose-build-finalization` (with `.exe` on Windows), passing a
fresh output-directory path. Outputs must remain in a cache directory. Windows
attributes are queried natively because Zig 0.17.0's Windows `stat` reports
default permissions rather than the actual read-only attribute.

## Everyday commands

Run commands from the repository root. `mise run` selects the pinned tools;
shell activation is optional.

| Command | Purpose |
| --- | --- |
| `mise run check` | Check bootstrap and compiler pin without devices |
| `mise run test` | Run the offline companion checks |
| `mise run editor:build` | Compile the native application without launching |
| `mise run editor:test` | Run offline GUI launch, tutor, source-refresh and companion fixtures |
| `mise run companion:test` | Check companion visibility and placement offline |
| `mise run typing-practice:test` | Check practice data, storage and application paths |
| `mise run editor` | Launch the editor with automatic keyboard monitoring |
| `mise run companion` | Launch the tray resident with windows hidden and automatic monitoring |

For a GUI session without keyboard monitoring:

```sh
mise run editor -- -- --offline
```

The two `--` separators forward arguments through mise and `zig build` to the
application. Closing the editor can leave the tray resident alive; choose
**Quit Zigmkay** to exit. An offline session never authorizes a device transfer.

Developer builds acquire immutable dependencies through Zig before compilation.
Network access may be needed on the build machine. The assembled application
contains its runtime dependencies and never downloads packages. Keep test outputs
in caches, and preserve personal projects and attached source bundles.

## Source map and further reading

| Location | Responsibility |
| --- | --- |
| [apps/desktop](../apps/desktop) | Application startup, resident lifecycle and background build/flash work |
| [packages/desktop](../packages/desktop) | Editor models, native UI, companion presentation and tutor |
| [packages/project](../packages/project) | Project schema, validation, source preservation and export |
| [packages/session](../packages/session) | Device sessions and verified live state |
| [packages/jobs](../packages/jobs) | Build environments, managed jobs and Flash tooling |
| [packages/catalog](../packages/catalog) | Pinned firmware board/default-profile inventory |
| [packages/platform](../packages/platform) | Desktop integration, user paths and native window support |
| [tools](../tools) / [tests](../tests) | Zig utilities and integration contracts |

- [Typing practice user guide](typing-practice.md): controls, metrics, data and evidence.
- [Tutor package design](design/typing-practice-packages.md): boundaries and contracts.
- [Keyboard onboarding and import design](design/keyboard-projects-and-import.md):
  multi-keyboard collections, device-specific companion routing and source migration research.
- [Keyboard projects user guide](keyboard-projects.md): creation, collections,
  one-way import, native tutor preparation and hardware-free acceptance commands.
- [Practice implementation](implementation/typing-practice.md): input and scoring.
- [Practice data](implementation/practice-data.md), [rundown](implementation/practice-rundown.md),
  [progress](implementation/practice-progress.md), [timing diagnostics](implementation/practice-diagnostics.md),
  [curriculum](implementation/practice-curriculum.md), and [help/recall](implementation/practice-help.md).
- [Native layout review](implementation/practice-layout-review.md): visual studies,
  native screenshots, layout checks and offline gallery reproduction.
- [README screenshot notes](screenshots/overview/README.md): native capture provenance.
- [Compatibility status](../compatibility/README.md): remaining acceptance gates.

## Build and check

Use exactly Zig 0.17.0 (`.zigversion` and `mise.toml`). Verify your compiler with
`zig version` before running these commands. The normal dependency is an
immutable, hash-pinned EuroZig firmware PR-head revision pending merge; the
normal source build does not require a sibling firmware checkout. Fetching missing
pinned source archives may require network access during dependency acquisition.

```sh
zig build test
zig build check
```

These checks do not access devices. An explicit `--fork <firmware-checkout>`
override is available for local firmware development, but is not required for
normal builds and is not a release dependency. `firmware-check` and
`catalog-firmware-check` are opt-in firmware compilation checks; they do not
flash hardware.

## Capabilities and limits

Project validation reads data without compiling callbacks. Export and firmware
compilation require supported source and ABI bindings; callback-bearing defaults
need an explicit source binding. Catalog fixtures and processor checks cover
all 14 selected boards, including offline default-profile source/export checks;
physical GPIO mapping and per-board hardware acceptance remain separate. Native layout tests can query the host desktop
layout and are distinct from deterministic keymap tests. Compatibility and
native platform acceptance remain incomplete; do not interpret a passing
`zig build check` as device or cross-platform certification.

Normal editor startup monitors keyboards. Builds, tests and explicit offline
startup do not access hardware. Flashing or other hardware mutations require a
separate explicit hardware task. The checks below never flash a device.

## Editor Build and Flash

The installed application contains Zig 0.17.0 and its libraries, the pinned
firmware dependency closure, native runner sources, and prebuilt Flash tools.
Startup reads a small bundle descriptor; it does not scan packages, run the
compiler, download files or compile tools. Build exports the selected project
and invokes the bundled compiler with `--system`, which forbids dependency
fetching. Missing resources produce a local error.

On macOS these resources live inside `Zigmkay.app`. On Windows they are embedded
in the single `Zigmkay.exe`; the first Build extracts those shipped bytes
atomically into an application-owned cache. This requires disk space, never a
network connection. Subsequent builds reuse the extracted resources. Project
exports, compiler caches and results stay outside the installed application.

**Flash** builds the current project if necessary, enters BOOTSEL,
transfers the verified UF2, and waits for coherent reconnection. Only that
explicit click authorizes transfer; startup and edits do not. **Auto-build** is
optional and does not authorize flashing. Normal Flash progress stays in the
system-message bar; a separate window opens only for errors. If BOOTSEL is not
discovered within five seconds of the HID trigger, the bar asks the user to
enter BOOTSEL manually and allows thirty additional seconds. That is the same
authorized transaction, not another transfer attempt. No automatic retry occurs.
The build evidence records the application payload identity and exported snapshot.
Artifact freshness, runner verification and Flash admission checks remain active.
No compiler installation, development checkout or platform SDK is required by
the assembled application.

## Assemble the application

```sh
zig build bundle-application -Dapplication-bundle=true \
  -Ddesktop-dependencies=true -Ddesktop-vectors=true -j2
```

This developer-only step acquires pinned dependencies and builds the editor and
Flash tools before copying the complete runtime payload. macOS output is
`zig-out/Zigmkay.app`; Windows output is `zig-out/Zigmkay.exe`.
Signing, notarization and DMG creation are separate release work.
`mise run editor` and `mise run companion` assemble and launch this installed
application. Compile-only desktop checks do not produce a distributable bundle.

To validate firmware and native runners for every catalog board without devices:

```sh
zig build build-bundle-check
zig-out/bin/check-application-bundle \
  "$PWD/zig-out/Zigmkay.app/Contents/Resources" \
  "$PWD/.zig-cache/bundle-check" all
```

## Dependencies

Desktop builds resolve immutable dependencies through Zig's package manager;
no source-directory arguments or source adaptation step is required:

```sh
zig build build-desktop -Ddesktop-dependencies=true -Ddesktop-vectors=true
zig build check-desktop-dependencies -Ddesktop-dependencies=true -Ddesktop-vectors=true
```

The root [manifest](../build.zig.zon) declares DVUI, ztray, SVG/TinyVG and icons
as ordinary upstream dependencies, each pinned by revision and package hash.
DVUI owns its SDL3 backend and FreeType dependency; the application consumes its
exported `dvui_sdl3` and `sdl3` modules. ztray owns the native menu/tray compilation
and framework linkage. Their Zig 0.17 build scripts run directly, without a local
wrapper, hidden source manifest or patches to cached dependencies.
The ztray pin uses the immutable head of its
[Zig 0.17 upstream PR](https://github.com/StaffinityAI/ztray/pull/2), pending merge.

Native CI assembles macOS and Windows applications and exercises relocated
firmware builds and practice without keyboard access. macOS acceptance denies
network and developer checkout/toolchain access. Windows uses the single
executable with empty application caches and Zig's offline package mode.
Interactive desktop/tray and physical device acceptance remain separate gates;
Linux distribution packaging remains pending.

Practice persistence uses the immutable `zqlite` dependency declared in
`build.zig.zon`, including its bundled SQLite implementation. Application code
owns schema validation, transactions and migrations; the translated upstream
header is used only for SQLite's online backup integration and journal-mode
retry handling. Current-schema history queries use a read-only connection and
one read transaction. Legacy imports and schema upgrades reopen for writing
only when needed.

Project saves retain a `.project.lock` file in the project directory. Cooperating
instances hold its OS lock while checking the saved digest and publishing the
document; the file must not be removed while an instance may hold it. Atomic
source bundles remain immutable. A completed background save advances the disk
baseline even if newer editor changes remain dirty.
