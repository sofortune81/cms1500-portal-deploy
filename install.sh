#!/bin/sh
# First install of the CMS-1500 review portal on a Linux host. [FEATURE: INSTALLER]
# Fetches the image, runs the in-image configurator (licence terms, settings, licence file),
# starts the portal, creates the first administrator.
#
# Usage: sh install.sh                                  (uses the portal-*.tar in this folder,
#                                                        else asks for the version)
#        sh install.sh <version>
#        sh install.sh <version> --tarball portal-<version>.tar
#        any of the above, plus configurator flags (--no-checkin, --auth-mode entra, ...)
#
# The only host tool required is docker: every python step runs inside the image, so a
# minimal host without curl or wget installs fine.
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

# portal.env doubles as the "this host is installed" sentinel. Re-running would regenerate
# PORTAL_SECRET_KEY, which makes the stored AWS-connection secret unreadable with no recovery
# (review_portal/secret_box.py). The configurator refuses too; refusing here as well means an
# installed host never reaches the registry sign-in.
if [ -f portal.env ]; then
  echo "portal.env exists; this host is installed. Use: sh update.sh <version>" >&2
  exit 3
fi

# -- what to install, and where the image comes from.
# A customer types `sh install.sh` and nothing else, so resolve in this order: an explicit
# version argument; the single portal-<version>.tar sitting in this folder; a prompt, when
# there is a terminal to prompt on.
VERSION=""
TARBALL=""
case "${1:-}" in
  "") ;;
  -*) ;;             # a configurator flag, never a version -- `sh install.sh --no-checkin`
  *) VERSION="$1"; shift ;;
esac
# `--tarball <file>` still comes straight after the version, as the emails document.
if [ "${1:-}" = "--tarball" ]; then
  if [ "$#" -lt 2 ] || [ -z "$2" ]; then
    echo "--tarball needs a file path" >&2
    exit 2
  fi
  TARBALL="$2"
  shift 2
fi

if [ -z "$TARBALL" ]; then
  # Counted with a loop, not `set --`: "$@" still holds the configurator flags. An unmatched
  # glob stays literal, which is what the -f test filters out.
  TAR_COUNT=0
  TAR_ONE=""
  for f in portal-*.tar; do
    [ -f "$f" ] || continue
    TAR_COUNT=$((TAR_COUNT+1))
    TAR_ONE="$f"
  done
  if [ -n "$VERSION" ]; then
    # A tarball customer has no registry credentials, so sending them to `docker login`
    # because they left the flag off is a dead end. A tar for any OTHER version is ignored.
    if [ -f "portal-$VERSION.tar" ]; then
      TARBALL="portal-$VERSION.tar"
      echo "Using $TARBALL found in this folder."
    fi
  elif [ "$TAR_COUNT" -gt 1 ]; then
    echo "more than one portal-*.tar in this folder, so which version is not obvious:" >&2
    for f in portal-*.tar; do
      [ -f "$f" ] && echo "  $f" >&2
    done
    echo "Name the one you want:  sh install.sh <version>" >&2
    exit 2
  elif [ "$TAR_COUNT" -eq 1 ]; then
    TARBALL="$TAR_ONE"
    VERSION=${TARBALL#portal-}
    VERSION=${VERSION%.tar}
    echo "Using $TARBALL found in this folder (version $VERSION)."
  fi
fi

if [ -z "$VERSION" ] && [ -t 0 ]; then
  printf "Version to install (from your onboarding email): "
  read -r VERSION || VERSION=""
fi
if [ -z "$VERSION" ]; then
  echo "usage: sh install.sh [<version>] [--tarball <file>] [configurator flags...]" >&2
  echo "  With no version: put portal-<version>.tar in this folder, or run this from a" >&2
  echo "  terminal and it will ask. The version is in your onboarding email." >&2
  exit 2
fi
# The same charset check whether the version was typed, passed, or read off a file name.
case "$VERSION" in
  *[!0-9A-Za-z._-]*) echo "bad version: $VERSION" >&2; exit 2 ;;
esac

if [ ! -f portal.env.template ]; then
  echo "portal.env.template is missing; run this from the unpacked deployment bundle." >&2
  exit 2
fi
IMAGE=$(sed -n 's/^PORTAL_IMAGE=//p' portal.env.template)
if [ -z "$IMAGE" ]; then
  echo "no PORTAL_IMAGE= line in portal.env.template; run this from the unpacked bundle." >&2
  exit 2
fi

# Compose substitutes ${PORTAL_IMAGE}:${PORTAL_VERSION} in docker-compose.yml from the process
# environment, a file literally named `.env`, or --env-file, and from nothing else. The
# service's `env_file: portal.env` populates the CONTAINER, not that substitution, and this
# bundle never creates a `.env`. Without the flag `up` dies on "invalid reference format"
# AFTER the configurator has written portal.env, at which point install.sh refuses to re-run
# and the host is wedged. Every compose call goes through here so the flag cannot be dropped
# from one of them.
compose() {
  docker compose --env-file portal.env "$@"
}
#: What to tell an operator to type; keep in step with `compose` above.
COMPOSE_CMD="docker compose --env-file portal.env"

# -- get the image (the one step a licence-gated download would replace)
if [ -n "$TARBALL" ]; then
  if [ ! -f "$TARBALL" ]; then
    echo "no such tarball: $TARBALL" >&2
    exit 2
  fi
  echo "== load $TARBALL"
  docker load -i "$TARBALL"
else
  echo "== registry sign-in (username and token from your second onboarding email)"
  docker login ghcr.io
  docker pull "${IMAGE}:${VERSION}"
fi

# -- compose plugin. The image carries one, so a host with Docker Engine but no compose
# plugin -- every distro `docker.io` package, including the dev WSL box -- needs no download
# and no network at all, and a --tarball install still works air-gapped. Only reached when
# `docker compose` does not already resolve, so a working plugin is never touched.
if ! have_compose; then
  echo "== docker compose plugin (missing; taking the one inside the image)"
  PLUGIN_DIR=$(compose_plugin_dir) || exit 2
  mkdir -p "$PLUGIN_DIR" || {
    echo "cannot create $PLUGIN_DIR." >&2
    echo "  A root-owned ~/.docker is the usual cause -- an earlier 'sudo docker' made it." >&2
    echo '  Fix it with:  sudo chown -R "$USER" "$HOME/.docker"' >&2
    exit 2
  }
  # `docker create` + `docker cp`, not a `-v "$HOME/...:/out"` bind mount. docker cp writes
  # through the CLI as the calling user: it needs no --user, the daemon cannot pre-create the
  # directory root-owned, and it lands on the CLIENT's filesystem. A bind mount is resolved by
  # the DAEMON, so on a rootless, VM-backed or remote daemon the same path is a different
  # filesystem and the plugin would be written somewhere the CLI never looks.
  # The trap, not just the `docker rm` below: between create and rm the script can leave by
  # `set -e`, by an explicit exit, or by Ctrl-C, and a stopped container left behind would
  # confuse the next run and hold a whole image layer set.
  CLEANUP_CID=""
  trap 'if [ -n "$CLEANUP_CID" ]; then docker rm -f "$CLEANUP_CID" >/dev/null 2>&1 || true; fi' EXIT INT TERM
  CID=$(docker create "${IMAGE}:${VERSION}") || {
    echo "could not create a container from ${IMAGE}:${VERSION} to copy the plugin out of." >&2
    echo "  Check the image is present:  docker image inspect ${IMAGE}:${VERSION}" >&2
    exit 2
  }
  CLEANUP_CID="$CID"
  COPY_STATUS=0
  docker cp "$CID:$COMPOSE_IN_IMAGE" "$PLUGIN_DIR/docker-compose" || COPY_STATUS=$?
  docker rm -f "$CID" >/dev/null 2>&1 || true
  CLEANUP_CID=""
  trap - EXIT INT TERM
  if [ "$COPY_STATUS" -ne 0 ]; then
    echo "could not copy $COMPOSE_IN_IMAGE out of ${IMAGE}:${VERSION}." >&2
    echo "  Install the plugin yourself: sudo apt-get install docker-compose-plugin" >&2
    exit 2
  fi
  chmod +x "$PLUGIN_DIR/docker-compose"
  if ! have_compose; then
    # Run it once: the commonest cause of a copied-but-dead plugin is an image built for
    # another CPU, and "exec format error" is a far better message than a path to try.
    RECHECK=$("$PLUGIN_DIR/docker-compose" version 2>&1) || true
    case "$RECHECK" in
      *xec\ format\ error*|*cannot\ execute\ binary\ file*)
        IMAGE_ARCH=$(docker image inspect "${IMAGE}:${VERSION}" --format '{{.Architecture}}' 2>/dev/null || echo unknown)
        echo "wrong architecture: the image is $IMAGE_ARCH, this host is $(uname -m)." >&2
        echo "  Ask us for a $(uname -m) build, or run the installer on a matching host." >&2
        ;;
      *)
        echo "copied the plugin to $PLUGIN_DIR/docker-compose but 'docker compose version' still fails." >&2
        echo "  Try it directly: $PLUGIN_DIR/docker-compose version" >&2
        echo "  Or install the distro package: sudo apt-get install docker-compose-plugin" >&2
        ;;
    esac
    exit 2
  fi
  echo "Installed the docker compose plugin to $PLUGIN_DIR/docker-compose, out of the portal"
  echo "image -- nothing was downloaded. It belongs to this user; another user running docker"
  echo "on this host needs its own copy."
fi

# The configurator takes the licence from a *.lic file in this folder when there is one, and
# otherwise reads a pasted one from stdin. `docker run -t` needs a terminal: on a scripted
# install (all answers as flags, licence via --licence-file or a pipe) there is none, and -t
# would fail with "the input device is not a TTY" instead of reading the pipe. -i is always
# wanted so stdin reaches the container.
if [ -t 0 ]; then
  TTY_FLAGS="-it"
else
  TTY_FLAGS="-i"
fi

echo "== configure"
# --user: the configurator writes portal.env and data/portal.lic through the bind mount.
# Without it the container runs as root and those files land root-owned on the host.
# The image sets PYTHONPATH=/app, so -m resolves from WORKDIR /data; it has a CMD and no
# ENTRYPOINT, so --entrypoint python replaces the whole command.
CONFIGURE_STATUS=0
# shellcheck disable=SC2086  # TTY_FLAGS is a deliberate one-or-two-flag word split
docker run --rm $TTY_FLAGS --user "$(id -u):$(id -g)" -v "$PWD:/work" --entrypoint python \
  "${IMAGE}:${VERSION}" -m dev_tools.install_configurator --version "$VERSION" --host-os linux "$@" \
  || CONFIGURE_STATUS=$?
if [ "$CONFIGURE_STATUS" -ne 0 ]; then
  # 2 invalid input, 3 already installed, 4 licence terms declined. Nothing was written and
  # nothing is started; the message above this line came from the configurator itself.
  echo "configuration did not complete (exit $CONFIGURE_STATUS); the portal was not started." >&2
  exit "$CONFIGURE_STATUS"
fi

# Read as text, never sourced: portal.env holds the AWS secret and PORTAL_SECRET_KEY, and
# sourcing would execute it as shell. Compose reads the file itself through --env-file; these
# three reads decide whether the proxy is expected and what to say about it.
PROFILES=$(sed -n 's/^COMPOSE_PROFILES=//p' portal.env)
HOSTNAME_SET=$(sed -n 's/^PORTAL_HOSTNAME=//p' portal.env)
TLS_MODE=$(sed -n 's/^PORTAL_TLS_MODE=//p' portal.env)

# Port preflight, only when the proxy will run: it publishes 80 and 443, so a container
# already holding either would fail `up` after everything else succeeded. Only docker-held
# ports are visible here; a non-docker listener is caught by the HTTPS wait below, so
# this does not depend on ss or netstat being installed.
if [ "$PROFILES" = "tls" ]; then
  for p in 80 443; do
    if docker ps --format '{{.Ports}}' | grep -q "[:.]$p->"; then
      echo "port $p is already in use by another container; free it or re-run with --tls-mode none" >&2
      exit 2
    fi
  done
fi

echo "== start"
compose up -d

echo "== health"
wait_for_health || exit 1

if [ "$PROFILES" = "tls" ]; then
  echo "== https"
  i=0
  until compose exec -T proxy wget -q -O /dev/null http://portal:8000/health 2>/dev/null; do
    i=$((i+1))
    if [ "$i" -ge 30 ]; then
      echo "the HTTPS proxy did not come up; see: $COMPOSE_CMD logs proxy" >&2
      echo "(if it says a port is already in use, another web server holds 80 or 443)" >&2
      exit 1
    fi
    sleep 2
  done
  echo "The portal is served at https://$HOSTNAME_SET"
  if [ "$TLS_MODE" = "internal" ]; then
    echo "Browsers will warn until they trust the portal's own certificate authority:"
    echo "  caddy-data/caddy/pki/authorities/local/root.crt   (import it as a trusted root on each PC)"
  fi
fi

echo "== first administrator"
# Read as text, never sourced. In entra mode a password is refused for every id but the
# break-glass one (review_portal/auth.py, ENTRA_REQUIRED_CODE), so the activation token that
# `create` prints is useless and the account has to be pre-bound to the administrator's
# Microsoft address -- otherwise their first Microsoft sign-in creates a SECOND, inactive
# account, and there is no active admin left who could activate it.
AUTH_MODE=$(sed -n 's/^AUTH_MODE=//p' portal.env)

# `read` returns non-zero at EOF (no terminal, or the operator pressed Ctrl-D) after still
# assigning whatever it got, so `|| true` keeps set -e from killing the script here and the
# emptiness check below handles it with a retry hint.
ADMIN_ID=""
ADMIN_NAME=""
ADMIN_UPN=""
printf "Administrator sign-in id: "
read -r ADMIN_ID || true
printf "Administrator display name: "
read -r ADMIN_NAME || true
if [ "$AUTH_MODE" = "entra" ]; then
  printf "Administrator Microsoft sign-in address (user@domain): "
  read -r ADMIN_UPN || true
fi

ADMIN_DB="/data/runtime/review_portal/review_portal.db"

# portal.env exists from here on, so install.sh refuses to run again. Every way this step can
# fail therefore has to hand the operator the commands that finish the job -- and in entra
# mode that is two commands, because create alone leaves an unreachable account.
admin_retry_hint() {
  echo "The portal is installed and running, but it has no administrator and install.sh will" >&2
  echo "now refuse to re-run. Create the first administrator with:" >&2
  echo "  $COMPOSE_CMD exec -T portal python -m dev_tools.portal_user_admin \\" >&2
  echo "    --db $ADMIN_DB create <sign-in-id> '<display name>' --role admin" >&2
  if [ "$AUTH_MODE" = "entra" ]; then
    echo "  $COMPOSE_CMD exec -T portal python -m dev_tools.portal_user_admin \\" >&2
    echo "    --db $ADMIN_DB set-upn <sign-in-id> <user@domain>" >&2
    echo "  Both are needed in entra mode: the second binds the account to the Microsoft" >&2
    echo "  address, so signing in lands on it instead of creating a new inactive account." >&2
  fi
}

if [ -z "$ADMIN_ID" ] || [ -z "$ADMIN_NAME" ]; then
  echo "no administrator details given." >&2
  admin_retry_hint
  exit 1
fi
# Checked BEFORE create, so entra mode never leaves a created-but-unbound account behind.
if [ "$AUTH_MODE" = "entra" ]; then
  case "$ADMIN_UPN" in
    *@*.*) ;;
    *)
      echo "AUTH_MODE=entra needs the administrator's Microsoft address, like admin@clinic.com." >&2
      admin_retry_hint
      exit 1
      ;;
  esac
fi

# -T: neither subcommand prompts, so no tty is needed and a scripted install does not stall.
# --no-activation in entra mode: sign-in is Microsoft and auth.py refuses passwords for every
# id but break-glass, so the token `create` would otherwise mint is a live credential nobody
# can ever use. Not minting it replaces the old capture-and-filter of the command's stdout.
NO_ACTIVATION=
[ "$AUTH_MODE" = "entra" ] && NO_ACTIVATION=--no-activation
ADMIN_STATUS=0
# $NO_ACTIVATION stays unquoted: it is empty or the one fixed flag, never user input.
compose exec -T portal python -m dev_tools.portal_user_admin \
  --db "$ADMIN_DB" create "$ADMIN_ID" "$ADMIN_NAME" --role admin $NO_ACTIVATION \
  || ADMIN_STATUS=$?
if [ "$ADMIN_STATUS" -ne 0 ]; then
  echo "creating the administrator failed (exit $ADMIN_STATUS)." >&2
  admin_retry_hint
  exit "$ADMIN_STATUS"
fi

if [ "$AUTH_MODE" = "entra" ]; then
  UPN_STATUS=0
  compose exec -T portal python -m dev_tools.portal_user_admin \
    --db "$ADMIN_DB" set-upn "$ADMIN_ID" "$ADMIN_UPN" \
    || UPN_STATUS=$?
  if [ "$UPN_STATUS" -ne 0 ]; then
    echo "the administrator account was created but could not be bound to $ADMIN_UPN (exit $UPN_STATUS)." >&2
    echo "  Retry just the binding:" >&2
    echo "  $COMPOSE_CMD exec -T portal python -m dev_tools.portal_user_admin \\" >&2
    echo "    --db $ADMIN_DB set-upn $ADMIN_ID $ADMIN_UPN" >&2
    exit "$UPN_STATUS"
  fi
  echo ""
  echo "$ADMIN_ID is bound to $ADMIN_UPN -- have them open the portal and Sign in with Microsoft."
else
  echo ""
  echo "The activation token printed above is single-use and expires in 48 hours. Give it to"
  echo "$ADMIN_ID out of band; they enter it with a new password at the portal's sign-in screen."
fi

if [ "$PROFILES" = "tls" ]; then
  echo "Portal ${VERSION} is running at https://$HOSTNAME_SET."
else
  echo "Portal ${VERSION} is running on 127.0.0.1:8000."
  echo "You chose no HTTPS proxy: put your own TLS in front before users sign in (README.md, 'TLS')."
fi
echo "Do not try it over plain http first -- README.md, 'TLS', explains why the first click"
echo "after a successful sign-in looks signed out."
