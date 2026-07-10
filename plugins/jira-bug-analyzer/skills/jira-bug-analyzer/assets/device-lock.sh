#!/usr/bin/env bash
# device-lock.sh — serialize adb device access across jira-bug-analyzer sessions/projects.
#
# Why a script (not prose): every shell call from the agent is a SEPARATE process, so a
# pid-keyed lock dies between calls and looks "stale" instantly. This locks on a stable
# OWNER TOKEN (pass the Claude session id) + a TTL, so the claim survives across the many
# adb commands of one verify, and a crashed session self-heals after the TTL.
#
# Usage:
#   device-lock.sh acquire <serial> <owner-token> [ttl_sec]   # claim (or refresh if you already hold it)
#   device-lock.sh install <serial> <owner-token> <apk> [ttl] # acquire-then-install -r -d (keeps the lock held)
#   device-lock.sh release <serial> <owner-token>             # release (only if you own it, or FORCE=1)
#   device-lock.sh status  <serial>                           # FREE | LOCKED | STALE + owner
#   device-lock.sh list                                       # every current lock
#   device-lock.sh free-serial <owner-token> [ttl]           # print first UNLOCKED adb serial (and claim it)
#
# Exit: 0 ok · 3 busy/not-owner · 2 usage.   (macOS bash 3.2 compatible — no same-line local back-refs)
set -uo pipefail

LOCKROOT="${HOME}/.claude/jira-bug-analyzer/device-locks"
mkdir -p "$LOCKROOT"
now() { date +%s; }
field() { sed -n "s/^$2=//p" "$1/owner" 2>/dev/null | head -1; }

is_stale() {            # 0 = stale (age >= ttl or malformed)
  local lock="$1"
  local at; at=$(field "$lock" at)
  local ttl; ttl=$(field "$lock" ttl)
  [ -z "$at" ] && return 0
  [ -z "$ttl" ] && ttl=1800
  [ $(( $(now) - at )) -ge "$ttl" ]
}

write_owner() {         # write_owner <lock> <token> <ttl>
  printf 'owner=%s\nproject=%s\nat=%s\nttl=%s\n' \
    "$2" "$(basename "$PWD")" "$(now)" "$3" > "$1/owner"
}

acquire() {             # acquire <serial> <token> [ttl]
  local serial="$1"
  local token="${2:-unknown}"
  local ttl="${3:-1800}"
  local lock="$LOCKROOT/$serial.lock"
  if mkdir "$lock" 2>/dev/null; then
    write_owner "$lock" "$token" "$ttl"; echo "ACQUIRED $serial"; return 0
  fi
  local cur; cur=$(field "$lock" owner)
  if [ "$cur" = "$token" ]; then            # we already hold it → refresh TTL
    write_owner "$lock" "$token" "$ttl"; echo "ACQUIRED $serial (refresh)"; return 0
  fi
  if is_stale "$lock"; then                  # holder timed out / crashed → reclaim
    rm -rf "$lock"
    if mkdir "$lock" 2>/dev/null; then
      write_owner "$lock" "$token" "$ttl"; echo "ACQUIRED $serial (stale-reclaim)"; return 0
    fi
  fi
  echo "BUSY $serial held-by=$cur since=$(field "$lock" at) project=$(field "$lock" project)"; return 3
}

release() {             # release <serial> <token>
  local serial="$1"
  local token="${2:-}"
  local lock="$LOCKROOT/$serial.lock"
  [ -d "$lock" ] || { echo "FREE $serial"; return 0; }
  local cur; cur=$(field "$lock" owner)
  if [ "${FORCE:-0}" = "1" ] || [ "$cur" = "$token" ] || is_stale "$lock"; then
    rm -rf "$lock"; echo "RELEASED $serial"; return 0
  fi
  echo "NOTOWNER $serial held-by=$cur (use FORCE=1 to override)"; return 3
}

status() {              # status <serial>
  local serial="$1"
  local lock="$LOCKROOT/$serial.lock"
  if [ -d "$lock" ]; then
    if is_stale "$lock"; then
      echo "STALE $serial held-by=$(field "$lock" owner) project=$(field "$lock" project)"
    else
      echo "LOCKED $serial held-by=$(field "$lock" owner) project=$(field "$lock" project) since=$(field "$lock" at)"
    fi
  else
    echo "FREE $serial"
  fi
}

install() {             # install <serial> <token> <apk> [ttl] — acquire then install, keep lock held
  local serial="$1"
  local token="${2:-unknown}"
  local apk="$3"
  local ttl="${4:-1800}"
  acquire "$serial" "$token" "$ttl" || return 3
  adb -s "$serial" install -r -d "$apk"
}

free_serial() {         # free-serial <token> [ttl] — claim + print the first unlocked connected serial
  local token="${1:-unknown}"
  local ttl="${2:-1800}"
  local s
  for s in $(adb devices | awk 'NR>1 && $2=="device"{print $1}'); do
    if acquire "$s" "$token" "$ttl" >/dev/null 2>&1; then echo "$s"; return 0; fi
  done
  echo ""; return 3
}

cmd="${1:-}"
case "$cmd" in
  acquire)     acquire "${2:?serial}" "${3:?token}" "${4:-1800}";;
  release)     release "${2:?serial}" "${3:-}";;
  status)      status  "${2:?serial}";;
  install)     install "${2:?serial}" "${3:?token}" "${4:?apk}" "${5:-1800}";;
  free-serial) free_serial "${2:?token}" "${3:-1800}";;
  list)        shopt -s nullglob; for d in "$LOCKROOT"/*.lock; do status "$(basename "${d%.lock}")"; done;;
  *) echo "usage: device-lock.sh {acquire|release|status|install|free-serial|list} <serial> <owner-token> [apk|ttl]"; exit 2;;
esac
