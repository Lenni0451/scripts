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
export PULSE_SERVER="unix:$XDG_RUNTIME_DIR/pulse/native"
export ALSOFT_DRIVERS="pulse,alsa"
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

    # --- Hardware & GPU ---
    --dev-bind /dev /dev
    --ro-bind /sys /sys
    --proc /proc

    # --- Ephemeral Workspaces ---
    --tmpfs /tmp
    --tmpfs /var/tmp
    --tmpfs /run
    --tmpfs "$HOME"

    # Recreate the directory structure in the empty tmpfs
    --dir "$HOME/.config"
    --dir "$HOME/.config/pulse"
    # Mount the PulseAudio auth cookie
    --ro-bind-try "$HOME/.config/pulse/cookie" "$HOME/.config/pulse/cookie"
    # Optional: Mount OpenAL config in case you use custom HRTF/surround settings
    --ro-bind-try "$HOME/.alsoftrc" "$HOME/.alsoftrc"

    # --- Display & Audio Sockets ---
    --ro-bind-try "$XDG_RUNTIME_DIR/wayland-0" "$XDG_RUNTIME_DIR/wayland-0"
    --ro-bind-try "$XDG_RUNTIME_DIR/wayland-1" "$XDG_RUNTIME_DIR/wayland-1"
    --ro-bind-try /tmp/.X11-unix /tmp/.X11-unix
    --ro-bind-try "$XAUTHORITY" "$XAUTHORITY"
    --ro-bind-try "$XDG_RUNTIME_DIR/pipewire-0" "$XDG_RUNTIME_DIR/pipewire-0"
    --ro-bind-try "$XDG_RUNTIME_DIR/pulse" "$XDG_RUNTIME_DIR/pulse"

    # --- TIGHTENED MINECRAFT ASSETS (Read-Only) ---
    --ro-bind-try "$PRISM_DIR/libraries" "$PRISM_DIR/libraries"
    --ro-bind-try "$PRISM_DIR/assets" "$PRISM_DIR/assets"
    --ro-bind-try "$PRISM_DIR/meta" "$PRISM_DIR/meta"
    --ro-bind-try "$PRISM_DIR/java" "$PRISM_DIR/java"

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
