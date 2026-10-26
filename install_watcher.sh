#!/bin/sh
# Install (or remove) the cron line that runs update_watcher.sh every minute, which is what
# lets the portal's Updates tab apply a new version. [FEATURE: IN-APP UPDATE]
# SEARCH TAGS: install watcher, cron, crontab, update watcher, in-app update
#
# Usage: sh install_watcher.sh            (idempotent: re-running leaves one line)
#        sh install_watcher.sh --remove
#
# The line goes in the crontab of the account that runs docker -- the invoking user, or under
# sudo the user who ran sudo -- never root's: update.sh is meant to run as the operator.
# Mutates: that user's crontab -- only the line naming THIS bundle's update_watcher.sh; every
# other line, another bundle's watcher included, is kept.
set -eu
cd "$(dirname "$0")"

# The account whose crontab is written, and the one named in every message: as root that is
# the sudo caller (root itself is refused below); otherwise the real account, not the USER
# variable, which an environment can set to anything.
if [ "$(id -u)" -eq 0 ]; then
  TARGET_USER="${SUDO_USER:-root}"
else
  TARGET_USER=$(id -un)
fi
BUNDLE_DIR=$(pwd -P)
WATCHER="$BUNDLE_DIR/update_watcher.sh"
# What identifies this bundle's line: the quoted path, so /srv/a never matches /srv/x/srv/a.
WATCHER_REF="sh '$WATCHER'"
CRON_LINE="* * * * * $WATCHER_REF >/dev/null 2>&1"

REMOVE=0
case "${1:-}" in
  '') ;;
  --remove) REMOVE=1 ;;
  *)
    echo "usage: sh install_watcher.sh [--remove]" >&2
    exit 2
    ;;
esac
if [ "$#" -gt 1 ]; then
  echo "usage: sh install_watcher.sh [--remove]" >&2
  exit 2
fi

if ! command -v crontab >/dev/null 2>&1; then
  echo "crontab is not installed on this host." >&2
  echo "  Install cron, for example:  sudo apt-get install cron" >&2
  exit 2
fi

if [ "$TARGET_USER" = "root" ]; then
  echo "refusing to install the watcher for root; it must run as the account that runs docker." >&2
  echo "  Run this as that account (in the docker group), or with sudo from it." >&2
  exit 2
fi

# Only root may name another user's table; a plain user edits their own without -u.
user_crontab() {
  if [ "$(id -u)" -eq 0 ]; then
    crontab -u "$TARGET_USER" "$@"
  else
    crontab "$@"
  fi
}

# `crontab -l` exits 1 when the user has no table yet; that is an empty table, not an error.
CURRENT=$(user_crontab -l 2>/dev/null) || CURRENT=""
OTHERS=$(printf '%s\n' "$CURRENT" | grep -vF "$WATCHER_REF") || OTHERS=""

if [ "$REMOVE" -eq 1 ]; then
  if ! printf '%s\n' "$CURRENT" | grep -F "$WATCHER_REF" >/dev/null; then
    echo "no update watcher is installed for $TARGET_USER."
    exit 0
  fi
  if [ -n "$OTHERS" ]; then
    printf '%s\n' "$OTHERS" | user_crontab -
  else
    printf '' | user_crontab -
  fi
  echo "removed the update watcher from $TARGET_USER's crontab."
  exit 0
fi

# The path goes inside single quotes on the cron line, and cron turns an unescaped % into a
# newline, so either character would break the line.
case "$WATCHER" in
  *\'*|*%*)
    echo "the bundle path contains ' or %, which a cron line cannot carry: $BUNDLE_DIR" >&2
    echo "  Move the bundle to a plainer folder and re-run." >&2
    exit 2
    ;;
esac
if [ ! -f "$WATCHER" ]; then
  echo "update_watcher.sh is missing from $BUNDLE_DIR." >&2
  exit 2
fi

if [ -n "$OTHERS" ]; then
  WANTED=$(printf '%s\n%s' "$OTHERS" "$CRON_LINE")
else
  WANTED="$CRON_LINE"
fi
if [ "$WANTED" = "$CURRENT" ]; then
  echo "the update watcher is already installed for $TARGET_USER:"
else
  printf '%s\n' "$WANTED" | user_crontab -
  echo "installed the update watcher for $TARGET_USER:"
fi
echo "  $CRON_LINE"
echo "Remove it with:  sh install_watcher.sh --remove"
