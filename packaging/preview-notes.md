These downloads are **unsigned previews**. Zig, its libraries, firmware sources,
the pinned dependency closure, native runner sources and flash tools are bundled.
Users do not need to install Zig or an SDK. Normal startup monitors keyboards;
flashing requires the application's explicit Flash action.

Downloads: Apple Silicon and Intel macOS 15 DMGs, Windows 11 x86_64 portable EXE,
and Linux x86_64 AppImage (glibc 2.35 or later; Ubuntu 22.04 baseline).

macOS may block an unsigned application; use the explicit **Open Anyway** control
in Privacy & Security only after verifying the download and its checksum.
Windows SmartScreen may show an unknown-publisher warning. This preview has no
Developer ID, notarization or Authenticode signature.

On Linux, make the AppImage executable with `chmod +x Zigmkay-*.AppImage`.
If FUSE mounting is unavailable, run `./Zigmkay-*.AppImage --appimage-extract`,
then `./squashfs-root/AppRun`. The static runtime does not require libfuse2.
See the bundled `usr/share/zigmkay/70-zigmkay.rules` and the repository's preview
documentation for manual Linux device permissions.

Windows flashing uses the RP2040 BOOTSEL USB mass-storage driver supplied with
Windows. It copies the validated UF2 directly and then waits for a coherent
firmware identity. Transfer completion alone does not establish success and
cannot provide picotool's flash read-back. Disconnect additional BOOTSEL devices.

Practice history remains schema 3. Upgrades from schemas 1 and 2 create validated
standalone backups in persistent `typing-practice/backups`; backups are retained.
For rollback, quit every Zigmkay instance, archive the entire current history
directory (including WAL/SHM files), restore a selected standalone backup as
`practice.sqlite3` in a clean history directory, then launch the older application.
Later history remains in your archive and is absent from the restored snapshot.

`SHA256SUMS`, `release-metadata.json` and per-download metadata record provenance
and hashes. `corresponding-source.tar.gz` contains this application and selected
dependency sources, including platform-specific dependency archives.

Native device and real Windows driver-free flashing acceptance require a separate
hardware task. Automated release verification does not access keyboards or flash
devices. Signing, installers, Flatpak and automatic updates are follow-up work.
