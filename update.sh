#!/bin/sh
# Update the portal to the version in portal.env. Backup first, fetch, restart, verify.
# Usage: sh update.sh                                 (reads PORTAL_VERSION from portal.env)
#        sh update.sh 1.2.3                           (also rewrites PORTAL_VERSION)
#        sh update.sh 1.2.3 --tarball portal-1.2.3.tar (air-gapped: load, never pull)
#   portal-<version>.tar in this folder is used automatically when you name that version.
set -eu
cd "$(dirname "$0")"

# Docker Desktop ends a failed docker command with a "docker ai" upsell; silence it.
export DOCKER_CLI_HINTS=false

# >>> shared preflight: byte-identical in install.sh and update.sh, pinned by a test >>>
# The bundle is four standalone scripts with no library file between them, so this block is
# duplicated rather than sourced. Every failure here is exit 2 plus the one command that
# fixes it: a customer either has Docker or does not, and there is nothing to undo.
require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker is not installed, or not on this shell's PATH." >&2
    echo "  Install Docker Engine: https://docs.docker.com/engine/install/" >&2
    exit 2
  fi
  docker_err=$(docker info 2>&1 >/dev/null) || {
    case "$docker_err" in
      *ermission\ denied*)
        echo "this account may not talk to the docker daemon." >&2
        echo "  Add yourself to the docker group, then log out and back in:" >&2
        echo "    sudo usermod -aG docker \$USER" >&2
        ;;
      *)
        echo "the docker daemon is not reachable." >&2
        echo "  Start it:  sudo systemctl start docker" >&2
        echo "  Check it:  docker info" >&2
        ;;
    esac
    exit 2
  }
}

#: Where the compose plugin lives inside the portal image (Dockerfile copies it there).
COMPOSE_IN_IMAGE="/opt/compose/docker-compose"

# True when the `docker compose` subcommand resolves at all.
have_compose() {
  docker compose version >/dev/null 2>&1
}

# Where a copied plugin must land for THIS user's docker to find it. docker reads
# $DOCKER_CONFIG/cli-plugins, defaulting to $HOME/.docker/cli-plugins, before the system
# directories a distro package would use, so honouring DOCKER_CONFIG is not optional.
# Under `sudo sh install.sh` sudo resets HOME, so this resolves to /root/.docker/cli-plugins
# -- which is also where the sudo'd docker calls later in the same script look, so the run is
# self-consistent either way. It does mean a plugin installed under sudo is invisible to the
# same person running `docker compose` as themselves afterwards, which is why the installer
# prints the path it used.
# Both are tested with ${VAR:-}: a bare $HOME under `set -u` aborts with "parameter not set"
# in the one environment (cron, a bare `env -i` shell) where the diagnosis matters most.
# NOTE this runs in a command substitution, where `exit` leaves only the subshell -- every
# caller is `PLUGIN_DIR=$(compose_plugin_dir) || exit 2`.
compose_plugin_dir() {
  if [ -n "${DOCKER_CONFIG:-}" ]; then
    echo "${DOCKER_CONFIG}/cli-plugins"
    return 0
  fi
  if [ -n "${HOME:-}" ]; then
    echo "${HOME}/.docker/cli-plugins"
    return 0
  fi
  echo "neither DOCKER_CONFIG nor HOME is set, so there is nowhere docker looks for a plugin." >&2
  echo "  Set one and re-run, for example:  HOME=/root sh install.sh <version>" >&2
  return 2
}

# Health wait, run INSIDE the container: the image's own python does the GET -- the same probe
# as the compose healthcheck -- so the host needs no curl or wget. 30 tries, 2s apart.
wait_for_health() {
  health_try=0
  until compose exec -T portal python -c \
      "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health')" \
      >/dev/null 2>&1; do
    health_try=$((health_try+1))
    if [ "$health_try" -ge 30 ]; then
      echo "portal did not come up; see: $COMPOSE_CMD logs portal" >&2
      return 1
    fi
    sleep 2
  done
}
# <<< shared preflight <<<

require_docker

if [ ! -f portal.env ]; then
  echo "portal.env is missing; this host is not installed. Use: sh install.sh <version>" >&2
  exit 2
fi

# Arguments first, so a typo refuses before anything is read or written. A tarball host was
# installed with `install.sh --tarball` and cannot reach the registry at all, so pulling
# there fails AFTER the backup has run and leaves the operator mid-update with no way forward.
NEW_VERSION=""
TARBALL=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tarball)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "--tarball needs a file path" >&2
        exit 2
      fi
      TARBALL="$2"
      shift 2
      ;;
    -*)
      echo "unknown option: $1" >&2
      echo "usage: sh update.sh [<version>] [--tarball <file>]" >&2
      exit 2
      ;;
    *)
      if [ -n "$NEW_VERSION" ]; then
        echo "unexpected argument: $1" >&2
        exit 2
      fi
      NEW_VERSION="$1"
      shift
      ;;
  esac
done
if [ -n "$TARBALL" ] && [ ! -f "$TARBALL" ]; then
  echo "no such tarball: $TARBALL" >&2
  exit 2
fi
# Named a version and its tarball is right here: use it. An offline host has no registry
# credentials, so pulling because the flag was left off is a dead end. A bare `sh update.sh`
# keeps its meaning -- re-apply the version already in portal.env -- and never guesses.
if [ -z "$TARBALL" ] && [ -n "$NEW_VERSION" ] && [ -f "portal-$NEW_VERSION.tar" ]; then
  TARBALL="portal-$NEW_VERSION.tar"
  echo "Using $TARBALL found in this folder."
fi

# Read as text, never sourced. `. ./portal.env` would execute a file of secrets as shell, so a
# pasted AWS secret or Entra id containing a space, a backtick or $(...) would run as the
# operator at update time. Same `sed -n` form install.sh uses on the template. These are for
# the messages below only -- Compose reads the file itself through --env-file.
# INSTALLED_VERSION is read BEFORE the version pin below rewrites it, because the compose
# hint must name an image this host actually has. Everything that can refuse runs first, so a
# refusal leaves portal.env byte-for-byte as it was and there is nothing to undo.
PORTAL_IMAGE=$(sed -n 's/^PORTAL_IMAGE=//p' portal.env)
INSTALLED_VERSION=$(sed -n 's/^PORTAL_VERSION=//p' portal.env)

# An update never installs anything: install.sh provisions the plugin, and a host that lost
# it since then gets the exact commands back rather than a surprise write.
if ! have_compose; then
  PLUGIN_DIR=$(compose_plugin_dir) || exit 2
  echo "the docker compose plugin is missing on this host." >&2
  echo "  Put it back from the portal image (nothing is downloaded):" >&2
  echo "    mkdir -p $PLUGIN_DIR" >&2
  echo "    CID=\$(docker create ${PORTAL_IMAGE}:${INSTALLED_VERSION})" >&2
  echo "    docker cp \$CID:$COMPOSE_IN_IMAGE $PLUGIN_DIR/docker-compose" >&2
  echo "    docker rm -f \$CID" >&2
  echo "    chmod +x $PLUGIN_DIR/docker-compose" >&2
  exit 2
fi

if [ -n "$NEW_VERSION" ]; then
  # Only a strict version charset reaches sed: & expands to the whole match and / ends the
  # replacement, so either inside the argument would corrupt portal.env.
  case "$NEW_VERSION" in
    *[!0-9A-Za-z._-]*) echo "bad version: $NEW_VERSION" >&2; exit 2 ;;
  esac
  # With no such line the substitution matches nothing, and the update would report success
  # while still running the old tag. Refuse instead of updating to a version nobody set.
  if ! grep -q '^PORTAL_VERSION=' portal.env; then
    echo "portal.env has no PORTAL_VERSION= line; cannot pin version $NEW_VERSION." >&2
    exit 2
  fi
  sed -i.bak "s/^PORTAL_VERSION=.*/PORTAL_VERSION=$NEW_VERSION/" portal.env && rm -f portal.env.bak
fi
PORTAL_VERSION=$(sed -n 's/^PORTAL_VERSION=//p' portal.env)

# Compose substitutes ${PORTAL_IMAGE}:${PORTAL_VERSION} in docker-compose.yml from the process
# environment, a file literally named `.env`, or --env-file, and from nothing else. The
# service's `env_file: portal.env` populates the CONTAINER, not that substitution, and this
# bundle never creates a `.env`. Every compose call goes through here so the flag cannot be
# dropped from one of them.
compose() {
  docker compose --env-file portal.env "$@"
}
#: What to tell an operator to type; keep in step with `compose` above.
COMPOSE_CMD="docker compose --env-file portal.env"

mkdir -p data/backups
echo "== backup"
compose exec -T portal python -m dev_tools.db_backup \
  --db /data/runtime/review_portal/review_portal.db --out /data/backups --keep 14

if [ -n "$TARBALL" ]; then
  echo "== load $TARBALL"
  docker load -i "$TARBALL"
else
  echo "== pull ${PORTAL_IMAGE}:${PORTAL_VERSION}"
  compose pull
fi
echo "== restart"
compose up -d

echo "== health"
wait_for_health || exit 1
echo "portal ${PORTAL_VERSION} is up"
