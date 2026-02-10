#!/bin/bash
#
# vmware-autolayout - Smart display layout manager for VMware VMs on Kali Linux
#
# Replaces xautoresize with a multi-monitor-aware alternative that
# auto-extends multiple displays and auto-resizes single displays.
#
# Usage:
#   ./vmware-autolayout.sh              # Fix now + install persistent watcher
#   ./vmware-autolayout.sh --watch      # Run as the background watcher (internal)
#   ./vmware-autolayout.sh --uninstall  # Undo everything
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "$0")"
WATCHER_AUTOSTART="/etc/xdg/autostart/vmware-autolayout.desktop"
XAUTORESIZE_AUTOSTART="/etc/xdg/autostart/xautoresize.desktop"
TOOLS_CONF="/etc/vmware-tools/tools.conf"
SETTLE_DELAY=2

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[-]${NC} $1"; }
log()   { echo "[$(date '+%H:%M:%S')] $1"; }

# Get the preferred mode (marked with +) for a display, or first listed mode
get_preferred_mode() {
    local display="$1"
    local mode
    mode=$(xrandr | sed -n "/^${display} /,/^[^ ]/p" | grep -v '^\S' | grep '+' | grep -oP '^\s+\K\d+x\d+' | head -1 || true)
    if [ -z "$mode" ]; then
        mode=$(xrandr | sed -n "/^${display} /,/^[^ ]/p" | grep -v '^\S' | grep -oP '^\s+\K\d+x\d+' | head -1 || true)
    fi
    echo "$mode"
}

# Get active mode from the status line, empty if display is inactive
get_active_mode() {
    local display="$1"
    xrandr | grep "^${display} " | grep -oP '\d+x\d+\+' | head -1 | grep -oP '\d+x\d+' || true
}

# Apply extended layout using a single atomic xrandr command
extend_displays() {
    local connected="$1"
    local args="" x_pos=0

    for d in $connected; do
        local mode
        mode=$(get_preferred_mode "$d")
        if [ -z "$mode" ]; then
            mode="1920x1080"
        fi
        args="$args --output $d --mode $mode --pos ${x_pos}x0"
        local w
        w=$(echo "$mode" | cut -dx -f1)
        x_pos=$((x_pos + w))
    done

    xrandr $args
}

# =========================================================================
# Watch mode — runs as a background daemon watching for display changes
# =========================================================================

watch_mode() {
    apply_layout() {
        sleep "$SETTLE_DELAY"

        local connected
        connected=$(xrandr | grep ' connected' | awk '{print $1}')
        local count
        count=$(echo "$connected" | wc -l)

        if [ "$count" -lt 2 ]; then
            # Single display — auto-resize to fit VMware window
            local display
            display=$(echo "$connected" | head -1)
            local preferred current
            preferred=$(get_preferred_mode "$display")
            current=$(get_active_mode "$display")

            if [ -n "$preferred" ] && [ "$preferred" != "$current" ]; then
                log "Single display: resizing $display from ${current:-inactive} to $preferred"
                xrandr --output "$display" --mode "$preferred"
            else
                log "Single display (${current:-$preferred}), already at preferred size"
            fi
            return
        fi

        # Check if already properly extended
        local screen_w=$(xrandr | head -1 | grep -oP 'current \K\d+')
        local expected_w=0
        for d in $connected; do
            local w
            w=$(get_preferred_mode "$d" | cut -dx -f1)
            expected_w=$((expected_w + ${w:-0}))
        done

        if [ "$expected_w" -gt 0 ] && [ "$screen_w" -ge "$expected_w" ] 2>/dev/null; then
            log "Already extended (${screen_w}px wide), skipping"
            return
        fi

        log "Extending $count displays (current: ${screen_w}px, expected: ${expected_w}px)..."

        # Single atomic xrandr command with explicit modes and positions
        extend_displays "$connected"
        sleep 1

        # Verify and retry if needed
        screen_w=$(xrandr | head -1 | grep -oP 'current \K\d+')
        if [ "$screen_w" -lt "$expected_w" ] 2>/dev/null; then
            log "First attempt got ${screen_w}px, retrying..."
            sleep 2
            extend_displays "$connected"
            sleep 1
            screen_w=$(xrandr | head -1 | grep -oP 'current \K\d+')
        fi

        log "Layout applied: ${screen_w}px wide across $count displays"
    }

    apply_layout
    log "Watching for display changes..."
    xev -root -event randr 2>/dev/null | while read -r line; do
        if echo "$line" | grep -q "RRScreenChangeNotify"; then
            log "Display change detected"
            apply_layout
        fi
    done
}

# =========================================================================
# Uninstall mode — undo all changes
# =========================================================================

uninstall_mode() {
    if ! sudo -n true 2>/dev/null; then
        sudo -v || { error "sudo authentication failed"; exit 1; }
    fi

    info "Uninstalling vmware-autolayout..."

    # Stop watcher
    if pgrep -f "vmware-autolayout.sh --watch" &>/dev/null; then
        pkill -f "vmware-autolayout.sh --watch" && info "Stopped watcher"
    fi

    # Also stop old watchers from previous versions
    if pgrep -f "fix_multi_monitor.sh --watch\|vmware-extend-monitors.sh" &>/dev/null; then
        pkill -f "fix_multi_monitor.sh --watch\|vmware-extend-monitors.sh" && info "Stopped old watcher"
    fi

    # Remove old autostart entries
    for f in /etc/xdg/autostart/vmware-extend-monitors.desktop; do
        [ -f "$f" ] && sudo rm "$f"
    done

    # Remove watcher autostart
    if [ -f "$WATCHER_AUTOSTART" ]; then
        sudo rm "$WATCHER_AUTOSTART" && info "Removed watcher autostart"
    fi

    # Re-enable xautoresize
    if [ -f "${XAUTORESIZE_AUTOSTART}.disabled" ]; then
        sudo mv "${XAUTORESIZE_AUTOSTART}.disabled" "$XAUTORESIZE_AUTOSTART" \
            && info "Re-enabled xautoresize autostart"
    fi

    echo ""
    info "Uninstall complete. Reboot or run xautoresize-launcher to restore default behavior."
    exit 0
}

# =========================================================================
# Main install/fix mode
# =========================================================================

main() {
    echo ""
    echo "  vmware-autolayout - Display Layout Manager"
    echo "  ==========================================="
    echo ""

    # --- Prompt for sudo upfront so all later sudo calls succeed ---

    if ! sudo -n true 2>/dev/null; then
        echo "  This script needs sudo for some steps."
        sudo -v || { error "sudo authentication failed"; exit 1; }
    fi

    # --- Pre-flight checks ---

    if [ "${XDG_SESSION_TYPE:-}" != "x11" ]; then
        error "This script requires an X11 session (detected: ${XDG_SESSION_TYPE:-unknown})"
        exit 1
    fi

    VIRT=$(systemd-detect-virt 2>/dev/null || echo "unknown")
    if [ "$VIRT" != "vmware" ]; then
        error "This script is for VMware VMs (detected: $VIRT)"
        exit 1
    fi

    if ! command -v xrandr &>/dev/null; then
        error "xrandr not found"
        exit 1
    fi

    if ! command -v xev &>/dev/null; then
        error "xev not found (install x11-utils)"
        exit 1
    fi

    # --- Detect connected displays ---

    CONNECTED=$(xrandr | grep ' connected' | awk '{print $1}')
    COUNT=$(echo "$CONNECTED" | wc -l)

    if [ "$COUNT" -lt 2 ]; then
        error "Only $COUNT display(s) detected. Enable multiple monitors in VMware first."
        echo "  VMware menu: View > Autosize > Autofit All Monitors"
        echo "  Or use the 'Cycle multiple monitors' toolbar button."
        exit 1
    fi

    DISPLAY1=$(echo "$CONNECTED" | sed -n '1p')
    DISPLAY2=$(echo "$CONNECTED" | sed -n '2p')

    info "Detected $COUNT connected displays: $(echo $CONNECTED | tr '\n' ' ')"

    # --- Step 1: Kill xautoresize ---

    if pgrep -x xautoresize &>/dev/null; then
        pkill -x xautoresize && info "Killed xautoresize" || warn "Failed to kill xautoresize"
        sleep 1
    else
        info "xautoresize not running"
    fi

    # --- Step 2: Disable xautoresize autostart ---

    if [ -f "$XAUTORESIZE_AUTOSTART" ]; then
        if sudo mv "$XAUTORESIZE_AUTOSTART" "${XAUTORESIZE_AUTOSTART}.disabled" 2>/dev/null; then
            info "Disabled xautoresize autostart"
        else
            warn "Could not disable xautoresize autostart (need sudo)"
        fi
    elif [ -f "${XAUTORESIZE_AUTOSTART}.disabled" ]; then
        info "xautoresize autostart already disabled"
    else
        info "xautoresize not installed"
    fi

    # --- Step 3: Configure resolutionKMS in VMware Tools ---

    NEEDS_RESTART=false
    if [ -f "$TOOLS_CONF" ]; then
        if grep -q '^\[resolutionKMS\]' "$TOOLS_CONF"; then
            if grep -q '^enable=true' "$TOOLS_CONF"; then
                info "resolutionKMS already enabled"
            else
                sudo sed -i 's/^\[resolutionKMS\]/[resolutionKMS]\nenable=true/' "$TOOLS_CONF" \
                    && { info "Enabled resolutionKMS in tools.conf"; NEEDS_RESTART=true; } \
                    || warn "Could not update tools.conf"
            fi
        else
            sudo sed -i '1i [resolutionKMS]\nenable=true\n' "$TOOLS_CONF" \
                && { info "Added resolutionKMS to tools.conf"; NEEDS_RESTART=true; } \
                || warn "Could not update tools.conf"
        fi
        if [ "$NEEDS_RESTART" = true ]; then
            sudo systemctl restart open-vm-tools.service \
                && info "Restarted open-vm-tools service" \
                || warn "Could not restart open-vm-tools"
        fi
    else
        warn "$TOOLS_CONF not found — is open-vm-tools installed?"
    fi

    # --- Step 4: Stop any existing watcher ---

    if pgrep -f "vmware-autolayout.sh --watch\|fix_multi_monitor.sh --watch\|vmware-extend-monitors.sh" &>/dev/null; then
        pkill -f "vmware-autolayout.sh --watch\|fix_multi_monitor.sh --watch\|vmware-extend-monitors.sh" 2>/dev/null
        sleep 1
        info "Stopped previous watcher"
    fi

    # --- Step 5: Set up extended display layout ---

    info "Configuring: $DISPLAY1 (left) | $DISPLAY2 (right)"

    # Use a single atomic xrandr command with explicit modes and positions
    extend_displays "$CONNECTED"
    sleep 2

    SCREEN_W=$(xrandr | head -1 | grep -oP 'current \K\d+')
    D1_MODE=$(get_preferred_mode "$DISPLAY1")
    FIRST_W=$(echo "${D1_MODE:-1920x1080}" | cut -dx -f1)

    if [ "$SCREEN_W" -gt "$FIRST_W" ] 2>/dev/null; then
        info "Extended desktop active: $(xrandr | head -1 | grep -oP 'current \K[0-9]+ x [0-9]+')"
    else
        # Retry once — VMware tools can race with xrandr
        warn "First attempt failed (${SCREEN_W}px), retrying..."
        sleep 2
        extend_displays "$CONNECTED"
        sleep 2

        SCREEN_W=$(xrandr | head -1 | grep -oP 'current \K\d+')
        if [ "$SCREEN_W" -gt "$FIRST_W" ] 2>/dev/null; then
            info "Extended desktop active: $(xrandr | head -1 | grep -oP 'current \K[0-9]+ x [0-9]+')"
        else
            error "Display layout did not apply (screen width: ${SCREEN_W:-unknown})"
            echo "  Try logging out and back in, or rebooting the VM."
            exit 1
        fi
    fi

    # --- Step 6: Install and start persistent watcher ---

    sudo tee "$WATCHER_AUTOSTART" > /dev/null << EOF
[Desktop Entry]
Type=Application
Name=VMware Autolayout
Comment=Smart display layout manager for VMware VMs
Exec=bash -c '$SCRIPT_PATH --watch > /tmp/vmware-autolayout.log 2>&1'
Hidden=false
X-XFCE-Autostart-Override=true
NoDisplay=true
EOF
    info "Installed watcher autostart"

    nohup "$SCRIPT_PATH" --watch > /tmp/vmware-autolayout.log 2>&1 &
    WATCHER_PID=$!
    sleep 2

    if kill -0 "$WATCHER_PID" 2>/dev/null; then
        info "Watcher running (PID $WATCHER_PID)"
    else
        warn "Watcher failed to start — check /tmp/vmware-autolayout.log"
    fi

    # --- Step 7: Save XFCE display config (optional, best-effort) ---

    if [ "${XDG_CURRENT_DESKTOP:-}" = "XFCE" ] && command -v xfconf-query &>/dev/null; then
        D1_RES=$(get_active_mode "$DISPLAY1")
        D2_RES=$(get_active_mode "$DISPLAY2")
        D1_X=$(xrandr | grep "^$DISPLAY1 " | grep -oP '\d+x\d+\+\K\d+' | head -1 || echo "0")
        D2_X=$(xrandr | grep "^$DISPLAY2 " | grep -oP '\d+x\d+\+\K\d+' | head -1 || echo "${FIRST_W}")

        xfconf-query -c displays -p "/Default/$DISPLAY1/Active" --create -t string -s true 2>/dev/null || true
        xfconf-query -c displays -p "/Default/$DISPLAY1/Position/X" --create -t string -s "${D1_X:-0}" 2>/dev/null || true
        xfconf-query -c displays -p "/Default/$DISPLAY1/Position/Y" --create -t string -s 0 2>/dev/null || true
        xfconf-query -c displays -p "/Default/$DISPLAY1/Resolution" --create -t string -s "${D1_RES:-1920x1080}" 2>/dev/null || true
        xfconf-query -c displays -p "/Default/$DISPLAY2/Active" --create -t string -s true 2>/dev/null || true
        xfconf-query -c displays -p "/Default/$DISPLAY2/Position/X" --create -t string -s "${D2_X:-1920}" 2>/dev/null || true
        xfconf-query -c displays -p "/Default/$DISPLAY2/Position/Y" --create -t string -s 0 2>/dev/null || true
        xfconf-query -c displays -p "/Default/$DISPLAY2/Resolution" --create -t string -s "${D2_RES:-1920x1080}" 2>/dev/null || true
        info "Saved XFCE display configuration"
    fi

    echo ""
    info "vmware-autolayout installed successfully."
    echo ""
    echo "  Layout:     $DISPLAY1 (left)  |  $DISPLAY2 (right)"
    echo "  Watcher:    Auto-extends and auto-resizes on display changes"
    echo "  Log:        /tmp/vmware-autolayout.log"
    echo "  Uninstall:  $SCRIPT_PATH --uninstall"
    echo ""
}

# =========================================================================
# Entry point
# =========================================================================

case "${1:-}" in
    --watch)     watch_mode ;;
    --uninstall) uninstall_mode ;;
    *)           main ;;
esac 