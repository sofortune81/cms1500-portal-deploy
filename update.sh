#!/bin/sh
# Update the portal to the version in portal.env. Backup first, pull, restart, verify.
# Usage: sh update.sh            (reads PORTAL_VERSION from portal.env)
#        sh update.sh 1.2.3      (also rewrites PORTAL_VERSION in portal.env)
set -eu
cd "$(dirname "$0")"

if [ "${1:-}" != "" ]; then
  # Only a strict version charset reaches sed: & expands to the whole match and / ends the
  # replacement, so either inside the argument would corrupt portal.env.
  case "$1" in
    *[!0-9A-Za-z._-]*) echo "bad version: $1" >&2; exit 2 ;;
  esac
  sed -i.bak "s/^PORTAL_VERSION=.*/PORTAL_VERSION=$1/" portal.env && rm -f portal.env.bak
fi
. ./portal.env

mkdir -p data/backups
echo "== backup"
docker compose exec -T portal python -m dev_tools.db_backup \
  --db /data/runtime/review_portal/review_portal.db --out /data/backups --keep 14

echo "== pull ${PORTAL_IMAGE}:${PORTAL_VERSION}"
docker compose pull
echo "== restart"
docker compose up -d

echo "== health"
i=0
until curl -fsS http://127.0.0.1:8000/health >/dev/null 2>&1; do
  i=$((i+1)); [ "$i" -ge 30 ] && { echo "portal did not come up; see: docker compose logs portal"; exit 1; }
  sleep 2
done
echo "portal ${PORTAL_VERSION} is up"
