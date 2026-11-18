# Typing practice implementation evidence

Integration base: `16ad7000da29dd5e24281f5ead17c56a4ea4b4e9` (published
`public/main`). The older extraction checkout has a separate history and
unrelated local work; it is unchanged. This existing worktree contains the
feature branch. No firmware, dependency pins or personal projects are changed.
The design input is the locally supplied 2026-10-14 typing practice rundown
plan. Its selected mockup is a design reference, never a product screenshot.

Contracts: generation v1 uses SplitMix64 with fixed textual coverage for
challenges; metrics v1 count distinct missed reference occurrences; storage v1
uses immutable per-run ZON files and atomic exclusive publication. Comparison
includes behavioral/mapping identities and all exercise settings. A layout
reference cannot certify the keyboard producing OS text.

Native Windows/Linux storage evidence is recorded below from the CI runners;
user typing trials remain pending. No hardware task is part
of this feature. The requested PR remains open for the user's morning review.

## Implementation and capture checkpoint

Production/fixture checkpoint: `c7772fa`; post-implementation review checkpoint:
`11e6271`, with final provenance/residency follow-up `bd9b81d`. Native screenshots
were regenerated from that final reviewed source. Generation/corpus/textual coverage, metrics, drill policy and ZON
storage versions are all 1. The nine English pairs cover seeds 0–63, with literal
SHA-256 fixtures for seed 42; `tools/practice_samples.zig` prints the reviewable
nine samples. Base vocabulary is 893 unique curated ordinary entries. No external
corpus or license dependency was introduced. Words use twelve sentence structures;
Mixed case uses twelve and punctuation has eight coverage-bearing openings.
Readable sample review led to explicit vocabulary-use sentences instead of
incoherent random topic claims and corrected acronym article agreement.

The [selected planning mockup](typing-practice-design-reference.png) is a generated
design reference, not a screenshot of the application. The user guide's images
are real native app output with deterministic offline exercise/result fixtures.
`src/app/practice_fixture.zig` adds explicit US symbol actions to the generic
QWERTY fixture only; the ordinary template lacks some symbol routes. No saved
project or firmware is altered by capture. Scripted counts do not represent a
human typing trial, hardware validation or learning efficacy.

Capture environment: macOS 26.6.2 (25G83), arm64, native SDL/Cocoa renderer,
Retina pixel scale 2. Normal window: 1536×1024 logical, 3072×2048 pixels; small
window: native minimum 900×700 logical. Images are reduced to 1536 pixels wide,
and the small image to 900, with the macOS `sips` utility. Light/dark use the app's
existing themes; system fonts are read locally and never committed.

After compiling `build-desktop` with the prepared immutable desktop sources and
`-Ddesktop-dependencies=true -Ddesktop-vectors=true`, capture explicitly:

```sh
practice_exe=$(ls -t .zig-cache/o/*/zigmkay-companion | head -1)
"$practice_exe" --native-rundown-frames 20
sips -s format png -Z 1536 .zig-cache/typing-practice-gallery/4.bmp \
  --out docs/screenshots/typing-practice/rundown-light.png
```

Capture reads pixels before frame cleanup, while render resources are valid.
The app remains offline; it uses no native input-source lookup, HID connection,
tray installation or user history. Source frames 2/4/6/8/10/14 respectively supply
tutor/light/symbols/dark/drill/history images. Frame 20 supplies the
[small-window rundown](../screenshots/typing-practice/small.png). Original BMPs and
logs stay in ignored caches. The software/dummy lane exercises controls and
state without hardware; its font rendering is not used for documentation.

## Checks and remaining gates

Compiler: exactly Zig 0.17.0, verified from the installed zvm compiler.
Local checks passed:

- `zig build test-desktop-core test-app-paths -j4`.
- `zig build check test -j4 --test-timeout 45s`.
- Prepared GUI graph: `build-desktop test-desktop-launch test-desktop-practice
  test-desktop-rundown test-desktop-companion test-desktop-source-refresh -j4`.
- Native macOS screenshot fixture, including layer/Shift selectors, details,
  history scope, drill focus, all assistance modes and the small window.
- Documentation links, Zig formatting and `git diff --check`.

The prepared GUI lane uses the pinned sources already acquired under the
existing checkout's `desktop-acquired/p/` cache, with each explicit
`desktop-*-source` option. No source acquisition or firmware override was needed.
Native storage tests create Unicode/space directories, publish/reopen records,
run independent writers, preserve interrupted/corrupt/future data, retain queued
failed saves, test idempotence and exercise weighted twelve-run history. The
background-worker allocator leak detected by those tests was corrected.

`.github/workflows/practice-contracts.yml` runs generator, result, storage,
background-runtime and path-policy tests on actual macOS, Windows and Linux CI
runners. Their results are recorded below; native GUI acceptance remains separate.
Native Windows/Linux GUI/input-source behavior, human typing trials and required
user review remain pending; no extraction, firmware or release gate is closed by
this feature. The requested PR is left open for morning review and testing.

## Post-implementation code review

Reviewed the complete feature diff against the committed integration base after
implementation/docs were finished. Review corrections:

- **P1, completed-result loss:** a completion and New exercise click in the same
  input batch could replace the session before the application froze it. Fresh
  starts now wait for result capture; an explicit batch regression retains the
  completed state and generation until acknowledgement.
- **P1, full-queue loss:** a seventeenth result during sustained save failure
  could remain outside the queue and be overwritten by another exercise. It now
  stays in the rundown, retries enqueue after capacity returns, and blocks fresh
  starts until it is retained or history is deliberately cleared.
- **P2, failed clearing:** prior errors could prevent Clear from running, and a
  failed clear could discard queued records. Clear now bypasses the prior-error
  guard and only discards pending records after successful clearing. A future
  schema fixture verifies pending IDs survive a failed clear.
- **P2, frozen display context:** result names could come from a later renamed
  project/input source even though IDs were frozen. Names are now captured at
  start. A real project identity fixture confirms renames and caption changes
  do not change the comparison identity; changed translated routes do.
- **P2, corrupted Unicode:** stored substitution codepoints and duplicate pairs
  now receive explicit validation before aggregation/rendering.

The review also checked atomic file ownership, weighted aggregation, scored
last-ten eligibility, current-run inclusion, case/symbol separation, modifier
variants, runner replacement/cancellation, stale live state, assistance scope,
keyboard-event forwarding on results, bounded generation and fixture hardware
guards. Remaining validation limitations are listed above; no cross-platform
GUI or human-learning acceptance is claimed.

Guided companion rendering was also brought into the same assistance policy:
TAP/HOLD guidance is shown only when its actual labels match the practice frame.
Layout only suppresses every guidance/pressed highlight, and Hidden suppresses
the participating window. Unrelated verified running profiles do not receive
hints from an unflashed draft.

A final residency check ensures hidden editor/companion windows do not bypass
polling and draining successful history writes. Failed queues can return to idle
and remain available on reopening; background workers use the existing bounded
wait budget. This does not change device monitoring or initiate device mutations.

PR: https://github.com/conlorz/zigmkay_companion/pull/2 (linked to the T3 thread).

## Native CI evidence

At published review checkpoint `a75a6a0`, all three native practice lanes passed
in [PR workflow run 38481853826](https://github.com/conlorz/zigmkay_companion/actions/runs/38481853826):
macOS, Windows and Ubuntu. This establishes native filesystem/generation/metric
contract evidence, including Unicode directories, independent atomic writers,
background save/reopen and failed-clear queue preservation. It does not establish
Windows/Linux GUI, active input-source discovery or human learning outcomes.

The final small review follow-up keeps background history responsive while the
editor is hidden, limits physical hand quotas to known translation, and keeps
English challenge/drill settings separate from fixed Zig lessons.

The route review additionally caught display-only `?` placeholders being accepted
as literal question-mark routes. Provenance is now explicit in the label cache:
unknown/named translations and arbitrary tap callbacks are excluded, and unknown
custom hold providers are not requested. A regression distinguishes a function
key's unknown placeholder from a real translated question mark. Hand coverage
also requires known translation, rather than claiming active-layout knowledge
from Windows/Linux fallback labels. This is part of the initial route contract.

The broader [Linux source-check run](https://github.com/conlorz/zigmkay_companion/actions/runs/38481853501)
failed four existing jobs fixtures at their 10-second deadline. The same four
package-cache/resolution/toolchain/build fixtures timed out in
[main's earlier run](https://github.com/conlorz/zigmkay_companion/actions/runs/38437303625)
before this feature. Those jobs and their timeout policy are unchanged; local
full checks pass. This pre-existing CI failure is recorded rather than hidden or
worked around by weakening the checks.

Unicode display-name truncation is codepoint-safe and corrupt stored names are
rejected before rendering. Native small-window inspection also led to a practice
scale floor of 0.8, preserving readable controls while retaining the editor's
existing fit policy. The small-window fixture now resets its result scope on
new runs, matching the actual controls rather than retaining a scripted old scope.
