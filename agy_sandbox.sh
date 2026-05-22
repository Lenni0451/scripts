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

# Expose D-Bus so the CLI can talk to the host's secret service (keyring)
DBUS_BINDS=()
if [ -n "$XDG_RUNTIME_DIR" ] && [ -S "$XDG_RUNTIME_DIR/bus" ]; then
  # Recreate the runtime directory structure on the tmpfs before binding the socket
  DBUS_BINDS+=(--dir "$XDG_RUNTIME_DIR" --bind "$XDG_RUNTIME_DIR/bus" "$XDG_RUNTIME_DIR/bus")
fi

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
