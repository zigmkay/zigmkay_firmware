# Development guide

Start with the [README](../README.md#get-started-with-mise) for installation.
This checkout contains the editor, resident companion, native UI, utilities and
tests. First-party implementation uses exactly Zig 0.17.0; imported C bridges
retain their existing scope. Follow [AGENTS.md](../AGENTS.md) when contributing.

## CI and Windows finalization diagnostics

All four workflows run automatically on pull requests and on pushes to `main`.
Feature-branch pushes do not duplicate the pull-request runs, and a new push
cancels the pull request's running checks. Full application verification covers
macOS and Windows, including relocated offline builds and the GUI build/practice
smoke test, without device access. Pull requests skip macOS x86_64, the isolated
Windows verification, the Ubuntu 22.04 runtime and the ReleaseSafe source job
unless they carry the `full-ci` label.

The **Self-contained application** workflow also supports manual dispatch:

- `diagnostic`: Windows-only manifest publication, runner protection, cache reuse
  and cleanup using fixture artifacts, without firmware compilation. The run
  preserves its executable, PDB, log and output artifacts for three days.
- `gui`: Windows-only offline GUI build/practice verification, without repeating
  the catalog's cold/warm build matrix.
- `full`: the complete macOS/Windows bundle matrix.

Build the small diagnostic locally with `zig build tools -Donly=diagnostic`.
Run `zig-out/bin/diagnose-build-finalization` (with `.exe` on Windows), passing a
fresh output-directory path. Outputs must remain in a cache directory. Windows
attributes are queried natively because Zig 0.17.0's Windows `stat` reports
default permissions rather than the actual read-only attribute.

## Everyday commands

Run commands from the repository root. `mise run` selects the pinned tools;
shell activation is optional.

| Command | Purpose |
| --- | --- |
| `mise run check` | Compile every source, tool and test without devices |
| `mise run test` | Run all offline tests |
| `mise run desktop:check` | Compile the native editor and GUI dependencies without launching |
| `mise run editor:build` | Assemble the complete application without launching |
| `mise run editor:test` | Run offline GUI launch, onboarding, tutor, draft, source-refresh and companion fixtures |
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
| [src/app](../src/app) | Application startup, resident lifecycle and background build/flash work |
| [src/desktop](../src/desktop) | Editor models, native UI, companion presentation and tutor |
| [src/project](../src/project) | Project schema, validation, source preservation and export |
| [src/session](../src/session) | Device sessions and verified live state |
| [src/jobs](../src/jobs) | Build environments, managed jobs and Flash tooling |
| [src/catalog](../src/catalog) | Pinned firmware board/default-profile inventory |
| [src/platform](../src/platform) | Desktop integration, user paths and native window support |
| [tools](../tools) / [tests](../tests) | Zig utilities and integration contracts |
| [build.zig](../build.zig) / [build](../build) | Build options, steps, module graph and test wiring |
| [runtime](../runtime) | Build script shipped inside the application bundle |

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
- [Compatibility status](compatibility.md): remaining acceptance gates.

## Build and check

Use exactly Zig 0.17.0 (`.zigversion` and `mise.toml`). Verify your compiler with
`zig version` before running these commands. The normal firmware dependency is
an immutable, hash-pinned PR-head revision (see [compatibility](compatibility.md));
the normal source build does not require a sibling firmware checkout. Fetching
missing pinned source archives may require network access during dependency
acquisition.

```sh
zig build check test
```

No step accesses devices. An explicit `--fork <firmware-checkout>` override is
available for local firmware development, but is not required for normal builds
and is not a release dependency. Zig configures the whole build graph for every
step, so the options below decide which lazy dependencies are fetched; a step
whose option is missing fails with a message that names it.

| Step | Purpose | Needs |
| --- | --- | --- |
| `check` (default) | Compile every configured source, tool and test | |
| `test` | Run all offline tests, including `test-practice` and `test-jobs`, and fail when a `test` block is compiled into no test binary | |
| `test-practice` | Practice data, storage migration and application paths | works with `-Donly=practice` |
| `test-jobs` | Subprocess, flash-job, traversal and release tooling tests | works with `-Donly=practice` |
| `test-desktop` | SDL dummy/software GUI fixtures, GUI unit tests and flash admission | `-Ddesktop` |
| `test-native` | Query the OS keyboard layout and install a hidden tray; never devices | `-Ddesktop` |
| `run` | Assemble and launch the editor; `-- --background` starts the companion | `-Dbundle` |
| `run-project` | Project create/validate/export command; pass arguments after `--` | |
| `bundle` | Assemble the self-contained application | `-Dbundle` |
| `tools` | Install `release`, `check-application-bundle`, `catalog-export`, `practice-samples` and `diagnose-build-finalization` (plus `bootsel-transfer` on Windows) to `zig-out/bin` | |
| `check-firmware` | Compile generated, synthetic all-board and imported firmware | `-Dfirmware` |
| `check-firmware-defaults` | Compile every board's actual default keymap | `-Dfirmware` |
| `build-project` | Build a verified export into `zig-out/firmware/project.uf2` and `zig-out/bin/project-runner` | `-Dfirmware -Dproject-export=<dir> -Dproject-board=<selector>` |
| `hardware-tools` | Prepare `zig-out/acceptance` (USB candidate UF2 and inventory) and `usb-acceptance` without running them | `-Dfirmware -Ddesktop` |
| `analyze-keymap` | Compile a captured keymap with the typed evaluator | `-Dimport-root=<dir>` |

| Option | Effect |
| --- | --- |
| `-Ddesktop` | Configure DVUI, SDL3, the tray and vector icons |
| `-Dfirmware` | Configure the microzig embedded graph (never flashes) |
| `-Dbundle` | Configure the application bundle; implies `-Ddesktop -Dfirmware` |
| `-Donly=practice` / `-Donly=diagnostic` | Configure only practice and jobs tests, or only the finalization diagnostic, without the firmware package |
| `-Doptimize`, `-Drelease`, `-Drevision`, `-Dmacos-sdk` | Optimization, release CPU/OS baseline, recorded revision and explicit macOS SDK |
| `-Dtest-filter=<text>` | Run only matching tests (repeatable); skips the reachability check |
| `-Dproject-export`, `-Dproject-board` | Inputs of `build-project` |
| `-Dimport-root`, `-Dimport-module` | Inputs of `analyze-keymap` |
| `-Dnative-only` | Skip the embedded graph even with `-Dfirmware`; the importer passes it to both this script and the bundled runtime build |
| `-Dcandidate-project`, `-Dcandidate-overlay-trigger`, `-Dfirmware-revision` | Inputs of the `hardware-tools` USB candidate |

`check-firmware` and `check-firmware-defaults` compile firmware into the build
cache; they do not flash hardware. The bundled application runs
[`runtime/build.zig`](../runtime/build.zig) with its own `build-project`,
`build-runner` and `analyze-keymap` steps; [`build/runtime.zig`](../build/runtime.zig)
lists the source directories shipped with it. The importer tests run their
nested builds against that runtime closure.

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
zig build bundle -Dbundle -j2
```

This developer-only step acquires pinned dependencies and builds the editor and
Flash tools before copying the complete runtime payload. macOS output is
`zig-out/Zigmkay.app`; Windows output is `zig-out/Zigmkay.exe`.
Signing, notarization and DMG creation are separate release work.
`mise run editor` and `mise run companion` assemble and launch this installed
application. Compile-only desktop checks do not produce a distributable bundle.

To validate firmware and native runners for every catalog board without devices:

```sh
zig build bundle tools -Dbundle -j2
zig-out/bin/check-application-bundle \
  "$PWD/zig-out/Zigmkay.app/Contents/Resources" \
  "$PWD/.zig-cache/bundle-check" all
```

## Dependencies

Desktop builds resolve immutable dependencies through Zig's package manager;
no source-directory arguments or source adaptation step is required:

```sh
zig build check -Ddesktop
```

The root [manifest](../build.zig.zon) declares DVUI, ztray, SVG/TinyVG and icons
as ordinary upstream dependencies, each pinned by revision and package hash.
DVUI owns its SDL3 backend and FreeType dependency; the application consumes its
exported `dvui_sdl3` and `sdl3` modules. ztray owns the native menu/tray compilation
and framework linkage. Their Zig 0.17 build scripts run directly, without a local
wrapper, hidden source manifest or patches to cached dependencies.
The ztray pin is the merge commit of its
[Zig 0.17 upstream PR](https://github.com/StaffinityAI/ztray/pull/2) on StaffinityAI/ztray.

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
