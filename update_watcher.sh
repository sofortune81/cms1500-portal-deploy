#!/bin/sh
# Docker-host update watcher: applies an update the portal requested. [FEATURE: IN-APP UPDATE]
# SEARCH TAGS: update watcher, request.txt, status.txt, watcher.heartbeat, in-app update, cron
#
# Run once a minute by cron (install_watcher.sh puts the line in). One tick: heartbeat, and if
# the portal wrote data/update/request.txt, run `sh update.sh <version>` once and record the
# outcome in data/update/status.txt. The portal never runs docker itself; this is the only
# path from an admin's click to a new image.
#
# request.txt is written from inside the container, so it is treated as hostile: VERSION is
# read by line prefix (never sourced or evaluated), charset-checked with the same pattern
# update.sh applies, and handed to update.sh as one quoted argument. The image name comes
# from portal.env, so a request can only pick a version of the configured image.
#
# REQUEST_ID (16-64 lowercase hex; absent from an older portal's request) is copied into every
# status.txt this tick writes for the request. The portal treats a request whose id status.txt
# carries as taken and deletes it; a request whose id is already there is never run a second
# time. This watcher never deletes a request with a valid id, only an id-less one.
#
# Every name under data/update may also be a symlink planted from inside the container, aimed
# at a file this account owns. Nothing here writes through, reads through, or removes through
# a name it has not checked; the run log is written only in .update-run/ in the bundle root,
# which the container cannot see, and only a copy of its tail is published into data/update.
#
# Mutates: data/update/{status.txt,watcher.heartbeat,last-update.log,.lock}, deletes an id-less,
# malformed or non-file data/update/request.txt, writes .update-run/, and (through update.sh) portal.env and the
# running containers.
#
# Status exit codes: update.sh's own, or
#   2  bad version or request id in request.txt
#   6  watcher interrupted mid-update (signal, or a stale lock found with STATE=running)
#
# No `set -e`: the update replaces the portal underneath this script, and its exit code has to
# be read and recorded whatever it is.
set -u
cd "$(dirname "$0")" || exit 1
BUNDLE_DIR=$(pwd -P) || exit 1

# cron's PATH is /usr/bin:/bin; Docker can live in /usr/local/bin or /snap/bin. Appended, so
# the operator's own PATH still comes first.
PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
export PATH

UPDATE_DIR="data/update"
#: The run log's home: the bundle root, outside the container's /data mount.
RUN_DIR="$BUNDLE_DIR/.update-run"
#: Lines of the run log published into data/update/last-update.log for the portal.
PUBLISHED_LOG_LINES=200
# Relative to data/update: the watcher works from inside it once its path is verified.
LOCK_DIR=".lock"
REQUEST="request.txt"
STATUS="status.txt"
HEARTBEAT="watcher.heartbeat"
LOG="last-update.log"
LOCK_PID="$LOCK_DIR/pid"
#: A lock is stale when the watcher PID it records is gone. With no readable PID (a tick
#: killed between mkdir and the PID write) it is stale past this age instead.
STALE_LOCK_MINUTES=30
#: PID-reuse backstop: past this age a lock is stale even when its PID is alive, since after a
#: reboot that number can belong to an unrelated process. No update runs for 6 hours.
LOCK_CEILING_MINUTES=360
#: status.txt EXIT_CODE for an update the watcher did not see to the end.
INTERRUPTED_EXIT_CODE=6

now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# True for a regular file that is not a symlink. A FIFO fails too: reading one would block
# this tick, and every later one behind its lock.
is_plain_file() {
  [ -f "$1" ] && [ ! -L "$1" ]
}

# GNU mv -T renames onto the name itself, never into a directory a planted link points at.
if mv --help 2>/dev/null | grep -q -- '--no-target-directory'; then
  MV_NO_TARGET_DIR="-T"
else
  MV_NO_TARGET_DIR=""
fi

# write_atomic DEST < content. The temp file is opened exactly once, by the write itself, under
# noclobber (`set -C`), which in dash and bash creates with O_EXCL and refuses an existing
# regular file -- so a link planted at the temp name, dangling or not, makes the write fail
# instead of being followed. mktemp -u only picks the name: a mktemp-created file would have to
# be reopened by name, and the container could swap a link in between. umask sets the mode at
# creation, so nothing is chmod'ed by name afterwards. A planted DEST link is removed first (for
# an mv without -T), so the rename replaces the name. The portal reads these files at any
# moment and must never see one half-written. A failed write removes nothing.
write_atomic() {
  tmp=$(mktemp -u "$1.tmp.XXXXXX") || return 1
  ( umask 022; set -C; cat > "$tmp" ) || return 1
  [ -L "$1" ] && rm -f "$1"
  # shellcheck disable=SC2086 # empty when mv has no -T
  mv -f $MV_NO_TARGET_DIR "$tmp" "$1"
}

write_heartbeat() {
  now | write_atomic "$HEARTBEAT"
}

# write_status STATE VERSION EXIT_CODE STARTED_AT FINISHED_AT REQUEST_ID
write_status() {
  printf 'STATE=%s\nVERSION=%s\nEXIT_CODE=%s\nSTARTED_AT=%s\nFINISHED_AT=%s\nREQUEST_ID=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" | write_atomic "$STATUS"
}

# True for an id the portal writes: 16-64 lowercase hex. The digits are listed rather than a
# range, which some locales collate with upper case; a newline (two REQUEST_ID= lines) fails too.
valid_request_id() {
  case "$1" in
    *[!0123456789abcdef]*) return 1 ;;
  esac
  [ "${#1}" -ge 16 ] && [ "${#1}" -le 64 ]
}

# The first value of KEY in status.txt. Read as text, like request.txt.
status_value() {
  is_plain_file "$STATUS" || return 0
  sed -n "s/^$1=//p" "$STATUS" 2>/dev/null | head -n 1
}

# Publish the tail of run log $1 for the portal, then keep the whole of it as last-run.log.
# The published copy is replaced, never appended to, so nothing is ever opened for writing
# at a name the container controls. Nothing reads the published copy back.
finish_run_log() {
  [ -n "$1" ] && is_plain_file "$1" || return 0
  tail -n "$PUBLISHED_LOG_LINES" "$1" | write_atomic "$LOG"
  mv -f "$1" "$RUN_DIR/last-run.log"
}

# A watcher killed mid-update left STATE=running behind; without this the portal would show
# the update as running forever. VERSION and STARTED_AT are carried over only when they still
# look like what this script writes. That watcher's run log is published too.
mark_interrupted() {
  [ "$(status_value STATE)" = "running" ] || return 0
  old_version=$(status_value VERSION)
  case "$old_version" in
    ''|-*|*[!0-9A-Za-z._-]*) old_version="" ;;
  esac
  old_started=$(status_value STARTED_AT)
  case "$old_started" in
    *[!0-9TZ:-]*) old_started="" ;;
  esac
  old_request_id=$(status_value REQUEST_ID)
  valid_request_id "$old_request_id" || old_request_id=""
  write_status failed "$old_version" "$INTERRUPTED_EXIT_CODE" "$old_started" "$(now)" "$old_request_id"
  # mktemp names only, so the listing is safe to read line by line.
  orphan_log=$(ls -t "$RUN_DIR" 2>/dev/null | grep '^run\.' | head -n 1)
  if [ -n "$orphan_log" ]; then
    finish_run_log "$RUN_DIR/$orphan_log"
  fi
}

# The run folder lives in the bundle root, which only the operator writes, but gets the same
# link check as everything else.
if [ -L "$RUN_DIR" ] || { [ -e "$RUN_DIR" ] && [ ! -d "$RUN_DIR" ]; }; then
  rm -f "$RUN_DIR"
fi
mkdir -p -m 700 "$RUN_DIR" && chmod 700 "$RUN_DIR" || exit 1

# data/ is the container's /data, so the update folder itself can be swapped for a link.
if [ -L "$UPDATE_DIR" ]; then
  rm -f "$UPDATE_DIR"
fi
mkdir -p "$UPDATE_DIR" || exit 1
# Into data/update once, by a verified physical path; every name below is relative to it, so
# no later swap of the folder redirects a write. data/ itself is the operator's (a symlinked
# data/ is allowed); only the last step is checked.
EXPECTED_UPDATE_DIR="$(cd data && pwd -P)/update" || exit 1
cd "$UPDATE_DIR" || exit 1
if [ "$(pwd -P)" != "$EXPECTED_UPDATE_DIR" ]; then
  echo "data/update resolves to $(pwd -P), not $EXPECTED_UPDATE_DIR; refusing." >&2
  exit 1
fi

# True when the lock dir is older than $1 minutes.
lock_older_than() {
  [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +"$1" 2>/dev/null)" ]
}

# True when the lock's recorded PID is a running update_watcher.sh. Where /proc exists it says
# what the process is, so a PID reused by an unrelated process does not hold the lock;
# elsewhere a live PID is the best evidence there is.
lock_holder_alive() {
  if [ -d /proc/self ]; then
    [ -r "/proc/$lock_pid/cmdline" ] || return 1
    tr '\0' ' ' < "/proc/$lock_pid/cmdline" | grep -F update_watcher.sh >/dev/null
    return
  fi
  kill -0 "$lock_pid" 2>/dev/null
}

# True when something sits at the lock's name that no live watcher holds. An update may
# legitimately outlast STALE_LOCK_MINUTES (a slow pull), so a live holder keeps its lock until
# the ceiling. A link or a non-directory there is never a lock this script took.
lock_is_stale() {
  if [ -L "$LOCK_DIR" ]; then
    return 0
  fi
  [ -e "$LOCK_DIR" ] || return 1
  [ -d "$LOCK_DIR" ] || return 0
  lock_older_than "$LOCK_CEILING_MINUTES" && return 0
  lock_pid=""
  if is_plain_file "$LOCK_PID"; then
    lock_pid=$(sed -n '1p' "$LOCK_PID" 2>/dev/null) || lock_pid=""
  fi
  case "$lock_pid" in
    ''|*[!0-9]*)
      lock_older_than "$STALE_LOCK_MINUTES"
      return
      ;;
  esac
  if lock_holder_alive; then
    return 1
  fi
  return 0
}

if lock_is_stale; then
  if [ -L "$LOCK_DIR" ] || [ ! -d "$LOCK_DIR" ]; then
    rm -f "$LOCK_DIR"
  else
    mark_interrupted
    rm -rf "$LOCK_DIR"
  fi
fi
# mkdir is atomic: exactly one tick gets the lock; any other one exits quietly.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0
fi
# Set once this tick has written STATE=running and cleared once it has written the outcome;
# a signal in between records the update as interrupted instead of leaving it running.
RUNNING=0
RUN_LOG=""
REQUEST_ID=""
on_signal() {
  if [ "$RUNNING" -eq 1 ]; then
    write_status failed "$VERSION" "$INTERRUPTED_EXIT_CODE" "$STARTED_AT" "$(now)" "$REQUEST_ID"
    exec 3>&-
    finish_run_log "$RUN_LOG"
  fi
  exit 1
}
trap 'rm -f "$LOCK_PID" "$LOCK_PID".tmp.*; rmdir "$LOCK_DIR" 2>/dev/null' EXIT
# dash skips the EXIT trap on a signal unless the signal handler exits explicitly.
trap on_signal HUP INT TERM
# Atomic, so a tick judging the lock never reads half a PID.
printf '%s\n' "$$" | write_atomic "$LOCK_PID"

write_heartbeat

if [ ! -e "$REQUEST" ] && [ ! -L "$REQUEST" ]; then
  exit 0
fi
# A link could aim the read at any file this account can see; anything but a plain file is
# discarded as hostile, never followed.
if ! is_plain_file "$REQUEST"; then
  STARTED_AT=$(now)
  write_status failed "" 2 "$STARTED_AT" "$(now)" ""
  rm -rf "$REQUEST"
  exit 0
fi

# One read: the portal may delete a consumed request and write the next one at any moment, so
# two reads could pair one request's VERSION with another's REQUEST_ID (or see no id at all and
# re-run a consumed request as if it were legacy). Gone since the check above: nothing to do.
REQ=$(cat -- "$REQUEST" 2>/dev/null) || exit 0
VERSION=$(printf '%s\n' "$REQ" | sed -n 's/^VERSION=//p')
REQUEST_ID=$(printf '%s\n' "$REQ" | sed -n 's/^REQUEST_ID=//p')
# No id is an older portal's request and runs as before. A malformed one is refused like a bad
# version, and not echoed into status.txt for the same reason. Removing it here is safe: the
# portal reads a request it cannot see consumed as pending, so it never writes over one.
if [ -n "$REQUEST_ID" ] && ! valid_request_id "$REQUEST_ID"; then
  STARTED_AT=$(now)
  write_status failed "" 2 "$STARTED_AT" "$(now)" ""
  rm -f "$REQUEST"
  exit 0
fi
# Already taken: status.txt carrying this id means it ran, or is running. Never twice, and left
# for the portal to remove (see release_request).
if [ -n "$REQUEST_ID" ] && [ "$(status_value REQUEST_ID)" = "$REQUEST_ID" ]; then
  exit 0
fi

# A request with a valid REQUEST_ID is the portal's to delete, once status.txt carries the id.
# A by-name rm here could remove a NEWER request: between this tick's read and its rm, the portal
# may discard the consumed one and accept the next. Only an older portal's id-less request, which
# nothing else would ever remove, is deleted here.
release_request() {
  [ -n "$REQUEST_ID" ] || rm -f "$REQUEST"
}

# Empty would make update.sh re-apply the current version, and a leading - would read as an
# option. Two VERSION= lines join with a newline, which the charset refuses. The rejected
# value is not echoed into status.txt: it could carry a newline and forge a STATE= line.
case "$VERSION" in
  ''|-*|*[!0-9A-Za-z._-]*)
    STARTED_AT=$(now)
    write_status failed "" 2 "$STARTED_AT" "$(now)" "$REQUEST_ID"
    release_request
    exit 0
    ;;
esac

STARTED_AT=$(now)
write_status running "$VERSION" "" "$STARTED_AT" "" "$REQUEST_ID"
RUNNING=1
# A fresh file in the run folder, opened once as fd 3 for the whole run.
RUN_LOG=$(mktemp "$RUN_DIR/run.XXXXXX") || RUN_LOG=""
if [ -n "$RUN_LOG" ]; then
  # `command`: a failed redirection on a bare `exec` ends the shell, leaving STATE=running.
  command exec 3>>"$RUN_LOG" || exec 3>/dev/null
else
  exec 3>/dev/null
fi
echo "== $STARTED_AT update to $VERSION requested" >&3
# Consumed before the run, not after: should this tick lose its lock mid-run (the 6-hour
# ceiling, or the PID-less age fallback), the tick that takes over must not start a second
# update.sh alongside this one. With an id, status.txt already says `running` with it, so that
# tick's id check skips the request; an id-less one is removed here.
release_request
( cd "$BUNDLE_DIR" && exec sh ./update.sh "$VERSION" ) >&3 2>&1
EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 0 ]; then
  STATE=ok
else
  STATE=failed
fi
write_status "$STATE" "$VERSION" "$EXIT_CODE" "$STARTED_AT" "$(now)" "$REQUEST_ID"
RUNNING=0
echo "== $(now) update to $VERSION finished: $STATE (exit $EXIT_CODE)" >&3
exec 3>&-
finish_run_log "$RUN_LOG"
