#!/bin/bash
set -euo pipefail

# Setup guide:
# 1. Go to Settings -> Custom Commands (or Edit Instance -> Settings -> Custom Commands).
# 2. Check the box for Wrapper command.
# 3. Enter the path to your script: prism_bubblewrap.sh

# 1. Grab the Java path Prism passes as the first argument
REAL_JAVA="$1"

# 2. 'shift' removes the first argument ($1) from the list,
# so "$@" now contains ONLY the actual Minecraft arguments.
shift

PRISM_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/PrismLauncher"
MANGOHUD_CONF="${MANGOHUD_CONFIGFILE:-$HOME/.config/MangoHud}"
export PULSE_SERVER="unix:$XDG_RUNTIME_DIR/pulse/native"
export ALSOFT_DRIVERS="pulse,alsa"

DISPLAY_ARGS=()

# --- X11 Display & Authentication ---
if [[ "${DISPLAY:-}" == :* ]]; then
    # Bind the entire X11 socket directory
    DISPLAY_ARGS+=(--ro-bind-try /tmp/.X11-unix /tmp/.X11-unix)

    # Resolve the Xauthority file (defaults to ~/.Xauthority if unset)
    XAUTH="${XAUTHORITY:-$HOME/.Xauthority}"

    # Mount the authentication file so GLFW has permission to draw the window
    DISPLAY_ARGS+=(--ro-bind-try "$XAUTH" "$HOME/.Xauthority")

    # Force the sandbox to look in the default home location
    export XAUTHORITY="$HOME/.Xauthority"
fi

# --- Wayland Display ---
if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    DISPLAY_ARGS+=(--ro-bind-try "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY")
fi

# Create a secure, filtered DBus socket for xdg-desktop-portal
PROXY_DIR="$(mktemp -d -t bwrap-dbus-XXXXXX)"
PROXY_SOCK="$PROXY_DIR/bus"

xdg-dbus-proxy "unix:path=$XDG_RUNTIME_DIR/bus" "$PROXY_SOCK" \
    --filter \
    --call="org.freedesktop.portal.*=*" \
    --broadcast="org.freedesktop.portal.*=@/org/freedesktop/portal/*" &
PROXY_PID=$!

# Ensure the proxy socket is cleaned up when Minecraft closes
trap "kill $PROXY_PID 2>/dev/null; rm -rf '$PROXY_DIR'" EXIT

# Wait for the socket to actually exist
timeout=20
while [ ! -S "$PROXY_SOCK" ] && [ $timeout -gt 0 ]; do
    sleep 0.1
    ((timeout--))
done

if [ ! -S "$PROXY_SOCK" ]; then
    echo "❌ Error: DBus proxy socket was not created in time."
    exit 1
fi

# Tell the sandbox to use our new proxy socket
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"

BWRAP_ARGS=(
    # --- Namespace & Process Isolation ---
    --unshare-all
    --share-net
    --new-session
    --die-with-parent

    # --- Base System (Read-Only) ---
    --ro-bind /usr /usr
    --symlink usr/lib /lib
    --symlink usr/lib64 /lib64
    --symlink usr/bin /bin
    --symlink usr/sbin /sbin
    --ro-bind /etc /etc

    # --- Ephemeral Workspaces ---
    --tmpfs /tmp
    --tmpfs /var/tmp
    --tmpfs /run
    --tmpfs "$HOME"

    # --- Hardware & GPU ---
    --dev /dev
    --dev-bind /dev/dri /dev/dri
    --dev-bind /dev/input /dev/input
    --dev-bind-try /dev/snd /dev/snd
    --ro-bind /sys /sys
    --proc /proc
    --ro-bind-try /run/udev/data /run/udev/data

    # Recreate the directory structure in the empty tmpfs
    --dir "$HOME/.config"
    --dir "$HOME/.config/pulse"
    # Mount the PulseAudio auth cookie
    --ro-bind-try "$HOME/.config/pulse/cookie" "$HOME/.config/pulse/cookie"
    # Optional: Mount OpenAL config in case you use custom HRTF/surround settings
    --ro-bind-try "$HOME/.alsoftrc" "$HOME/.alsoftrc"

    # --- Display & Audio Sockets ---
    "${DISPLAY_ARGS[@]}"
    --ro-bind-try "$XDG_RUNTIME_DIR/pipewire-0" "$XDG_RUNTIME_DIR/pipewire-0"
    --ro-bind-try "$XDG_RUNTIME_DIR/pulse" "$XDG_RUNTIME_DIR/pulse"

    # Bind our filtered proxy socket to the expected DBus path inside the sandbox
    --bind "$PROXY_SOCK" "$XDG_RUNTIME_DIR/bus"
    # Force xdg-open to use DBus portals
    --unsetenv XDG_CURRENT_DESKTOP
    --setenv DE flatpak

    # --- TIGHTENED MINECRAFT ASSETS (Read-Only) ---
    --ro-bind-try "$PRISM_DIR/libraries" "$PRISM_DIR/libraries"
    --ro-bind-try "$PRISM_DIR/assets" "$PRISM_DIR/assets"
    --ro-bind-try "$PRISM_DIR/meta" "$PRISM_DIR/meta"
    --ro-bind-try "$PRISM_DIR/java" "$PRISM_DIR/java"

    # Optional: Allow MangoHud configurations to pass through
    --ro-bind-try "$MANGOHUD_CONF" "$MANGOHUD_CONF"

    # --- Target Instance (Read/Write) ---
    --bind "$PWD" "$PWD"
)

echo "========================================="
echo "🛡️ BUBBLEWRAP SANDBOX INITIALIZING..."
echo "Java: $REAL_JAVA"
echo "Target: $PWD"
echo "========================================="
# Launch the dynamically provided Java binary inside the sandbox
exec bwrap "${BWRAP_ARGS[@]}" "$REAL_JAVA" "$@"
