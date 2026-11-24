#!/usr/bin/env bash
# The operator runs this in the background. It waits until the inbox has new records,
# prints them (one JSON object per line, at most SWITCHBOARD_BATCH per run) and exits,
# which wakes the operator. The operator then starts it again.
#
# It also exits, printing {"type":"replaced",...}, when another session has taken over as
# operator, so two operators never share one inbox.
set -u
. "$(dirname "$0")/lib.sh"

tick="${SWITCHBOARD_TICK:-1}"
settle="${SWITCHBOARD_SETTLE:-1}"
batch="${SWITCHBOARD_BATCH:-20}"
me="${CLAUDE_CODE_SESSION_ID:-}"
off_file="$home/offset"
mkdir -p "$home"
touch "$inbox"

size_now() { lock; wc -c < "$inbox" | tr -d ' '; unlock; }

while :; do
  owner=$(op session_id)
  if [ -n "$me" ] && [ -n "$owner" ] && [ "$owner" != "$me" ]; then
    jq -nc --arg by "$(op name)" '{type: "replaced", by: $by}'
    exit 0
  fi
  if [ -z "$owner" ]; then
    jq -nc '{type: "unregistered"}'
    exit 0
  fi

  size=$(size_now)
  off=$(cat "$off_file" 2>/dev/null || echo 0)
  [ "$size" -lt "$off" ] 2>/dev/null && off=0   # the inbox was reset
  if [ "$size" -gt "$off" ]; then
    sleep "$settle"                              # let a burst of replies land together
    size=$(size_now)
    out=$(tail -c +"$((off + 1))" "$inbox" | head -c "$((size - off))" | head -n "$batch")
    used=$(printf '%s\n' "$out" | wc -c | tr -d ' ')
    echo "$((off + used))" > "$off_file"
    printf '%s\n' "$out"
    exit 0
  fi
  sleep "$tick"
done
