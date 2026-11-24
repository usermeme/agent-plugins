#!/usr/bin/env bash
# Shared by the switchboard scripts. Sourced, never executed. Works with macOS bash 3.2.

home="${SWITCHBOARD_HOME:-$HOME/.claude/switchboard}"
inbox="$home/inbox.jsonl"
op_file="$home/operator.json"
lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() { printf 'switchboard: %s\n' "$*" >&2; exit 1; }
alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# op <field>: a field of the registered operator, or nothing
op() { jq -r --arg f "$1" '.[$f] // ""' "$op_file" 2>/dev/null; }

# operator_live: true when an operator is registered and its Claude process still runs
operator_live() { [ -f "$op_file" ] && alive "$(op pid)"; }

# lock / unlock: serialise inbox writes and reads. A writer that can't get the lock in
# about 2 s goes ahead anyway: a hook must never hang a session.
lock() {
  mkdir -p "$home"
  local i=0
  while ! mkdir "$home/.lock" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -ge 40 ] && return 0
    sleep 0.05
  done
}
unlock() { rmdir "$home/.lock" 2>/dev/null || true; }

# agents: every running Claude session, as `claude agents --json` prints them
agents() { claude agents --json 2>/dev/null || echo '[]'; }

# session_name <session_id>: its display name, or the first 8 characters of the id
session_name() {
  local n
  n=$(agents | jq -r --arg s "$1" 'map(select(.sessionId == $s)) | .[0].name // ""' 2>/dev/null)
  if [ -n "$n" ]; then printf '%s' "$n"; else printf '%s' "$1" | cut -c1-8; fi
}

# resolve <name>: sets r_name, r_sid, r_pid for the session with that name. An exact
# match wins; otherwise one session whose name contains <name> (any case). Dies otherwise.
resolve() {
  local all hits n
  all=$(agents)
  hits=$(printf '%s' "$all" | jq -c --arg n "$1" 'map(select(.name == $n))')
  if [ "$(printf '%s' "$hits" | jq length)" != 1 ]; then
    hits=$(printf '%s' "$all" | jq -c --arg n "$1" 'map(select((.name // "") | ascii_downcase | contains($n | ascii_downcase)))')
  fi
  n=$(printf '%s' "$hits" | jq length)
  [ "$n" = 0 ] && die "no running session is called '$1'"
  [ "$n" = 1 ] || die "'$1' matches $n sessions: $(printf '%s' "$hits" | jq -r 'map(.name) | join(", ")')"
  r_name=$(printf '%s' "$hits" | jq -r '.[0].name')
  r_sid=$(printf '%s' "$hits" | jq -r '.[0].sessionId')
  r_pid=$(printf '%s' "$hits" | jq -r '.[0].pid')
}

# pane_of_pid <pid>: "<pane_id> <session>:<window>" of the tmux pane that runs the
# process, found by walking up its parents. Nothing when it isn't in tmux.
pane_of_pid() {
  local p="$1" i=0 panes hit
  panes=$(tmux list-panes -a -F '#{pane_pid} #{pane_id} #{session_name}:#{window_index}' 2>/dev/null) || return 1
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ "$i" -lt 8 ]; do
    hit=$(printf '%s\n' "$panes" | awk -v p="$p" '$1 == p { print $2 " " $3; exit }')
    if [ -n "$hit" ]; then printf '%s' "$hit"; return 0; fi
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    i=$((i + 1))
  done
  return 1
}
