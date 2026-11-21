# Compatibility status

The companion lives in the `companion/` folder of the firmware repository and
builds on the enclosing firmware tree: [`build.zig.zon`](../build.zig.zon)
depends on the root package by path. That tree supplies the processor, keycodes
and board sources for all selected firmware boards. microzig and picotool are
pinned once, in [`zigmkay/build.zig.zon`](../../zigmkay/build.zig.zon). There
is no separate firmware pin and no local firmware override; firmware changes are
made in the same checkout. This is not an accepted stable contract.

The companion uses exactly Zig 0.17.0. The unchanged historical reference uses
Zig 0.16.0; compiler versions alone do not establish behavioral equivalence.

Offline source, test and firmware compilation checks (`zig build check test`,
`check-firmware -Dfirmware`) do not establish physical hardware acceptance.
Native toolchain and platform integration, including desktop USB
identity/snapshot delivery, require validation on supported hosts. Physical
keyboard checks, startup latency and separate interrupt OUT evidence remain
hardware gates. Flashing requires an explicit hardware task. Release artifacts
and native platform acceptance are not implied by passing source checks.
