#!/usr/bin/env bash
# Stop and Notification hook, installed in every session by the plugin.
#   Stop          the session finished a turn: forward its final reply
#   Notification  the session is stuck on a permission prompt or a dialog: say so
# It writes only while an operator is running, only for interactive sessions (never for
# `claude -p` runs or the operator itself), and it always exits 0 without output, so it
# can't block or change a session.
set -u
. "$(dirname "$0")/lib.sh"

in=$(cat)
[ "${CLAUDE_CODE_ENTRYPOINT:-}" = cli ] || exit 0
[ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = 1 ] || exit 0
operator_live || exit 0

sid=$(printf '%s' "$in" | jq -r '.session_id // ""' 2>/dev/null)
[ -n "$sid" ] || exit 0
[ "$sid" = "$(op session_id)" ] && exit 0

case "$(printf '%s' "$in" | jq -r '.hook_event_name // ""')" in
  Stop)
    type=reply
    text=$(printf '%s' "$in" | jq -r '.last_assistant_message // ""') ;;
  Notification)
    type=waiting
    text=$(printf '%s' "$in" | jq -r '.message // .title // "needs your attention"') ;;
  *) exit 0 ;;
esac
[ -n "$text" ] || exit 0

name=$(session_name "$sid")
pane="${TMUX_PANE:-}"
window=""
[ -n "$pane" ] && window=$(tmux display -p -t "$pane" '#{session_name}:#{window_index}' 2>/dev/null)

record() {  # record <max>
  printf '%s' "$in" | jq -c -f "$lib_dir/entry.jq" \
    --arg type "$type" --arg text "$text" --arg name "$name" --arg pane "$pane" \
    --arg window "$window" --arg now "$(date +%s)" --arg max "$1"
}

mkdir -p "$home/last"
full=$(record 0) && printf '%s\n' "$full" > "$home/last/$sid.json"
line=$(record "${SWITCHBOARD_PREVIEW:-1200}") || exit 0
lock
printf '%s\n' "$line" >> "$inbox"
unlock
exit 0
