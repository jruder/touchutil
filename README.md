# touchutil

Make an external **USB touchscreen** work naturally on macOS — tap, scroll, drag, pinch, and navigation swipes.

## The problem this solves

I plugged a portable touchscreen monitor into my Mac and found that macOS
treats it like a plain mouse. On an extended desktop, tapping the touchscreen
doesn't click where you touch — it clicks wherever the system cursor already
happens to be, on whichever display. There's no native macOS setting to map an
external touchscreen's absolute touch input to its own display.

`touchutil` fixes this: it reads the touchscreen's absolute coordinates via
`IOHIDManager` and maps every gesture to the right display.

> **Tested locally** with a **Goojodoq portable touchscreen monitor**
> (SiS HID Touch Controller). Other HID digitizer touchscreens should work too,
> but that's the panel it's been verified on.

- ✅ Apple Silicon + Intel (universal binary)
- ✅ No kernel extension, no SIP changes, no paid developer account
- ✅ Tap, double-tap, scroll, drag, long-press, pinch, and multi-finger navigation

## Limitations

- Multi-finger input is recognized locally and translated into public macOS
  scroll and keyboard events. It is not native multi-contact injection: an app
  that requires ten independent touch points will not see them. Native touch
  emulation requires an entitlement-gated DriverKit HID system extension.

## Requirements

- macOS 11 or later
- [Homebrew](https://brew.sh) (recommended) — or Xcode Command Line Tools for manual install

## Install

### Option A — Homebrew (easiest, recommended)

```bash
brew install --cask keys2505/tap/touchutil
```

No Xcode, no manual steps. Homebrew installs the app, sets up the login agent,
and starts it automatically.

**After install — grant permissions (one-time only)**

macOS will block touchutil until you grant two permissions under
**System Settings → Privacy & Security**:

| Permission | Why it's needed |
| --- | --- |
| **Input Monitoring** | To read raw touch coordinates from the touchscreen |
| **Accessibility** | To move the cursor and synthesize click events |

1. Open System Settings → Privacy & Security → **Input Monitoring** → enable `touchutil`
2. Open System Settings → Privacy & Security → **Accessibility** → enable `touchutil`
3. The app retries automatically once permissions are granted — no need to relaunch.

> These permissions stay local on your Mac. touchutil reads touch input only to
> move your cursor — it sends nothing anywhere.

To uninstall:

```bash
brew uninstall --cask touchutil        # remove app + stop login agent
brew uninstall --cask --zap touchutil  # also delete saved config
```

### Option B — pre-built binary (no Xcode needed)

1. Download the latest `touchutil.zip` from the [Releases](https://github.com/keys2505/touchutil/releases/latest) page.
2. Unzip and run the installer:

```bash
unzip touchutil.zip
cd touchutil
chmod +x scripts/*.sh
./scripts/install.sh
```

To uninstall:

```bash
./scripts/uninstall.sh          # remove app, agent, CLI link, permissions
./scripts/uninstall.sh --purge  # also delete saved config
```

### Option C — build from source

Requires Xcode Command Line Tools (`xcode-select --install`):

```bash
git clone https://github.com/keys2505/touchutil.git
cd touchutil
chmod +x scripts/*.sh
./scripts/install.sh
```

The installer builds the app, copies it to `/Applications`, links the CLI to
`/usr/local/bin/touchutil`, and sets up a login agent so it starts
automatically. After install, grant the two permissions described above.

## Usage

```bash
touchutil           # auto-detects the touchscreen display
touchutil --setup   # pick the touchscreen display and remember it
touchutil --test    # open gesture-feedback window for testing
```

Touch the screen — the cursor follows your finger and responds to gestures.
Your `--setup` choice is saved to `~/.config/touchutil/config.json` and reused
on every run.

### Supported gestures

| Gesture | Action |
| --- | --- |
| Tap | Click |
| Double-tap | Double-click |
| Long-press (~0.5s) | Right-click |
| Vertical swipe | Scroll up / down |
| Hold 0.35s then drag horizontally | Select text / move / resize windows |
| Swipe inward from bottom-left corner | Mission Control (show all windows) |
| Two-finger move | Smooth horizontal / vertical scroll |
| Two-finger pinch | Zoom using Command-plus / Command-minus |
| Three-finger swipe left / right | Next / previous Space |
| Three-finger swipe up / down | Mission Control / App Exposé |

### Options

| Option | Description |
| --- | --- |
| `--setup` | Pick & remember the touchscreen display |
| `--test` | Open a gesture-feedback window on the touchscreen |
| `--no-gestures` | Plain pointer only (no tap / long-press / scroll / edge-swipe) |
| `--list-displays` | List displays and detected touch devices |
| `--list-devices` | List all HID devices |
| `--inspect` | Dump a touchscreen's HID capabilities |
| `--inspect-details` | Dump every HID element and Finger collection |
| `--display-index N` | Map touch to display index `N` (remembered) |
| `--vendor-id 0xVVVV` / `--product-id 0xPPPP` | Match a specific touch device |
| `--debug` | Log raw HID events to stderr |
| `--debug-log` | Log raw HID events to `/tmp/touchutil.debug.log` |
| `--version` | Print version and exit |
| `-h`, `--help` | Show help |

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `IOHIDManagerOpen failed` | Grant **Input Monitoring**, then re-run |
| Cursor doesn't move | Grant **Accessibility**, then re-run |
| `--list-devices` shows nothing | Plug in the touchscreen's **USB data cable** (separate from video) |
| Touch lands on the wrong screen | Run `--setup`, or pass `--display-index` |
| Scroll feels like text selection | Swipe more vertically — horizontal swipes drag instead of scroll |
| Not sure what gesture was detected | Run `touchutil --test` to see real-time gesture feedback |

## How it works

`IOHIDManager` matches the touchscreen digitizer, groups absolute X/Y, contact
identifier, and Tip Switch values by Finger collection, and maps normalized
coordinates onto the chosen display. Gestures are recognised from contact
count, centroid movement, and distance changes.
Click events are posted via `CGEvent` without manual click-count manipulation —
macOS counts consecutive taps naturally, exactly like a real mouse.
A display-reconfiguration callback refreshes the target when you rearrange or
hot-plug displays.

## Contributing

Bug reports are welcome — please open a GitHub issue and include:
- Your macOS version
- Your touchscreen model and the output of `touchutil --list-devices`
- What you expected vs. what happened

For code changes, open an issue first to discuss before sending a PR. This
project is intentionally minimal — patches that add complexity without a clear
use case are unlikely to be merged.

## License

MIT — see [LICENSE](LICENSE).
