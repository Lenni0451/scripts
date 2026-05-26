#!/bin/bash

# Ensure required config and cache directories exist
mkdir -p "$HOME/.gemini"
mkdir -p "$HOME/.gradle"

# Dynamically find and bind all Arch Linux Java configuration directories
# Matches both the old (java-8-openjdk) and new (java17-openjdk) naming schemes
JAVA_ETC_BINDS=()
for conf_dir in /etc/java*; do
  if [ -d "$conf_dir" ]; then
    JAVA_ETC_BINDS+=(--ro-bind "$conf_dir" "$conf_dir")
  fi
done

# Expose a D-Bus Proxy so the CLI can talk to the host's secret service (keyring)
# 1. Create a temporary directory for the filtered proxy socket
PROXY_DIR=$(mktemp -d -t dbus-proxy-XXXXXX)
PROXY_SOCKET="$PROXY_DIR/bus"

# 2. Spin up the proxy in the background
# --filter blocks everything by default
# --talk=org.freedesktop.secrets explicitly allows keyring access
xdg-dbus-proxy "$XDG_RUNTIME_DIR/bus" "$PROXY_SOCKET" \
    --filter \
    --talk=org.freedesktop.secrets &
PROXY_PID=$!

# Ensure the proxy dies when your script exits
trap 'kill $PROXY_PID; rm -rf "$PROXY_DIR"' EXIT

DBUS_BINDS=()
if [ -n "$XDG_RUNTIME_DIR" ]; then
  DBUS_BINDS+=(--dir "$XDG_RUNTIME_DIR" --bind "$PROXY_SOCKET" "$XDG_RUNTIME_DIR/bus")
fi

systemd-run --user --scope \
  -p TasksMax=2048 \
  -p MemoryMax=8G \
  bwrap \
  --unshare-all \
  --share-net \
  --uid "$(id -u)" \
  --gid "$(id -g)" \
  --ro-bind /usr /usr \
  --symlink usr/bin /bin \
  --symlink usr/sbin /sbin \
  --symlink usr/lib /lib \
  --symlink usr/lib64 /lib64 \
  --ro-bind /etc/resolv.conf /etc/resolv.conf \
  --ro-bind /etc/ssl /etc/ssl \
  --ro-bind /etc/ca-certificates /etc/ca-certificates \
  --ro-bind /etc/passwd /etc/passwd \
  "${JAVA_ETC_BINDS[@]}" \
  --proc /proc \
  --dev /dev \
  --tmpfs /tmp \
  --tmpfs /run \
  --tmpfs "$HOME" \
  "${DBUS_BINDS[@]}" \
  --bind "$HOME/.gemini" "$HOME/.gemini" \
  --bind "$HOME/.gradle" "$HOME/.gradle" \
  --bind "$PWD" "$PWD" \
  --chdir "$PWD" \
  --tmpfs "$PWD/.antigravitycli" \
  --setenv JAVA_HOME "/usr/lib/jvm/default" \
  --setenv PATH "/usr/bin" \
  --setenv HOME "$HOME" \
  --setenv USER "$USER" \
  --setenv DBUS_SESSION_BUS_ADDRESS "$DBUS_SESSION_BUS_ADDRESS" \
  agy --dangerously-skip-permissions "$@"
