#!/usr/bin/env bash
# Tests for the switchboard scripts. `claude` and `tmux` are the stubs in tests/stubs, so
# nothing here touches real sessions or windows.
#
#   tests/run.sh          run everything
#   tests/run.sh hook     run one group: hook | watch | ctl
set -u
here=$(cd "$(dirname "$0")" && pwd)
S=$(cd "$here/../scripts" && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/switchboard-tests.XXXXXX")
T=$(cd "$T" && pwd -P)
sleep 600 & live=$!; disown "$live"   # stands in for a running Claude process
sh -c 'exit 0' & dead=$!; wait "$dead" 2>/dev/null
trap 'kill "$live" 2>/dev/null; rm -rf "$T"' EXIT

export STUB="$T/stub" SWITCHBOARD_HOME="$T/home"
export PATH="$here/stubs:$PATH" SWITCHBOARD_TICK=0.1 SWITCHBOARD_SETTLE=0.1 SWITCHBOARD_START_WAIT=3
mkdir -p "$STUB" "$SWITCHBOARD_HOME"
H="$SWITCHBOARD_HOME"

pass=0; fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$3], got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1" "[$3] is not in: $(printf '%s' "$2" | head -c 300)" ;; esac; }
group() { [ -z "${ONLY:-}" ] || [ "$ONLY" = "$1" ]; }
ONLY="${1:-}"

agents() {  # agents '<name> <sid> <pid>' ...
  local a
  for a in "$@"; do
    set -- $a
    jq -nc --arg n "$1" --arg s "$2" --arg p "$3" '{name: $n, sessionId: $s, pid: ($p | tonumber), kind: "interactive", status: "idle", cwd: "/w/\($n)"}'
  done | jq -sc . > "$STUB/agents.json"
}
operator() {  # operator <sid> <pid>: register without going through ctl.sh
  jq -nc --arg s "$1" --arg p "$2" '{session_id: $s, pid: ($p | tonumber), name: "op", since: 0}' > "$H/operator.json"
}
reset() { rm -rf "$H" "$STUB"; mkdir -p "$H" "$STUB"; }

# hook <event> <sid> <text> [notification_type]: runs on-hook.sh as an interactive session
hook() {
  jq -nc --arg e "$1" --arg s "$2" --arg t "$3" --arg k "${4:-}" '
    {session_id: $s, cwd: "/w/x", hook_event_name: $e}
    + (if $e == "Stop" then {last_assistant_message: $t} else {message: $t, notification_type: $k} end)' |
    CLAUDE_CODE_ENTRYPOINT="${EP:-cli}" CLAUDE_CODE_SESSION_ATTENDED="${ATT:-1}" TMUX_PANE="${PANE:-%7}" "$S/on-hook.sh"
  hook_rc=$?
}
inbox() { cat "$H/inbox.jsonl" 2>/dev/null; }

# ============================================================================ hook
if group hook; then
  echo "hook: what gets forwarded"
  reset; agents "landing sid-a $live"; operator sid-op "$live"

  hook Stop sid-a "Done. Tests pass."
  eq "exits 0" "$hook_rc" 0
  line=$(inbox)
  eq "a reply is recorded with the session's name" "$(jq -r '[.type, .name, .cwd, .pane, .window] | join(" ")' <<<"$line")" "reply landing /w/x %7 main:3"
  eq "a plain reply needs nothing" "$(jq -r .needs <<<"$line")" ""
  eq "the full record is kept for show" "$(jq -r .text "$H/last/sid-a.json")" "Done. Tests pass."

  reset; agents "landing sid-a $live"; operator sid-op "$live"
  hook Stop sid-a "$(printf 'I found two options.\n\nShould I go with A or B?\n')"
  eq "a reply ending in a question needs the user" "$(inbox | jq -r .needs)" question
  reset; agents "landing sid-a $live"; operator sid-op "$live"
  hook Stop sid-a "Want me to commit it? **"
  eq "a question before trailing markdown still counts" "$(inbox | jq -r .needs)" question
  reset; agents "landing sid-a $live"; operator sid-op "$live"
  hook Stop sid-a "Why did it fail? Because the lock was stale. Fixed."
  eq "a question mid-text is not a question" "$(inbox | jq -r .needs)" ""

  reset; agents "landing sid-a $live"; operator sid-op "$live"
  hook Notification sid-a "Claude needs your permission to use Bash" permission_prompt
  eq "a permission prompt is recorded as waiting" "$(inbox | jq -r '[.type, .needs, .kind, .text] | join("|")')" "waiting|dialog|permission_prompt|Claude needs your permission to use Bash"

  reset; agents "landing sid-a $live"; operator sid-op "$live"
  long=$(printf 'x%.0s' $(seq 1 2000))
  SWITCHBOARD_PREVIEW=100 hook Stop sid-a "$long"
  eq "a long reply is cut in the inbox" "$(inbox | jq -r '[.truncated, .chars, (.text | length)] | join(" ")')" "true 2000 101"
  eq "but kept whole for show" "$(jq -r '.text | length' "$H/last/sid-a.json")" 2000

  reset; agents "landing sid-a $live"; operator sid-op "$live"
  hook Stop sid-z "hi"
  eq "an unknown session falls back to its short id" "$(inbox | jq -r .name)" "sid-z"

  reset; agents "landing sid-a $live"; operator sid-op "$live"
  EP=sdk-cli hook Stop sid-a "headless"
  eq "claude -p runs are not forwarded" "$(inbox)" ""
  ATT=0 hook Stop sid-a "unattended"
  eq "unattended sessions are not forwarded" "$(inbox)" ""
  hook Stop sid-op "operator talking"
  eq "the operator's own replies are not forwarded" "$(inbox)" ""
  hook Stop sid-a ""
  eq "an empty reply is not forwarded" "$(inbox)" ""
  hook SubagentStop sid-a "sub"
  eq "other events are ignored" "$(inbox)" ""

  reset; agents "landing sid-a $live"; operator sid-op "$dead"
  hook Stop sid-a "nobody listens"
  eq "nothing is written when the operator's process is gone" "$(inbox)" ""
  eq "and it still exits 0" "$hook_rc" 0
  rm -f "$H/operator.json"
  hook Stop sid-a "no operator"
  eq "nothing is written without an operator" "$(inbox)" ""

  reset; agents "landing sid-a $live"; operator sid-op "$live"
  out=$(printf 'not json' | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_SESSION_ATTENDED=1 "$S/on-hook.sh" 2>&1; echo "rc=$?")
  eq "garbage input: no output, exit 0" "$out" "rc=0"

  reset; agents "landing sid-a $live"; operator sid-op "$live"
  pids=""
  for i in 1 2 3 4 5 6 7 8; do hook Stop sid-a "reply $i" & pids="$pids $!"; done
  wait $pids
  eq "concurrent hooks write whole lines" "$(inbox | jq -r .text | sort | tr '\n' ' ')" "reply 1 reply 2 reply 3 reply 4 reply 5 reply 6 reply 7 reply 8 "
fi

# ============================================================================ watch
if group watch; then
  echo "watch: delivering the inbox"
  reset; operator sid-op "$live"
  printf '%s\n' '{"type":"reply","name":"a"}' '{"type":"reply","name":"b"}' > "$H/inbox.jsonl"
  out=$(CLAUDE_CODE_SESSION_ID=sid-op "$S/watch.sh")
  eq "prints what is waiting and exits" "$(jq -r .name <<<"$out" | tr '\n' ' ')" "a b "
  printf '%s\n' '{"type":"reply","name":"c"}' >> "$H/inbox.jsonl"
  out=$(CLAUDE_CODE_SESSION_ID=sid-op "$S/watch.sh")
  eq "the next run prints only new records" "$(jq -r .name <<<"$out")" "c"

  ( sleep 0.5; printf '%s\n' '{"type":"reply","name":"d"}' >> "$H/inbox.jsonl" ) &
  out=$(CLAUDE_CODE_SESSION_ID=sid-op "$S/watch.sh")
  eq "waits for a record that arrives later" "$(jq -r .name <<<"$out")" "d"

  reset; operator sid-op "$live"
  for i in 1 2 3 4 5; do printf '{"n":%s}\n' "$i"; done > "$H/inbox.jsonl"
  out=$(SWITCHBOARD_BATCH=2 CLAUDE_CODE_SESSION_ID=sid-op "$S/watch.sh")
  eq "a batch is capped" "$(jq -r .n <<<"$out" | tr '\n' ' ')" "1 2 "
  out=$(SWITCHBOARD_BATCH=2 CLAUDE_CODE_SESSION_ID=sid-op "$S/watch.sh")
  eq "the rest comes next" "$(jq -r .n <<<"$out" | tr '\n' ' ')" "3 4 "

  reset; operator sid-op "$live"
  printf '%s\n' '{"n":1}' '{"n":2}' > "$H/inbox.jsonl"; echo 999 > "$H/offset"
  out=$(CLAUDE_CODE_SESSION_ID=sid-op "$S/watch.sh")
  eq "a shrunk inbox starts over" "$(jq -r .n <<<"$out" | tr '\n' ' ')" "1 2 "

  reset; operator sid-other "$live"
  out=$(CLAUDE_CODE_SESSION_ID=sid-op "$S/watch.sh")
  eq "exits when another session took over" "$(jq -c . <<<"$out")" '{"type":"replaced","by":"op"}'
  rm -f "$H/operator.json"
  out=$(CLAUDE_CODE_SESSION_ID=sid-op "$S/watch.sh")
  eq "exits when switchboard was turned off" "$(jq -r .type <<<"$out")" "unregistered"
fi

# ============================================================================ ctl
if group ctl; then
  echo "ctl: register"
  reset; agents "boss sid-op $live"
  echo junk > "$H/inbox.jsonl"
  out=$(CLAUDE_CODE_SESSION_ID=sid-op CLAUDE_PID=$live "$S/ctl.sh" register)
  eq "register prints the operator" "$out" '{"name":"boss","session_id":"sid-op"}'
  eq "and empties the inbox" "$(inbox)" ""
  out=$(CLAUDE_CODE_SESSION_ID=sid-2 CLAUDE_PID=$live "$S/ctl.sh" register 2>&1); rc=$?
  eq "a second operator is refused" "$rc" 1
  has "naming the current one" "$out" "boss is already the operator"
  CLAUDE_CODE_SESSION_ID=sid-2 CLAUDE_PID=$live "$S/ctl.sh" register --force >/dev/null
  eq "--force takes over" "$(jq -r .session_id "$H/operator.json")" sid-2
  operator sid-op "$dead"
  CLAUDE_CODE_SESSION_ID=sid-3 CLAUDE_PID=$live "$S/ctl.sh" register >/dev/null; rc=$?
  eq "a dead operator is replaced without --force" "$rc:$(jq -r .session_id "$H/operator.json")" "0:sid-3"
  out=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID "$S/ctl.sh" register 2>&1); rc=$?
  eq "register outside Claude fails" "$rc" 1
  out=$(CLAUDE_CODE_SESSION_ID=sid-x "$S/ctl.sh" unregister 2>&1); rc=$?
  eq "another session can't unregister a live operator" "$rc" 1
  CLAUDE_CODE_SESSION_ID=sid-3 "$S/ctl.sh" unregister >/dev/null
  eq "the operator can" "$([ -f "$H/operator.json" ] && echo yes || echo no)" no

  echo "ctl: list, show, screen, press"
  reset; agents "boss sid-op $live" "landing sid-a $live" "landing-2 sid-b $dead"; operator sid-op "$live"
  printf '%s %%30 main:9\n' "$live" > "$STUB/panes"
  out=$("$S/ctl.sh" list)
  has "list shows each session" "$out" "landing"
  has "with its tmux window" "$out" "main:9"
  has "and marks the operator" "$out" "boss (operator)"

  hook Stop sid-a "the whole reply"
  eq "show prints the full last reply" "$("$S/ctl.sh" show landing | tail -n 1)" "the whole reply"
  out=$("$S/ctl.sh" show land 2>&1); rc=$?
  eq "an ambiguous name is refused" "$rc" 1
  has "listing the matches" "$out" "landing, landing-2"
  out=$("$S/ctl.sh" show nobody 2>&1); rc=$?
  eq "an unknown name is refused" "$rc" 1

  printf 'line 1\n> Do you want to proceed?\n  1. Yes\n  2. No\n\n\n' > "$STUB/screen"
  out=$("$S/ctl.sh" screen landing)
  has "screen shows the pane" "$out" "1. Yes"
  eq "without trailing blank lines" "$(printf '%s' "$out" | tail -n 1)" "  2. No"
  out=$("$S/ctl.sh" screen landing-2 2>&1); rc=$?
  eq "a session outside tmux has no screen" "$rc" 1

  : > "$STUB/tmux.log"
  "$S/ctl.sh" press landing 2 Enter >/dev/null
  eq "press sends the keys to the pane" "$(grep send-keys "$STUB/tmux.log")" "send-keys -t %30 2 Enter"
  out=$("$S/ctl.sh" press landing "rm -rf /" 2>&1); rc=$?
  eq "free text is not a key" "$rc" 1
  out=$("$S/ctl.sh" press landing C-c 2>&1); rc=$?
  eq "neither is Ctrl-C" "$rc" 1
  out=$("$S/ctl.sh" press boss Enter 2>&1); rc=$?
  has "the operator's own pane is off limits" "$out" "operator's own pane"

  echo "ctl: new"
  reset; agents "boss sid-op $live"; operator sid-op "$live"
  mkdir -p "$T/proj"
  cat > "$STUB/on-new.sh" <<EOF
jq -c '. + [{name: "web", sessionId: "sid-w", pid: $live}]' "$STUB/agents.json" > "$STUB/a.tmp" && mv "$STUB/a.tmp" "$STUB/agents.json"
EOF
  out=$("$S/ctl.sh" new web "$T/proj" "fix the header")
  eq "a new session comes up READY" "$(jq -r .status <<<"$out")" READY
  nw=$(grep '^new-window' "$STUB/tmux.log")
  has "in a new window of main" "$nw" "new-window -d -t =main: -n web -c $T/proj"
  has "running claude with its name and the prompt" "$nw" "claude -n web fix the header"
  out=$("$S/ctl.sh" new web "$T/proj" 2>&1); rc=$?
  eq "a name that is taken is refused" "$rc" 1

  reset; agents "boss sid-op $live"; operator sid-op "$live"
  printf ' Is this a project you created or one you trust?\n' > "$STUB/screen"
  out=$("$S/ctl.sh" new api "$T/proj")
  eq "an untrusted folder reports TRUST" "$(jq -r .status <<<"$out")" TRUST
  has "and says how to go on" "$(jq -r .message <<<"$out")" "Pressing Enter"

  reset; agents "boss sid-op $live"; touch "$STUB/no-session"
  out=$("$S/ctl.sh" new api "$T/proj")
  has "without a main session, one is created" "$(cat "$STUB/tmux.log")" "new-session -d -s main -n api"
  eq "a session that never shows up is STARTING" "$(jq -r .status <<<"$out")" STARTING

  reset; agents; touch "$STUB/gone"
  eq "a session that dies at once is EXITED" "$("$S/ctl.sh" new api "$T/proj" | jq -r .status)" EXITED

  reset; agents
  out=$("$S/ctl.sh" new "bad name" "$T/proj" 2>&1); rc=$?
  eq "names with spaces are refused" "$rc" 1
  out=$("$S/ctl.sh" new 'x;rm' "$T/proj" 2>&1); rc=$?
  eq "names with shell characters are refused" "$rc" 1
  out=$("$S/ctl.sh" new api "$T/nope" 2>&1); rc=$?
  eq "a missing folder is refused" "$rc" 1
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
