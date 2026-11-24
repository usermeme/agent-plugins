#!/usr/bin/env bash
# switchboard control script. The operator session calls it; you can too, from a terminal.
#
#   ctl.sh register [--force]       make the calling Claude session the operator
#   ctl.sh unregister               stop operating (sessions stop forwarding)
#   ctl.sh status                   who operates, and how much is waiting in the inbox
#   ctl.sh list                     running sessions: name, state, tmux window, folder
#   ctl.sh show <name>              the full last reply (or dialog) of a session
#   ctl.sh screen <name> [lines]    what the session's tmux pane shows now
#   ctl.sh press <name> <key>...    press keys in the session's pane (a small fixed set)
#   ctl.sh new <name> <dir> [prompt]
#                                   open a Claude session in a new window of the tmux
#                                   session $SWITCHBOARD_TMUX_SESSION (default: main)
set -u
. "$(dirname "$0")/lib.sh"

cmd="${1:-}"
[ $# -gt 0 ] && shift

short_dir() { case "$1" in "$HOME"*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

# pane_of <name>: sets p_pane and p_window for a running session, or dies
pane_of() {
  resolve "$1"
  local hit
  hit=$(pane_of_pid "$r_pid") || die "$r_name is not running in a tmux pane"
  p_pane="${hit%% *}"
  p_window="${hit#* }"
}

case "$cmd" in
register)
  sid="${CLAUDE_CODE_SESSION_ID:-}"
  pid="${CLAUDE_PID:-}"
  [ -n "$sid" ] && [ -n "$pid" ] || die "run this from inside a Claude Code session"
  if operator_live && [ "$(op session_id)" != "$sid" ] && [ "${1:-}" != --force ]; then
    die "$(op name) is already the operator. Run 'ctl.sh register --force' to take over."
  fi
  mkdir -p "$home"
  name=$(session_name "$sid")
  jq -n --arg sid "$sid" --arg pid "$pid" --arg name "$name" --arg now "$(date +%s)" \
    '{session_id: $sid, pid: ($pid | tonumber), name: $name, since: ($now | tonumber)}' > "$op_file.tmp"
  mv "$op_file.tmp" "$op_file"
  lock; : > "$inbox"; echo 0 > "$home/offset"; unlock
  jq -c '{name, session_id}' "$op_file"
  ;;

unregister)
  if [ -f "$op_file" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] &&
     [ "$(op session_id)" != "$CLAUDE_CODE_SESSION_ID" ] && operator_live && [ "${1:-}" != --force ]; then
    die "$(op name) is the operator, not this session. Use --force to unregister it anyway."
  fi
  rm -f "$op_file"
  echo "switchboard: no operator; sessions stopped forwarding"
  ;;

status)
  if operator_live; then
    printf 'operator: %s (pid %s)\n' "$(op name)" "$(op pid)"
  elif [ -f "$op_file" ]; then
    printf 'operator: %s, but its process is gone; nothing is forwarded\n' "$(op name)"
  else
    echo "operator: none; nothing is forwarded"
  fi
  size=$(wc -c < "$inbox" 2>/dev/null | tr -d ' ')
  off=$(cat "$home/offset" 2>/dev/null || echo 0)
  printf 'inbox: %s records, %s bytes not yet delivered\n' \
    "$(wc -l < "$inbox" 2>/dev/null | tr -d ' ' || echo 0)" "$(( ${size:-0} - off ))"
  ;;

list)
  me=$(op session_id)
  agents | jq -r '.[] | [.name // "-", .status // "-", .kind // "-", (.pid | tostring), .sessionId, .cwd // ""] | @tsv' |
  while IFS="$(printf '\t')" read -r n st kind pid sid cwd; do
    hit=$(pane_of_pid "$pid") || hit="- -"
    tag=""; [ "$sid" = "$me" ] && tag=" (operator)"
    printf '%s%s\t%s\t%s\t%s\t%s\n' "$n" "$tag" "$st" "$kind" "${hit#* }" "$(short_dir "$cwd")"
  done
  ;;

show)
  [ $# -ge 1 ] || die "usage: ctl.sh show <name>"
  file=""
  if err=$( (resolve "$1") 2>&1 >/dev/null ); then
    resolve "$1"
    file="$home/last/$r_sid.json"
  else
    case "$err" in *" matches "*) die "${err#switchboard: }" ;; esac
  fi
  if [ ! -f "$file" ]; then  # a session that has exited: look it up by the name it had
    file=$(grep -l -F "\"name\":\"$1\"" "$home"/last/*.json 2>/dev/null | head -n 1)
  fi
  [ -n "$file" ] && [ -f "$file" ] || die "nothing recorded for '$1' since the operator started"
  jq -r '"\(.name) · \(.type) · \(.cwd)\n\n\(.text)"' "$file"
  ;;

screen)
  [ $# -ge 1 ] || die "usage: ctl.sh screen <name> [lines]"
  lines="${2:-40}"
  case "$lines" in ''|*[!0-9]*) die "lines must be a number" ;; esac
  pane_of "$1"
  printf '%s · %s\n\n' "$r_name" "$p_window"
  tmux capture-pane -p -J -t "$p_pane" | awk '{ a[NR] = $0 } NF { last = NR } END { for (i = 1; i <= last; i++) print a[i] }' | tail -n "$lines"
  ;;

press)
  [ $# -ge 2 ] || die "usage: ctl.sh press <name> <key>...   keys: Enter Escape Tab BTab Space Up Down Left Right 0-9 y n"
  target="$1"; shift
  [ $# -le 5 ] || die "at most 5 keys at a time"
  for k in "$@"; do
    case "$k" in
      Enter|Escape|Tab|BTab|Space|Up|Down|Left|Right|[0-9]|y|n) ;;
      *) die "key '$k' is not allowed. Allowed: Enter Escape Tab BTab Space Up Down Left Right 0-9 y n" ;;
    esac
  done
  pane_of "$target"
  [ "$r_sid" = "$(op session_id)" ] && die "won't press keys in the operator's own pane"
  tmux send-keys -t "$p_pane" "$@"
  printf 'pressed %s in %s (%s)\n' "$*" "$r_name" "$p_window"
  ;;

new)
  [ $# -ge 2 ] || die "usage: ctl.sh new <name> <dir> [prompt]"
  name="$1"; dir="$2"; prompt="${3:-}"
  printf '%s' "$name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$' ||
    die "name must be 1-40 letters, digits, '.', '_' or '-', starting with a letter or digit"
  case "$dir" in "~") dir="$HOME" ;; "~/"*) dir="$HOME/${dir#"~/"}" ;; esac
  [ -d "$dir" ] || die "no such folder: $dir"
  dir=$(cd "$dir" && pwd -P)
  if agents | jq -e --arg n "$name" 'any(.[]; .name == $n)' >/dev/null; then
    die "a session called '$name' is already running"
  fi
  bin=$(command -v claude) || die "claude is not on PATH"
  tsess="${SWITCHBOARD_TMUX_SESSION:-main}"
  if [ -n "$prompt" ]; then set -- "$bin" -n "$name" "$prompt"; else set -- "$bin" -n "$name"; fi
  if tmux has-session -t "=$tsess" 2>/dev/null; then
    pane=$(tmux new-window -d -t "=$tsess:" -n "$name" -c "$dir" -P -F '#{pane_id}' "$@") || die "tmux could not open a window"
  else
    pane=$(tmux new-session -d -s "$tsess" -n "$name" -c "$dir" -P -F '#{pane_id}' "$@") || die "tmux could not start session $tsess"
  fi
  window=$(tmux display -p -t "$pane" '#{session_name}:#{window_index}' 2>/dev/null)

  # Wait until the session is up, stuck on the folder-trust prompt, or gone.
  status=STARTING
  i=0; wait_s="${SWITCHBOARD_START_WAIT:-20}"
  while [ "$i" -lt "$wait_s" ]; do
    if ! tmux display -p -t "$pane" '#{pane_id}' >/dev/null 2>&1; then status=EXITED; break; fi
    if tmux capture-pane -p -t "$pane" 2>/dev/null | grep -Eqi 'trust this folder|one you trust'; then status=TRUST; break; fi
    if agents | jq -e --arg n "$name" 'any(.[]; .name == $n)' >/dev/null; then status=READY; break; fi
    sleep "${SWITCHBOARD_TICK:-1}"
    i=$((i + 1))
  done
  case "$status" in
    READY)    msg="$name is running in $window." ;;
    TRUST)    msg="$name is waiting for you to trust $(short_dir "$dir"). Pressing Enter in its pane trusts it, and that only happens if you ask for it." ;;
    EXITED)   msg="$name exited right after it started." ;;
    STARTING) msg="$name has not shown up yet; check it with 'screen $name' or 'list'." ;;
  esac
  jq -nc --arg s "$status" --arg n "$name" --arg p "$pane" --arg w "$window" --arg d "$dir" --arg m "$msg" \
    '{status: $s, name: $n, pane: $p, window: $w, dir: $d, message: $m}'
  ;;

*)
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  [ -z "$cmd" ] || exit 1
  ;;
esac
