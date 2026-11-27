# Linux Keyboard Permissions

On Linux, your Zigmkay keyboard works for normal typing as soon as you plug it in. The kernel's HID input driver handles standard keystrokes without any extra configuration.

To use Companion features that talk directly to the keyboard, Linux requires a small permission rule (`udev` rule):

- **Live layer and keycap labels**
- **Companion on-screen overlay**
- **Typing tutor live key feedback and tap/hold diagnostics**
- **Rebooting into bootloader mode from the editor**
- **Flashing firmware via `picotool`** (on builds that use `picotool` on Linux)

By default, Linux restricts raw HID (`/dev/hidraw*`) and USB boot interfaces (`/dev/bus/usb/*`) to `root`, so ordinary desktop applications cannot open them until a `udev` rule explicitly grants access to the local logged-in user.

## Automatic setup ("Allow access")

When you click **Allow access** in Zigmkay Companion, the app runs:

```sh
pkexec tee /etc/udev/rules.d/70-zigmkay.rules
```

and pipes the bundled rule file to its standard input:

```udev
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="fafa", ATTRS{idProduct}=="00f0", TAG+="uaccess"
SUBSYSTEM=="usb", ATTR{idVendor}=="2e8a", ATTR{idProduct}=="0003", TAG+="uaccess"
```

- Your desktop's own authentication dialog (`polkit`) asks for your administrator password; Zigmkay never sees it.
- Nothing stays running as `root` afterwards.
- `TAG+="uaccess"` grants access **only to the user currently logged in at the local desktop session**, and **only for**:
  - `fafa:00f0` — Zigmkay companion raw HID interface
  - `2e8a:0003` — Raspberry Pi RP2040 ROM BOOTSEL interface

After granting access, **unplug your keyboard and plug it back in** so Linux applies the new rule to the connected device.

## Manual setup (terminal)

If your system does not have `pkexec` / a polkit authentication agent, or if automatic setup fails, run the following in a terminal:

```sh
sudo tee /etc/udev/rules.d/70-zigmkay.rules <<'EOF'
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="fafa", ATTRS{idProduct}=="00f0", TAG+="uaccess"
SUBSYSTEM=="usb", ATTR{idVendor}=="2e8a", ATTR{idProduct}=="0003", TAG+="uaccess"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger
```

Then unplug your keyboard and plug it back in.

## Removing the rule

To revoke the permission at any time:

```sh
sudo rm /etc/udev/rules.d/70-zigmkay.rules
sudo udevadm control --reload-rules
```

## Re-enabling the prompt after "Don't ask again"

Clicking **Don't ask again** creates an empty marker file at `~/.config/zigmkay/linux-access-prompt-dismissed` (or `$XDG_CONFIG_HOME/zigmkay/linux-access-prompt-dismissed`). Delete that file if you want Zigmkay Companion to prompt you again.
