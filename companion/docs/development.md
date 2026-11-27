# Development guide

Start with the [README](../README.md#get-started-with-mise) for installation.
This checkout contains the editor, resident companion, native UI, utilities and
tests. First-party implementation uses exactly Zig 0.17.0; the imported C
bridges grow only where Zig cannot reach a system API. Follow
[AGENTS.md](../AGENTS.md) when contributing.

## CI and Windows finalization diagnostics

All four workflows run automatically on pull requests and on pushes to `main`.
Feature-branch pushes do not duplicate the pull-request runs, and a new push
cancels the pull request's running checks. Full application verification covers
macOS and Windows, including relocated offline builds and the GUI build/practice
smoke test, without device access. Pull requests skip macOS x86_64, the isolated
Windows verification, the Ubuntu 22.04 runtime and the ReleaseSafe source job
unless they carry the `full-ci` label.

The **Self-contained application** workflow also supports manual dispatch:

- `diagnostic`: Windows-only manifest publication and cleanup using fixture
  artifacts, without firmware compilation. The run
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

Run commands from the repository root: the root `mise.toml` is a mise
monorepo, so `//companion:<task>` names a task of this folder. Inside
`companion/`, the short names work too. `mise run` selects the pinned tools;
shell activation is optional. `mise tasks --all` lists the firmware tasks as
well.

| Command | Purpose |
| --- | --- |
| `mise run //companion:check` | Compile every source, tool and test without devices |
| `mise run //companion:test` | Run all offline tests |
| `mise run //companion:desktop:check` | Compile the native editor and GUI dependencies without launching |
| `mise run //companion:editor:build` | Assemble the complete application without launching |
| `mise run //companion:editor:test` | Run offline GUI launch, onboarding, tutor, draft, source-refresh and companion fixtures |
| `mise run //companion:typing-practice:test` | Check typing test generation, scoring and application paths |
| `mise run //companion:editor` | Launch the editor with automatic keyboard monitoring |
| `mise run //companion:companion` | Launch the tray resident with windows hidden and automatic monitoring |

For a GUI session without keyboard monitoring:

```sh
mise run //companion:editor -- -- --offline
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
| [src/catalog](../src/catalog) | Firmware board/default-profile inventory |
| [src/platform](../src/platform) | Desktop integration, user paths and native window support |
| [tools](../tools) / [tests](../tests) | Zig utilities and integration contracts |
| [build.zig](../build.zig) / [build](../build) | Build options, steps, module graph and test wiring |
| [runtime](../runtime) | Build script shipped inside the application bundle |

- [Typing practice user guide](typing-practice.md): controls, metrics and fixtures.
- [Keyboard onboarding and import design](design/keyboard-projects-and-import.md):
  multi-keyboard collections, device-specific companion routing and source migration research.
- [Keyboard projects user guide](keyboard-projects.md): creation, collections,
  one-way import, native tutor preparation and hardware-free acceptance commands.
- [Compatibility status](compatibility.md): remaining acceptance gates.

## Build and check

Use exactly Zig 0.17.0 (`.zigversion` and the root `mise.toml`). Verify your
compiler with `zig version` before running these commands. The firmware is the
root package of this repository, a path dependency (`..`); microzig and picotool
come from its pins in `zigmkay/build.zig.zon`. Fetching missing pinned source
archives may require network access during dependency acquisition.

```sh
zig build check test
```

No step accesses devices. The firmware comes from the enclosing repository, so
firmware changes are tested from the same checkout. Zig configures the whole build graph for every
step, so the options below decide which lazy dependencies are fetched; a step
whose option is missing fails with a message that names it.

| Step | Purpose | Needs |
| --- | --- | --- |
| `check` (default) | Compile every configured source, tool and test | |
| `test` | Run all offline tests, including `test-practice` and `test-jobs`, and fail when a `test` block is compiled into no test binary | |
| `test-practice` | Typing test generation, scoring, tutor controls and application paths | works with `-Donly=practice` |
| `test-jobs` | Subprocess, flash-job, traversal and release tooling tests | works with `-Donly=practice` |
| `test-desktop` | SDL dummy/software GUI fixtures, GUI unit tests and flash admission | `-Ddesktop` |
| `test-native` | Query the OS keyboard layout and install a hidden tray; never devices | `-Ddesktop` |
| `run` | Assemble and launch the editor; `-- --background` starts the companion | `-Dbundle` |
| `run-project` | Project create/validate/export command; pass arguments after `--` | |
| `bundle` | Assemble the self-contained application | `-Dbundle` |
| `tools` | Install `release`, `check-application-bundle`, `catalog-export` and `diagnose-build-finalization` (plus `bootsel-transfer` on Windows) to `zig-out/bin` | |
| `check-firmware` | Compile generated, synthetic all-board and imported firmware | `-Dfirmware` |
| `check-firmware-defaults` | Compile every board's actual default keymap | `-Dfirmware` |
| `build-project` | Build a verified export into `zig-out/firmware/project.uf2` | `-Dfirmware -Dproject-export=<dir> -Dproject-board=<selector>` |
| `hardware-tools` | Prepare `zig-out/acceptance` (USB candidate UF2 and inventory) and `usb-acceptance` without running them | `-Dfirmware -Ddesktop` |
| `analyze-keymap` | Compile a captured keymap with the typed evaluator | `-Dimport-root=<dir>` |

| Option | Effect |
| --- | --- |
| `-Ddesktop` | Configure DVUI, SDL3, the tray and vector icons |
| `-Dfirmware` | Configure the microzig embedded graph (never flashes) |
| `-Dbundle` | Configure the application bundle; implies `-Ddesktop -Dfirmware` |
| `-Donly=practice` / `-Donly=diagnostic` | Configure only typing test and jobs tests, or only the finalization diagnostic, without the firmware package |
| `-Doptimize`, `-Drelease`, `-Drevision`, `-Dmacos-sdk` | Optimization, release CPU/OS baseline, recorded revision and explicit macOS SDK |
| `-Dtest-filter=<text>` | Run only matching tests (repeatable); skips the reachability check |
| `-Dproject-export`, `-Dproject-board` | Inputs of `build-project` |
| `-Dimport-root`, `-Dimport-module` | Inputs of `analyze-keymap` |
| `-Dnative-only` | Skip the embedded graph even with `-Dfirmware`; the importer passes it to both this script and the bundled runtime build |
| `-Dcandidate-project`, `-Dcandidate-overlay-trigger` | Inputs of the `hardware-tools` USB candidate; its firmware revision is `-Drevision` |

`check-firmware` and `check-firmware-defaults` compile firmware into the build
cache; they do not flash hardware. The bundled application runs
[`runtime/build.zig`](../runtime/build.zig) with its own `build-project` and
`analyze-keymap` steps; [`build/runtime.zig`](../build/runtime.zig)
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
firmware dependency closure, and prebuilt Flash tools.
Startup reads a small bundle descriptor; it does not scan packages or download
files. An interactive start may run one quiet background build a few seconds
later, described [below](#compiler-cache-warm-up-and-cleanup). Build exports the selected project
and invokes the bundled compiler with `--system`, which forbids dependency
fetching. Missing resources produce a local error.

On macOS these resources live inside `Zigmkay.app`. On Windows they are embedded
in the single `Zigmkay.exe`; the first Build extracts those shipped bytes
atomically into an application-owned cache. This requires disk space, never a
network connection. Subsequent builds reuse the extracted resources. Project
exports, compiler caches and results stay outside the installed application.

### Compiler cache, warm-up and cleanup

Builds use one Zig cache per bundled compiler and host:
`builds/compiler-cache/zig-<hash>` in the application cache directory
(`~/Library/Caches/zigmkay` on macOS). The key is the SHA-256 of the bundled
compiler, recorded as `compiler_hash` in `application.zon`, and the host
target, not the bundle identity, so an application update reuses what it did
not change. A build holds the cache's lock file `zig-<hash>.lock` while its
compiler runs: builds of several running instances take turns, and cleanup
never deletes a cache in use. After its first completed build a bundle leaves
a `built-<bundle id>` marker in the cache; until then the editor shows the
first-build message.

Measured on a 15-core Apple Silicon Mac for the Keycaprio default layout, a
cold build takes about 72 seconds. Nearly all of it is the build runner, the
`regz` register generator with its C libraries and the other host tools; the
firmware itself takes about a second. With a warm cache the same layout builds
again in 0.3 seconds and another board's layout in about a second. After an
identical bundle is reinstalled, the C libraries and `regz` are rebuilt (about
35 seconds); everything else stays cached. `zig build -j` is the core count
minus one, between 2 and 12. On this graph it shortens a cold build only a
little (76 to 80 seconds with `-j2`, 72 seconds with `-j12`) because the critical
path is sequential.

**Warm-up.** About three seconds after every interactive start, unless a
build already ran and once the editor is idle, the editor quietly builds the
open layout, or the default layout while no project is open, with
half the cores. The warm-up never flashes or opens a device. The status row
shows it as **Preparing build caches** with a pulsing orange dot and a thin
progress bar estimated from the last long warm-up (its duration is kept in
`builds/compiler-cache/warmup-ms`; without one the bar moves indeterminately).
Meanwhile Build and Flash look disabled but still take a click: the clicked
button reads **Queued…**, a second click cancels it, and the build or flash
starts by itself when the warm-up ends. Auto-build waits for the warm-up too.
A queued Flash runs only if the layout is still the one it was clicked on. A
warm-up failure is only logged in Details; Build and Flash then work as usual.
A warm-up of the current layout counts as an ordinary build of it, so a
queued Build of that layout needs no second build. It also runs when this bundle built
before: after the application is reinstalled or rebuilt, Zig recompiles a few
host libraries (sqlite, libxml, regz) for the fresh files, about 35 seconds,
while an already warm cache costs about a second. Fixtures, tests, `--offline`, light
previews and bundles without a toolchain never warm up.

**Cleanup.** At startup and after each accepted build, a background pass
deletes cache entries the application recreates on demand. It matches exact
name patterns and never touches projects, preferences or Tutor data. Entries
changed within the last hour are kept, since another instance may be using
them.

| Cache entry | Rule |
| --- | --- |
| `builds/compiler-cache/<64 hex>` | Per-bundle caches of earlier versions: deleted |
| `builds/compiler-cache/zig-<hash>` | Other compilers' caches: deleted when unlocked. The current cache is dropped above 1 GiB, which makes the next build cold once |
| `builds/build-<hex>` | Build outputs and logs: the newest five and the accepted build are kept |
| `exports/v<format>/<snapshot>` | The newest ten and the accepted build's export are kept; older formats are deleted |
| `flash/<hash>.uf2` | Frozen transfer copies: the newest five and the accepted firmware are kept |
| `imports/{analysis,capture,download}-<hex>` | The newest five are kept; the importer's compiler caches are dropped above 512 MiB |
| `editor-environment` | Preparation cache of editors before the bundled toolchain: deleted |
| `runtime/<bundle id>` | Windows payloads of other bundles: deleted |

A cold cache of one bundle holds about 210 MB; each reinstall adds about
160 MB of rebuilt host tools, so the cap is reached after about five updates.

**Flash** builds the current project if necessary, enters BOOTSEL,
transfers the verified UF2, and waits for coherent reconnection. Only that
explicit click authorizes transfer; startup and edits do not. **Auto-build** is
optional and does not authorize flashing. Normal Flash progress stays in the
status row below the toolbar; a separate window opens only for errors. If BOOTSEL is not
discovered within five seconds of the HID trigger, the bar asks the user to
enter BOOTSEL manually and allows thirty additional seconds. That is the same
authorized transaction, not another transfer attempt. No automatic retry occurs.
The build evidence records the application payload identity and exported snapshot.
Artifact freshness and Flash admission checks remain active.
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
`mise run //companion:editor` and `mise run //companion:companion` assemble and launch this installed
application. Compile-only desktop checks do not produce a distributable bundle.

To validate firmware for every catalog board without devices:

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

Project saves retain a `.project.lock` file in the project directory. Cooperating
instances hold its OS lock while checking the saved digest and publishing the
document; the file must not be removed while an instance may hold it. Atomic
source bundles remain immutable. A completed background save advances the disk
baseline even if newer editor changes remain dirty.
