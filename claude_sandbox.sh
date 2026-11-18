#!/bin/bash
set -euo pipefail

# Locate the real Claude Code binary on the host (follows symlinks, e.g.
# ~/.local/bin/claude -> ~/.local/share/claude/versions/<ver>)
CLAUDE_BIN=$(command -v claude) || { echo "claude not found in PATH" >&2; exit 1; }
CLAUDE_REAL=$(readlink -f "$CLAUDE_BIN")

# Note: the Arch package's /usr/bin/claude is a wrapper that execs
# /opt/claude-code/bin/claude, so /opt/claude-code is bound below as well.
# If it lives outside /usr (native installer, or npm with a user prefix),
# bind its install directory read-only so it is visible inside the sandbox
CLAUDE_BINDS=()
case "$CLAUDE_REAL" in
  /usr/*) ;;
  *) CLAUDE_BINDS+=(--ro-bind "$(dirname "$CLAUDE_REAL")" "$(dirname "$CLAUDE_REAL")") ;;
esac

# Ensure required config and cache directories exist
# All Claude Code state (credentials, settings, .claude.json) is kept in ~/.claude
# via CLAUDE_CONFIG_DIR, so only one directory needs to be bound
mkdir -p "$HOME/.claude"
mkdir -p "$HOME/.gradle"

# The working directory is bound read-write, so refuse to start in / or in
# $HOME (or any parent of it), which would expose the whole home dir. Also
# refuse to start inside ~/.gradle, which must stay behind its overlay
if [ "$PWD" = "/" ] || [[ "$HOME/" == "$PWD/"* ]] || [[ "$PWD/" == "$HOME/.gradle/"* ]]; then
  echo "Refusing to run in $PWD: it would be bound read-write into the sandbox" >&2
  exit 1
fi

# Start from an empty environment (--clearenv) and only pass through what the
# terminal UI, locale and Java need. Everything else (DBUS/Wayland/X11
# addresses, session info, tokens from the shell profile, ...) stays outside
ENV_PASS=()
for var in TERM COLORTERM COLORFGBG KONSOLE_VERSION LANG LANGUAGE TZ \
           _JAVA_OPTIONS $(compgen -e LC_ || true); do
  if [ -n "${!var+x}" ]; then
    ENV_PASS+=(--setenv "$var" "${!var}")
  fi
done

# Dynamically find and bind all Arch Linux Java configuration directories
# Matches both the old (java-8-openjdk) and new (java17-openjdk) naming schemes
JAVA_ETC_BINDS=()
for conf_dir in /etc/java*; do
  if [ -d "$conf_dir" ]; then
    JAVA_ETC_BINDS+=(--ro-bind "$conf_dir" "$conf_dir")
  fi
done

# fds 3 and 4 (empty, from /dev/null) feed the --ro-bind-data mounts that
# hide the Gradle secrets as empty read-only regular files. Binding /dev/null
# itself does not work: bwrap mounts binds nodev, so opening it fails with EACCES
exec systemd-run --user --scope \
  -p TasksMax=2048 \
  -p MemoryMax=8G \
  bwrap \
  --unshare-all \
  --share-net \
  --die-with-parent \
  --uid "$(id -u)" \
  --gid "$(id -g)" \
  --ro-bind /usr /usr \
  --ro-bind-try /opt/claude-code /opt/claude-code \
  --symlink usr/bin /bin \
  --symlink usr/sbin /sbin \
  --symlink usr/lib /lib \
  --symlink usr/lib64 /lib64 \
  --ro-bind /etc/resolv.conf /etc/resolv.conf \
  --ro-bind-try /etc/hosts /etc/hosts \
  --ro-bind-try /etc/localtime /etc/localtime \
  --ro-bind /etc/ssl /etc/ssl \
  --ro-bind-try /etc/ca-certificates /etc/ca-certificates \
  --ro-bind /etc/passwd /etc/passwd \
  "${JAVA_ETC_BINDS[@]}" \
  --proc /proc \
  --dev /dev \
  --tmpfs /tmp \
  --tmpfs /run \
  --tmpfs "$HOME" \
  "${CLAUDE_BINDS[@]}" \
  --bind "$HOME/.claude" "$HOME/.claude" \
  --overlay-src "$HOME/.gradle" \
  --tmp-overlay "$HOME/.gradle" \
  --ro-bind-data 3 "$HOME/.gradle/secring.gpg" \
  --ro-bind-data 4 "$HOME/.gradle/gradle.properties" \
  --ro-bind-try "$HOME/.gitconfig" "$HOME/.gitconfig" \
  --bind "$PWD" "$PWD" \
  --chdir "$PWD" \
  --clearenv \
  "${ENV_PASS[@]}" \
  --setenv JAVA_HOME "/usr/lib/jvm/default" \
  --setenv PATH "/usr/bin" \
  --setenv HOME "$HOME" \
  --setenv USER "$USER" \
  --setenv CLAUDE_CONFIG_DIR "$HOME/.claude" \
  --setenv DISABLE_AUTOUPDATER 1 \
  "$CLAUDE_REAL" "$@" \
  3</dev/null 4</dev/null
