# vmware-kali-multimonitor-fix

Display layout manager for Kali Linux running inside VMware Workstation. Replaces `xautoresize` with a two monitor aware alternative that auto-extends multiple displays and auto-resizes single displays to fit the VMware window.

## Tested on 
1. kali-linux-2025.4-vmware-amd64
2. VMware Workstation 25.0.0
## The Problem

When you enable two monitors in VMware Workstation with a Kali Linux guest:

- **The second monitor mirrors the first** instead of extending the desktop
- **Mouse clicks are offset** clicking lands further and further to the left of the cursor as you move right across the screen
- **Exiting fullscreen doesn't scale the guest** the display stays at the fullscreen resolution and you have to scroll to see the full desktop

This happens because `xautoresize` resets the display layout every time it detects a change. It was designed for single monitor auto resize and actively breaks multi-monitor setups. Disabling it fixes multi-monitor but loses auto resize. This script replaces it with a alternative that handles both.

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

- kali-linux-2025.4-vmware-amd64
- VMware Workstation (tested on 25.0.0)
- VM has been upgraded to support 25H2
- `open-vm-tools` and `open-vm-tools-desktop` installed
- `xrandr`, `xev` (from `x11-utils`), `sudo`
- Two monitors enabled in VMware VM settings

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
[17:10:48] Extending 2 displays (current: 1920px, expected: 3840px)...
[17:10:51] Layout applied: 3840px wide across 2 displays
[17:11:07] Display change detected
[17:11:07] Single display: resizing Virtual-1 from 1920x1080 to 1543x920
```

## License

MIT  