# vmware-kali-multimonitor-fix
Fix for VMware multi-monitor on Kali Linux — xautoresize breaks extended displays, this replaces it with a multi-monitor-aware alternative 

Smart display layout manager for Kali Linux running inside VMware Workstation. Replaces `xautoresize` with a multi-monitor-aware alternative that auto-extends multiple displays and auto-resizes single displays to fit the VMware window.

## The Problem

When you enable two monitors in VMware Workstation with a Kali Linux guest:

- **The second monitor mirrors the first** instead of extending the desktop
- **Mouse clicks are offset** -- clicking lands further and further to the left of the cursor as you move right across the screen
- **Exiting fullscreen doesn't scale the guest** -- the display stays at the fullscreen resolution and you have to scroll to see the full desktop

This happens because `xautoresize`, a Kali-specific utility, resets the display layout every time it detects a change. It was designed for single-monitor auto-resize and actively breaks multi-monitor setups. Disabling it fixes multi-monitor but loses auto-resize. This script replaces it with a smarter alternative that handles both.

## What the Script Does

1. **Kills `xautoresize`** and disables it from starting on login
2. **Enables `resolutionKMS`** in VMware Tools config for proper KMS display management
3. **Extends the desktop** across all connected monitors using xrandr
4. **Saves the display configuration** to XFCE settings
5. **Installs a background watcher** that automatically handles all display changes:
   - **Multi-monitor**: auto-extends when VMware connects additional displays
   - **Single monitor**: auto-resizes to fit the VMware window (replaces xautoresize)
   - **Monitor cycling**: re-extends after toggling monitors off and back on
   - **Fullscreen toggle**: scales the guest up or down when entering/exiting fullscreen

The watcher is event-driven (not polling), using `xev` to listen for X11 RandR screen change events.

## Requirements

- Kali Linux guest (tested on kernel 6.18, XFCE desktop, X11 session)
- VMware Workstation (tested on 25.0.0)
- `open-vm-tools` and `open-vm-tools-desktop` installed
- `xrandr`, `xev` (from `x11-utils`), `sudo`
- Two or more monitors enabled in VMware VM settings

## Quick Start

```bash
git clone https://github.com/willlindsey05/vmware-kali-multimonitor-fix.git
cd vmware-kali-multimonitor-fix
chmod +x vmware-autolayout.sh
./vmware-autolayout.sh
```

The script will prompt for your sudo password once, then handle everything automatically.

## Usage

### Fix displays and install the watcher

```bash
./vmware-autolayout.sh
```

Example output:

```
  vmware-autolayout - Display Layout Manager
  ===========================================

[+] Detected 2 connected displays: Virtual-1 Virtual-2
[+] Killed xautoresize
[+] Disabled xautoresize autostart
[+] Added resolutionKMS to tools.conf
[+] Restarted open-vm-tools service
[+] Configuring: Virtual-1 (left) | Virtual-2 (right)
[+] Extended desktop active: 3840 x 1080
[+] Saved XFCE display configuration
[+] Installed watcher autostart
[+] Watcher running (PID 12345)

[+] vmware-autolayout installed successfully.

  Layout:     Virtual-1 (left)  |  Virtual-2 (right)
  Watcher:    Auto-extends and auto-resizes on display changes
  Log:        /tmp/vmware-autolayout.log
  Uninstall:  /path/to/vmware-autolayout.sh --uninstall
```

### Uninstall and restore defaults

```bash
./vmware-autolayout.sh --uninstall
```

This stops the watcher, removes its autostart entry, and re-enables `xautoresize`.

### View the watcher log

The log is written on both initial install and after reboot (via the autostart entry). It is recreated each boot since `/tmp` is cleared on restart.

```bash
cat /tmp/vmware-autolayout.log
```

Example log showing a full cycle -- exiting fullscreen, going back to multi-monitor, and exiting again:

```
[17:10:01] Single display: resizing Virtual-1 from 1920x1080 to 1543x920
[17:10:01] Watching for display changes...
[17:10:42] Display change detected
[17:10:42] Single display: resizing Virtual-1 from 1543x920 to 1920x1080
[17:10:48] Display change detected
[17:10:48] Mirrored layout detected with 2 displays, extending...
[17:10:51] Layout applied: 3840px wide across 2 displays
[17:11:07] Display change detected
[17:11:07] Single display: resizing Virtual-1 from 1920x1080 to 1543x920
```

## How It Works

### Why xautoresize breaks multi-monitor

Kali Linux dropped `xf86-video-vmware` (the dedicated VMware X11 display driver) because it is incompatible with mesa > 25.1. As a replacement, Kali ships `xautoresize`, a utility that watches for display change events and automatically resizes the guest screen to match the VM window.

The problem is that `xautoresize` was built for single-monitor use. When xrandr expands the framebuffer to 3840x1080 for two side-by-side displays, `xautoresize` immediately collapses it back to 1920x1080. This forces both monitors to overlap at position (0,0), causing the mirrored display and the mouse coordinate mismatch.

### Why monitor cycling resets the layout

When you cycle monitors in VMware (toolbar button, fullscreen toggle, or View menu), VMware disconnects and reconnects the virtual displays. The `vmtoolsd` user agent re-establishes the topology, but defaults both displays to position (0,0). Without intervention, they mirror again.

### Why exiting fullscreen doesn't resize

With `xautoresize` disabled, nothing tells the guest to resize when the VMware window changes size. VMware sets a new "preferred" mode on the virtual display connector matching the window dimensions, but no process was reading and applying it.

### The watcher

`vmware-autolayout` installs a lightweight background process that listens for X11 RandR `RRScreenChangeNotify` events via `xev -root -event randr`. When a display change is detected, it handles two scenarios:

**Multiple displays connected** -- checks if the layout is mirrored (screen width equals a single display width) and extends the displays side-by-side.

**Single display connected** -- reads the VMware-suggested preferred resolution from xrandr and resizes the display to match the VM window, replicating what `xautoresize` did without breaking multi-monitor.

The watcher:

- Is event-driven, not polling -- zero CPU usage when idle
- Handles any number of connected displays
- Auto-resizes single displays to fit the VMware window
- Skips re-configuration if the layout is already correct
- Starts automatically on login via an XDG autostart entry, with output logged to `/tmp/vmware-autolayout.log`

## Tested On

| Component | Version |
|-----------|---------|
| VMware Workstation | 25.0.0 (build 24995812) |
| Kali Linux kernel | 6.18.5+kali-amd64 |
| Desktop | XFCE 4 on X11 |
| Graphics stack | modesetting DDX + vmwgfx |
| open-vm-tools | 13.0.10 |

## Troubleshooting

**Script says "Only 1 display(s) detected"**
Enable multiple monitors in VMware first: VM > Settings > Display > Monitors: 2 (or use the "Cycle multiple monitors" toolbar button).

**Script says "This script is for VMware VMs"**
The script checks `systemd-detect-virt` and only runs inside VMware guests.

**Script says "xev not found"**
Install x11-utils: `sudo apt install x11-utils`

**Displays extend briefly then revert**
Make sure `xautoresize` is not running: `pgrep -la xautoresize`. If it is, the script's kill step may have failed -- try `pkill -9 xautoresize` manually.

**Mouse is still offset after fix**
Log out and log back in, or restart the VM. The mouse coordinate mapping sometimes needs a session restart to fully reset.

**Guest doesn't resize when dragging the VMware window edge**
Check the watcher is running: `pgrep -la xev`. If not, restart it: `./vmware-autolayout.sh --watch &`

## License

MIT