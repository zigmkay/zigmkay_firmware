# Compatibility status

The normal firmware dependency is `conlorz/zigmkay_firmware` commit
`83b689262ae4a6f814ba9c7aa9fa868bf734350f`, the head of firmware PR #60, pinned
to an immutable package hash in [`build.zig.zon`](../build.zig.zon). It supplies
the processor, keycodes and board sources for all selected firmware boards. It is
pinned for hardware testing; it is not a native release or an accepted stable
contract. Normal builds do not require a sibling firmware checkout. A local
firmware override is an explicit development input only.

The companion uses exactly Zig 0.17.0. The unchanged historical reference uses
Zig 0.16.0; compiler versions alone do not establish behavioral equivalence.

Offline source, test and firmware compilation checks (`zig build check test`,
`check-firmware -Dfirmware`) do not establish physical hardware acceptance.
Native toolchain and platform integration, including desktop USB
identity/snapshot delivery, require validation on supported hosts. Physical
keyboard checks, startup latency and separate interrupt OUT evidence remain
hardware gates. Flashing requires an explicit hardware task. Release artifacts
and native platform acceptance are not implied by the published source pin.
