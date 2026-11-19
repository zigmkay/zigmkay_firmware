# Companion agreement

This folder of the zigmkay firmware repository owns the Zigmkay editor and
companion source. Contributors can work from this checkout without private
plans, handovers or other repositories. Publishing and device access require separate requests.

- Keep first-party application packages, utilities, generators and tests here
  and implement them in Zig. Another implementation language requires explicit
  user permission. Preserve existing imported C bridges without expanding them.
- Use exactly Zig 0.17.0, pinned in `.zigversion`, for production code, build
  logic, utilities, generators and tests. Verify the selected compiler; do not
  downgrade Zig to work around dependency compatibility.
- The firmware is in-tree: `build.zig.zon` depends on the enclosing root
  package by path, and there are no separate firmware pins or local firmware
  overrides. microzig and picotool are pinned once, in `../zigmkay/build.zig.zon`;
  pin other external dependencies to immutable revisions and hashes. The board
  table comes from `../keyboards/boards.zig`. Firmware packages must not depend
  on `companion/`.
- Do not create additional clones or worktrees without a user request. Do not
  add remotes, push, open PRs or publish releases without a user request. Make
  focused local commits when authorized. In multi-agent work, the coordinator
  owns Git, manifests, shared build glue, generated-source regeneration and
  integration; workers receive disjoint writable paths and frozen contracts.
- Builds, tests and explicit offline startup must not access hardware. Normal
  editor/companion startup automatically monitors keyboards. Flashing and other
  hardware mutations require an explicit hardware task.
- Preserve personal projects and source bundles. Keep generated test outputs in
  caches; regenerate committed sources only explicitly.
- Keep code, comments, diagnostics, tests, documentation and commit messages in
  English. Run appropriate Zig checks for implementation changes and check
  documentation links and whitespace for documentation changes.
