#!/usr/bin/env bash
#
# Refuse to start a second copy of Vanika, and say precisely what is in the way.
#
# Three ways a duplicate happens, and what this does about each:
#
#   1. Two installers at once. A lock file makes the second wait or exit rather
#      than racing the first through a build.
#   2. A second checkout. Compose now pins `name: vanikaai`, so any invocation
#      addresses the same project -- but this still reports when the running
#      stack came from a different directory, because that is usually a mistake.
#   3. Something else already holds a port. Naming the process beats "address
#      already in use" from a container that then restarts forever.
#
# Sourced by install.sh; also runnable on its own:  ./scripts/preflight.sh
set -euo pipefail

PROJECT="vanikaai"
LOCK_FILE="${TMPDIR:-/tmp}/vanika-install.lock"
PORTS="8080 3001 3002 3003 3004 5432 7447"

_say()  { printf '  %s\n' "$*"; }
_warn() { printf '  !   %s\n' "$*"; }
_die()  { printf '\nx  %s\n' "$*"; exit 1; }

# ---------------------------------------------------------------- lock ----
# Held for the life of the calling shell; released when it exits, including on
# Ctrl-C, so a cancelled install never leaves a stale lock behind.
preflight_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
      _die "Another Vanika install is already running (lock: $LOCK_FILE).
   Wait for it to finish, or remove the lock if you are certain it is stale."
    fi
  else
    # No flock (macOS ships without it): fall back to a pid file.
    if [ -f "$LOCK_FILE" ]; then
      local pid; pid="$(cat "$LOCK_FILE" 2>/dev/null || echo '')"
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        _die "Another Vanika install is already running (pid $pid)."
      fi
      _warn "Clearing a stale lock from pid ${pid:-unknown}."
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT INT TERM
  fi
}

# ------------------------------------------------------------ running ----
# Is our stack already up, and did it come from here?
preflight_existing() {
  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0

  local running
  running="$(docker ps --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')"
  [ "${running:-0}" -eq 0 ] && return 0

  local where
  where="$(docker ps --filter "label=com.docker.compose.project=${PROJECT}" \
            --format '{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null | head -1)"
  _say "${running} service(s) of project '${PROJECT}' are already running."
  # Compare paths case-insensitively with separators normalised: on Windows the
  # same directory is "C:\path" to Docker and "/c/path" to this shell, and
  # reporting that as a different location would be crying wolf.
  local a b
  a="$(printf '%s' "$where" | tr 'A-Z' 'a-z' | tr '\\' '/' | sed 's#^\([a-z]\):#/\1#')"
  b="$(printf '%s' "$PWD"   | tr 'A-Z' 'a-z' | tr '\\' '/' | sed 's#^\([a-z]\):#/\1#')"
  if [ -n "$where" ] && [ "$a" != "$b" ]; then
    _warn "They were started from: $where"
    _warn "You are in:             $PWD"
    _say  "Compose pins the project name, so continuing REPLACES those containers"
    _say  "rather than starting a second set. That is usually what you want after"
    _say  "moving or re-cloning the repository."
  fi
  return 0
}

# -------------------------------------------------------------- ports ----
# Who holds a port we need, if it is not us?
port_holder() {
  local port="$1"
  # A container of ours is not a conflict.
  local mine
  mine="$(docker ps --filter "label=com.docker.compose.project=${PROJECT}" \
          --format '{{.Ports}}' 2>/dev/null | grep -c ":${port}->" || true)"
  [ "${mine:-0}" -gt 0 ] && return 0

  local other
  other="$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | grep ":${port}->" | cut -f1 | head -1 || true)"
  if [ -n "$other" ]; then printf 'container %s' "$other"; return 1; fi

  if command -v lsof >/dev/null 2>&1; then
    local proc
    proc="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1" (pid "$2")"}')"
    [ -n "$proc" ] && { printf '%s' "$proc"; return 1; }
  elif command -v ss >/dev/null 2>&1; then
    ss -lntp 2>/dev/null | grep -q ":${port} " && { printf 'another process'; return 1; }
  fi
  return 0
}

preflight_ports() {
  local blocked=0 holder
  for port in $PORTS; do
    if ! holder="$(port_holder "$port")"; then
      _warn "Port ${port} is held by ${holder}"
      blocked=1
    fi
  done
  if [ "$blocked" -eq 1 ]; then
    _die "Free those ports, or stop the other stack, then run this again.
   If it is an older Vanika under a different project name:
     docker ps --filter name=vanika --format '{{.Names}}' | xargs -r docker rm -f"
  fi
}

preflight_all() {
  preflight_lock
  preflight_existing
  preflight_ports
}

# Run everything when executed directly rather than sourced.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  printf '\n> Preflight\n'
  preflight_all
  printf '  ok  nothing is in the way\n'
fi
