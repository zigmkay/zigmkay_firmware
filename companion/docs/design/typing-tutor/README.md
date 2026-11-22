# Typing Tutor Visual Mockups

Visual design references for the adaptive Typing Tutor feature (tracked in the **`Typing tutor`** git-native issue milestone via `git issue`).

These HTML mockups preserve the visual direction aligned with the Companion Editor design language (`companion/docs/design/editor.md`) and incorporate the finalized design decisions:
- English-only UI terminology matching the editor (`Back to editor`, `Tutor | Test keys`, `Stage 1 · Home row`, `Stage 2 · All letters`, `Target speed`, `Progress`, `Guided`, `On hesitation`, `Free`).
- Dedicated `Tutor | Test keys` segmented control in the top bar separating 10-finger touch-typing practice from pure hardware/layout verification.
- Exact board geometry and Tap/Hold keycap anatomy (illustrated on Keycaprio 34 with Colemak-DH).

## Files

- [mockup-1-active-practice.html](mockup-1-active-practice.html) — Main Tutor screen: editor-style top bar with `Tutor | Test keys` switch, key-confidence strip, calm 3-line typing stage, live metrics, and physical Tap/Hold keyboard guidance with finger zones and home-anchor motion indicator.
- [mockup-2-shift-layers-combos.html](mockup-2-shift-layers-combos.html) — Stage 3 (Opposite-Hand Home-Row Shift) and Stage 5 (Layers, Symbols & 2-Key Combos) guidance states.
- [mockup-3-stages-progress.html](mockup-3-stages-progress.html) — Secondary sheets: 6-stage learning path grid, KPI cards, WPM trend chart with target speed & unlock markers, weakest keys/bigrams, and 1-click weak-spot drill CTA.

> **Note:** Planning, architecture contracts, task dependencies, and implementation documentation live in git-native issues (`git issue ls` / `git issue tree`), not in Markdown planning files. Before opening the final PR, review and clean up these mockup files as part of the pre-PR documentation & hygiene audit issue.
