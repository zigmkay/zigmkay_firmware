# Linux Keyboard Permissions

On Linux, your Zigmkay keyboard works for **normal typing and flashing firmware** right out of the box—no extra permissions or system rules are required for either.

To use Companion features that talk directly to the running keyboard over raw HID, Linux requires a small permission rule (`udev` rule):

- **Live layer and keycap labels**
- **Companion on-screen overlay**
- **Typing tutor live key feedback and tap/hold diagnostics**
- **Automatic bootloader reboot from the editor**
- **Live firmware identity verification after flashing**

By default, Linux restricts raw HID nodes (`/dev/hidraw*`) to `root`, so ordinary desktop applications cannot open them until a `udev` rule explicitly grants access to the local logged-in user.

## Automatic setup ("Allow access")

When you click **Allow access** in Zigmkay Companion, the app runs:

```sh
pkexec tee /etc/udev/rules.d/70-zigmkay.rules
```

and pipes the bundled rule file to its standard input:

```udev
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="fafa", ATTRS{idProduct}=="00f0", TAG+="uaccess"
```

- Your desktop's own authentication dialog (`polkit`) asks for your administrator password; Zigmkay never sees it.
- Nothing stays running as `root` afterwards.
- `TAG+="uaccess"` grants access **only to the user currently logged in at the local desktop session**, and **only for** the Zigmkay companion raw HID interface (`fafa:00f0`).

After granting access, **unplug your keyboard and plug it back in** so Linux applies the new rule to the connected device.

## Manual setup (terminal)

If your system does not have `pkexec` / a polkit authentication agent, or if automatic setup fails, run the following in a terminal:

```sh
echo 'SUBSYSTEM=="hidraw", ATTRS{idVendor}=="fafa", ATTRS{idProduct}=="00f0", TAG+="uaccess"' \
  | sudo tee /etc/udev/rules.d/70-zigmkay.rules
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
