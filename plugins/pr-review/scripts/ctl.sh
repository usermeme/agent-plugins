#!/usr/bin/env bash
# pr-review control script. Every decision that doesn't need a model is made here: which
# folder and session a PR belongs to, whether a round is needed, the round counters, when
# the review is over, and the message for the authoring session. State is on disk under
# $PR_REVIEW_HOME (default ~/.claude/pr-review); no model ever reads it.
#
#   ctl.sh run <pr_url> [opened|new-sha|reply|threads-resolved|recheck]
#       Decide what the PR needs and, if it needs one, run a headless review round.
#       Prints one JSON line: {url, status, head_sha, round, origin, message, note}
#         WAITING      comments are open; `message` is for the authoring session
#         FINISHED     nothing is open; the review is over
#         STALLED      two rounds in a row resolved nothing; the user has to step in
#         ROUND-CAP    PR_REVIEW_MAX_ROUNDS automatic rounds in a row; same
#         SKIPPED      nothing to do (duplicate event, nothing new)
#         BUSY         a round for this PR is running and will pick the event up
#         CLOSED       the PR is merged or closed; its worktree and state are gone
#         NO-CHECKOUT  no local checkout of the PR's repo was found
#         ERROR        see `note`; nothing was recorded, the next event tries again
#   ctl.sh stop <pr_url>      forget a PR: remove its worktree and state
#   ctl.sh reset <pr_url>     zero the stop counters (the user said to continue)
#   ctl.sh sweep              forget every tracked PR that is no longer open
#   ctl.sh status             one line per tracked PR
#
# Environment: PR_REVIEW_MAX_ROUNDS (10; 0 = no cap), PR_REVIEW_MODEL, PR_REVIEW_EFFORT,
# PR_REVIEW_MAX_BUDGET_USD, PR_REVIEW_TIMEOUT (seconds per round, 1800),
# PR_REVIEW_MAX_PARALLEL (3), PR_REVIEW_SEARCH_ROOTS (~/git, colon-separated).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

PRR="$here/prr.sh"
plugin_root=$(cd "$here/.." && pwd)
pushes="$home/pushes.jsonl"
max_rounds="${PR_REVIEW_MAX_ROUNDS:-10}"
tmp=""

sessions() { claude agents --json 2>/dev/null || echo '[]'; }

# ---------------------------------------------------------------- local checkouts

is_temp() {
  case "$1" in /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) return 0 ;; esac
  return 1
}

# slug_of_remote <remote url> -> owner/repo in lower case, for any host alias or protocol
slug_of_remote() {
  lc "$1" | sed -E 's#\.git$##; s#/$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#'
}

# remote_for <dir>: the name of the remote in <dir> that points at the PR's repo
remote_for() {
  local want r u
  [ -n "$1" ] && [ -d "$1" ] || return 1
  want=$(lc "$owner_repo")
  for r in $(git -C "$1" remote 2>/dev/null); do
    u=$(git -C "$1" remote get-url "$r" 2>/dev/null) || continue
    if [ "$(slug_of_remote "$u")" = "$want" ]; then echo "$r"; return 0; fi
  done
  return 1
}

# stable_checkout <dir>: the checkout <dir> is in. A session's scratchpad worktree is
# deleted with the session, so for a temp folder pick another checkout of the same repo.
stable_checkout() {
  local top wt
  [ -n "$1" ] && [ -d "$1" ] || return 1
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  case "$top" in */.claude/worktrees/*) return 1 ;; esac
  if ! is_temp "$top"; then echo "$top"; return 0; fi
  git -C "$top" worktree list --porcelain 2>/dev/null |
    awk '/^worktree /{p = substr($0, 10)} /^bare$/{p = ""} /^$/{if (p != "") print p; p = ""} END{if (p != "") print p}' |
    while IFS= read -r wt; do
      is_temp "$wt" && continue
      case "$wt" in */.claude/worktrees/*) continue ;; esac
      [ -d "$wt" ] || continue
      echo "$wt"; break
    done
}

# find_repo: a working tree under the search roots with a remote for the PR's repo
find_repo() {
  local root g d roots
  IFS=':' read -r -a roots <<<"${PR_REVIEW_SEARCH_ROOTS:-$HOME/git}"
  for root in "${roots[@]}"; do
    [ -d "$root" ] || continue
    while IFS= read -r g; do
      d=$(dirname "$g")
      case "$d" in */.claude/worktrees/*) continue ;; esac
      [ "$(git -C "$d" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || continue
      remote_for "$d" >/dev/null || continue
      echo "$d"; return 0
    done < <(find "$root" -maxdepth 5 \( -name node_modules -prune \) -o \( -name .git -prune -print \) 2>/dev/null)
  done
  return 1
}

# ---------------------------------------------------------------- who pushed what

# attr_lines: the push records (written by the hook) that belong to this PR, oldest first
attr_lines() {
  [ -s "$pushes" ] || return 0
  jq -c -R --arg url "$url" --arg repo "$(lc "$owner_repo")" --arg branch "$p_branch" '
    fromjson? | select(type == "object")
    | select((.pr_url // "") == $url
             or ($branch != "" and (.branch // "") == $branch and ((.repos // []) | index($repo))))' "$pushes" 2>/dev/null || true
}

# pushed_by_session <sha>: did a Claude Code session push this commit?
pushed_by_session() {
  attr_lines | jq -e -s --arg h "$1" 'any(.[]; (.head_sha // "") == $h)' >/dev/null
}

# resolve_origin: the live session that last pushed to this PR -> o_origin (name or "-")
resolve_origin() {
  local sid n
  sid=$(attr_lines | jq -r -s 'last | .session_id // ""')
  [ -n "$sid" ] || sid="$s_origin_sid"
  s_origin_sid="$sid"
  o_origin="-"
  [ -n "$sid" ] || return 0
  n=$(sessions | jq -r --arg id "$sid" '[.[] | select(.sessionId == $id) | .name // ""][0] // ""' 2>/dev/null || true)
  [ -z "$n" ] || o_origin="$n"
}

# resolve_dir: the checkout to put the reviewer's worktree in -> dir, remote.
# The saved one wins, so a PR never ends up with two worktrees. Every candidate must
# have a remote for the PR's repo: a session often pushes to a repo it wasn't started in.
resolve_dir() {
  local c
  dir=""; remote=""
  if remote=$(remote_for "$s_launch_dir"); then dir="$s_launch_dir"; return 0; fi
  while IFS= read -r c; do
    c=$(stable_checkout "$c") || continue
    [ -n "$c" ] || continue
    if remote=$(remote_for "$c"); then dir="$c"; return 0; fi
  done < <(attr_lines | jq -r -s 'reverse | .[] | .dir // empty')
  c=$(find_repo) || return 1
  remote=$(remote_for "$c") || return 1
  dir="$c"
}

# ---------------------------------------------------------------- state, locks

s_file() { echo "$home/prs/$key.json"; }
s_get() { jq -r --arg d "$2" "$1 // \$d" "$(s_file)" 2>/dev/null || echo "$2"; }

s_load() {
  s_launch_dir=$(s_get .launch_dir ""); s_origin_sid=$(s_get .origin_session_id "")
  s_session=$(s_get .session_id "");    s_last_sha=$(s_get .last_sha "")
  s_round=$(s_get .round 0); s_auto=$(s_get .auto 0); s_stall=$(s_get .stall 0)
  s_runs=$(s_get .runs 0)
  s_status=$(s_get .status "")
}

s_save() {
  mkdir -p "$home/prs"
  jq -n --arg url "$url" --arg launch_dir "$s_launch_dir" --arg origin "$s_origin_sid" \
        --arg session "$s_session" --arg last_sha "$s_last_sha" --arg status "$s_status" \
        --argjson round "$s_round" --argjson auto "$s_auto" --argjson stall "$s_stall" \
        --argjson runs "$s_runs" --arg at "$(date -u +%FT%TZ)" \
    '{url: $url, launch_dir: $launch_dir, origin_session_id: $origin, session_id: $session,
      last_sha: $last_sha, status: $status, round: $round, auto: $auto, stall: $stall,
      runs: $runs, updated_at: $at}' \
    > "$(s_file).tmp"
  mv "$(s_file).tmp" "$(s_file)"
}

# lock_take <dir>: an atomic lock that survives a crashed holder
lock_take() {
  local pid
  mkdir -p "$(dirname "$1")"
  if mkdir "$1" 2>/dev/null; then echo $$ > "$1/pid"; return 0; fi
  pid=$(cat "$1/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 1; fi
  rm -rf "$1"
  mkdir "$1" 2>/dev/null || return 1
  echo $$ > "$1/pid"
}

cleanup() {
  [ -z "${held_lock:-}" ] || rm -rf "$held_lock"
  [ -z "${held_slot:-}" ] || rm -rf "$held_slot"
  [ -z "$tmp" ] || rm -rf "$tmp"
}

# slot_take: at most PR_REVIEW_MAX_PARALLEL reviewers run at once; wait for a free slot
slot_take() {
  local n="${PR_REVIEW_MAX_PARALLEL:-3}" i
  while :; do
    i=1
    while [ "$i" -le "$n" ]; do
      if lock_take "$home/slots/$i"; then held_slot="$home/slots/$i"; return 0; fi
      i=$((i + 1))
    done
    sleep 5
  done
}

# ---------------------------------------------------------------- worktree

# Keep reviewer worktrees out of `git status`, so an authoring session's `git add -A`
# can't commit one as an embedded repo. info/exclude is local and never committed.
exclude_worktrees() {
  local ex
  ex="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
  mkdir -p "$(dirname "$ex")"
  grep -qxF '.claude/worktrees/' "$ex" 2>/dev/null && return 0
  # Don't glue the rule onto a last line that has no newline.
  if [ -s "$ex" ] && [ -n "$(tail -c 1 "$ex")" ]; then echo >> "$ex"; fi
  echo '.claude/worktrees/' >> "$ex"
}

# prepare_worktree: a detached worktree at exactly $p_head, or fail with o_note set.
# Nothing is cloned: the commit is normally local already (it was pushed from this
# machine); otherwise only the PR head is fetched.
prepare_worktree() {
  git -C "$dir" worktree prune 2>/dev/null || true
  if ! git -C "$dir" cat-file -e "$p_head^{commit}" 2>/dev/null; then
    git -C "$dir" fetch --quiet "$remote" "pull/$number/head" 2>/dev/null || true
    if ! git -C "$dir" cat-file -e "$p_head^{commit}" 2>/dev/null; then
      o_note="commit ${p_head:0:7} is not in $dir and could not be fetched"; return 1
    fi
  fi
  exclude_worktrees "$dir"
  if [ -e "$wt/.git" ]; then
    git -C "$wt" checkout --quiet --force --detach "$p_head" 2>/dev/null ||
      { o_note="could not check out ${p_head:0:7} in $wt"; return 1; }
  else
    mkdir -p "$(dirname "$wt")"
    git -C "$dir" worktree add --quiet --force --detach "$wt" "$p_head" 2>/dev/null ||
      { o_note="could not create a worktree at $wt"; return 1; }
  fi
  if [ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" != "$p_head" ]; then
    o_note="the worktree is not at ${p_head:0:7}"; return 1
  fi
}

remove_worktree() {
  local d="${1:-$s_launch_dir}" w
  [ -n "$d" ] && [ -d "$d" ] || return 0
  w="$d/.claude/worktrees/$name"
  # Detached, and the reviewer cannot commit: there is never anything to lose here.
  if [ -e "$w" ]; then git -C "$d" worktree remove --force "$w" 2>/dev/null || rm -rf "$w"; fi
  git -C "$d" worktree prune 2>/dev/null || true
  rmdir "$d/.claude/worktrees" "$d/.claude" 2>/dev/null || true
}

# ---------------------------------------------------------------- the reviewer

# with_timeout <seconds> <command...>: stock macOS has no timeout(1)
with_timeout() {
  local t="$1" pid wd rc=0
  shift
  "$@" &
  pid=$!
  ( trap 'kill "$s" 2>/dev/null; exit 0' TERM; sleep "$t" & s=$!; wait "$s" && kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  wd=$!
  wait "$pid" || rc=$?
  kill "$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true
  return "$rc"
}

# reviewer <prompt> <session id to resume, or "">: one headless run in $wt.
#   --restricted      file tools are confined to the worktree, and the repo's own
#                     settings, hooks and MCP servers are not loaded
#   dontAsk + rules   the only shell commands are the exact prr.sh forms; the only
#                     writable file is .pr-review/actions.json
reviewer() {
  local args
  args=(-p --restricted --strict-mcp-config --output-format json --permission-mode dontAsk
        --plugin-dir "$plugin_root" --tools "Read,Glob,Grep,Bash,Write,Edit,Skill")
  if [ -d "$HOME/.claude/skills" ]; then args+=(--add-dir "$HOME/.claude/skills"); fi
  if [ -n "${PR_REVIEW_MODEL:-}" ]; then args+=(--model "$PR_REVIEW_MODEL"); fi
  if [ -n "${PR_REVIEW_EFFORT:-}" ]; then args+=(--effort "$PR_REVIEW_EFFORT"); fi
  if [ -n "${PR_REVIEW_MAX_BUDGET_USD:-}" ]; then args+=(--max-budget-usd "$PR_REVIEW_MAX_BUDGET_USD"); fi
  if [ -n "$2" ]; then args+=(--resume "$2"); fi
  args+=(--allowedTools "Read" "Glob" "Grep" "Skill" "Edit(//$wt/.pr-review/**)"
         "Bash($PRR context)" "Bash($PRR diff)" "Bash($PRR diff --since)" "Bash($PRR diff --names)"
         "Bash($PRR log)" "Bash($PRR log --since)" "Bash($PRR submit)")
  : > "$tmp/claude.json"
  ( cd "$wt" && with_timeout "${PR_REVIEW_TIMEOUT:-1800}" claude "${args[@]}" -- "$1" \
      < /dev/null > "$tmp/claude.json" 2> "$tmp/claude.err" ) || return 1
  [ "$(jq -r '.is_error // false' "$tmp/claude.json" 2>/dev/null)" = false ]
}

# ---------------------------------------------------------------- GitHub side effects

post_comment() {
  gh api "repos/$owner_repo/issues/$number/comments" -f body="$1" >/dev/null 2>&1 || true
}

pj() { jq -r "$1" "${2:-$tmp/pr.json}"; }

# message <status> <summary> <pr json>: what the authoring session is told -> o_message
message() {
  local n
  n=$(pj '[.threads[] | select(.resolved | not)] | length' "$3")
  case "$1" in
    FINISHED)
      o_message="pr-review: $owner_repo#$number is clean at ${p_head:0:7}. Nothing to do." ;;
    STALLED)
      o_message="pr-review: $owner_repo#$number stopped. Two rounds in a row resolved none of the $n open comments. Stop fixing it on your own; the user will take over." ;;
    ROUND-CAP)
      o_message="pr-review: $owner_repo#$number stopped after $max_rounds automatic rounds with $n comments still open. Stop fixing it on your own; the user will take over." ;;
    WAITING)
      o_message=$(jq -r --arg repo "$owner_repo" --arg num "$number" --arg sha "${p_head:0:7}" \
                        --arg sum "$2" --arg url "$url" -f "$here/message.jq" "$3") ;;
  esac
}

# ---------------------------------------------------------------- one round

# round_once <reason> -> o_status, o_note, o_message, o_head, o_round, o_origin
round_once() {
  local reason="$1" reviewed open awaiting mode="" round auto stall
  o_status=ERROR; o_note=""; o_message=""; o_head=""; o_round=0; o_origin="-"

  if ! pr_fetch > "$tmp/pr.json"; then o_note="could not read the PR from GitHub"; return 0; fi
  p_state=$(pj .state); p_head=$(pj .head); p_branch=$(pj .branch)
  o_head="$p_head"
  s_load

  if [ "$p_state" != OPEN ]; then
    remove_worktree; rm -f "$(s_file)" "$home/pending/$key"
    o_status=CLOSED; o_note="the PR is $(lc "$p_state")"; return 0
  fi
  if [ "$(pj .viewer)" != "$(pj .author)" ]; then
    o_status=SKIPPED; o_note="not your PR"; return 0
  fi

  # The last reviewed commit: from local state, or, when that is gone, from the newest
  # signed comment on GitHub.
  reviewed="$s_last_sha"
  [ -n "$reviewed" ] || reviewed=$(pj '.marker.sha // ""')
  [ "$s_round" -gt 0 ] || s_round=$(pj '.marker.round // 0')
  open=$(pj '[.threads[] | select(.resolved | not)] | length')
  awaiting=$(pj '[.threads[] | select(.awaiting)] | length')
  o_round="$s_round"
  resolve_origin

  if [ "$p_head" != "$reviewed" ]; then
    if [ -z "$reviewed" ]; then mode=first; else mode=round; fi
  elif [ "$open" -eq 0 ]; then
    # Reviewed at this commit and nothing is open (the threads were fixed, or resolved by
    # hand): the review is over. No reviewer run is needed to see that.
    if ! pj '.clean[]' | grep -qx "$p_head"; then
      post_comment "✅ pr-review: no open findings at ${p_head:0:7}.$(footer "$p_head" "$s_round" clean)"
      o_status=FINISHED; message FINISHED "" "$tmp/pr.json"
    else
      o_status=SKIPPED; o_note="already clean at ${p_head:0:7}"
    fi
    remove_worktree
    s_last_sha="$p_head"; s_status=FINISHED; s_session=""; s_auto=0; s_stall=0; s_save
    return 0
  elif [ "$awaiting" -gt 0 ] || [ "$reason" = recheck ]; then
    mode=recheck
  elif [ "$reason" = opened ]; then
    # Asked to look at a PR that already has open comments at this commit: say so again.
    s_last_sha="$p_head"; s_status=WAITING; s_save
    o_status=WAITING; message WAITING "" "$tmp/pr.json"; return 0
  else
    o_status=SKIPPED; o_note="nothing new at ${p_head:0:7}: $open comment(s) open, waiting for a push or a reply"
    return 0
  fi

  if ! resolve_dir; then
    o_status=NO-CHECKOUT
    o_note="no local checkout of $owner_repo under ${PR_REVIEW_SEARCH_ROOTS:-$HOME/git}"; return 0
  fi
  case "$PRR$dir" in *[[:space:]]*) o_note="paths with spaces are not supported: $PRR / $dir"; return 0 ;; esac
  wt="$dir/.claude/worktrees/$name"
  # A PR keeps one worktree: if it moved to another checkout, drop the old one.
  if [ -n "$s_launch_dir" ] && [ "$s_launch_dir" != "$dir" ]; then remove_worktree "$s_launch_dir"; s_session=""; fi
  prepare_worktree || return 0
  s_launch_dir="$dir"

  # Counters. A round is "automatic" when a Claude Code session pushed the commit under
  # review (the hook recorded it). A push from anywhere else is the user's own: it breaks
  # the streak. Nothing here depends on the authoring session's cooperation.
  round="$s_round"; auto="$s_auto"; stall="$s_stall"
  case "$mode" in
    first) round=$((s_round + 1)); auto=0; stall=0 ;;
    round) round=$((s_round + 1))
           if pushed_by_session "$p_head"; then auto=$((s_auto + 1)); else auto=0; stall=0; fi ;;
  esac
  o_round="$round"

  # Pin prr.sh to this PR. The context lives in the worktree's private git dir, which the
  # reviewer cannot write; .pr-review/ is the one place it can.
  local gitdir id prev=""
  gitdir=$(git -C "$wt" rev-parse --absolute-git-dir)
  # One id per completed run. A run that failed half-way keeps its id, so the retry
  # does not post again what prr.sh already posted.
  id="$p_head:$round:$mode:$s_runs"
  rm -f "$gitdir/pr-review-result.json"
  if [ "$mode" != first ]; then prev="$reviewed"; fi
  jq -n --arg id "$id" --arg url "$url" --arg repo "$owner_repo" --argjson number "$number" \
        --arg head "$p_head" --arg previous "$prev" --argjson round "$round" --arg mode "$mode" \
    '{id: $id, url: $url, repo: $repo, number: $number, head: $head,
      previous: (if $previous == "" then null else $previous end), round: $round, mode: $mode}' \
    > "$gitdir/pr-review-context.json"
  rm -rf "$wt/.pr-review"; mkdir "$wt/.pr-review"
  pj '[.threads[] | select(.resolved | not) | .id]' > "$tmp/open-before.json"

  if [ -n "$s_session" ]; then
    reviewer "Next run for this PR: mode $mode, round $round. Start with: $PRR context" "$s_session" || true
    # Only a missing conversation is worth a second, fresh attempt. A timeout or a spending
    # limit is not: that would run (and pay for) the same round twice.
    if grep -q 'No conversation found' "$tmp/claude.err" 2>/dev/null; then s_session=""; fi
  fi
  # No conversation to resume: a fresh one picks up everything it needs from `context`.
  if [ -z "$s_session" ]; then
    reviewer "/pr-review:review tool=$PRR" "" || true
  fi

  local sid summary
  sid=$(jq -r '.session_id // ""' "$tmp/claude.json" 2>/dev/null || true)
  if [ "$(jq -r '.id // ""' "$gitdir/pr-review-result.json" 2>/dev/null)" != "$id" ]; then
    o_note="the reviewer ended without submitting ($(jq -r '.result // empty' "$tmp/claude.json" 2>/dev/null | tail -1 | cut -c1-200)$(head -1 "$tmp/claude.err" 2>/dev/null | cut -c1-200))"
    # Keep the conversation: the next event resumes it, and prr.sh won't repeat what it
    # already posted for this run.
    if [ -n "$sid" ]; then s_session="$sid"; s_status="${s_status:-WAITING}"; s_save; fi
    return 0
  fi
  summary=$(jq -r '.summary // ""' "$gitdir/pr-review-result.json")
  s_runs=$((s_runs + 1))

  # What happened to the threads decides everything else.
  local tries=0 open_after resolved
  until pr_fetch > "$tmp/pr2.json"; do
    tries=$((tries + 1))
    if [ "$tries" -ge 3 ]; then cp "$tmp/pr.json" "$tmp/pr2.json"; o_note="could not re-read the threads after the round"; break; fi
    sleep 3
  done
  open_after=$(pj '[.threads[] | select(.resolved | not)] | length' "$tmp/pr2.json")
  resolved=$(jq -n --slurpfile b "$tmp/open-before.json" --slurpfile a "$tmp/pr2.json" \
    '[ $a[0].threads[] | select(.resolved | not) | .id ] as $now | [ $b[0][] | select(. as $x | $now | index($x) | not) ] | length')
  if [ "$(jq length "$tmp/open-before.json")" -gt 0 ]; then
    if [ "$resolved" -gt 0 ]; then stall=0; else stall=$((stall + 1)); fi
  fi

  local status=WAITING
  if [ "$open_after" -eq 0 ]; then status=FINISHED
  elif [ "$stall" -ge 2 ]; then status=STALLED
  elif [ "$max_rounds" -gt 0 ] && [ "$auto" -ge "$max_rounds" ]; then status=ROUND-CAP
  fi

  local was="$s_status"
  s_round="$round"; s_last_sha="$p_head"; s_status="$status"
  case "$status" in
    WAITING)
      s_auto="$auto"; s_stall="$stall"; s_session="$sid" ;;
    FINISHED)
      post_comment "✅ pr-review: no open findings at ${p_head:0:7}.$(footer "$p_head" "$round" clean)"
      s_auto=0; s_stall=0; s_session=""; remove_worktree "$dir" ;;
    STALLED)
      # Said once is enough: don't add the same notice on every further stuck round.
      [ "$was" = STALLED ] ||
        post_comment "⏸ pr-review stopped at ${p_head:0:7}: two rounds in a row resolved none of the $open_after open comments. Push a fix, reply, or resolve them by hand.$(footer "$p_head" "$round")"
      s_auto="$auto"; s_stall="$stall"; s_session=""; remove_worktree "$dir" ;;
    ROUND-CAP)
      [ "$was" = ROUND-CAP ] ||
        post_comment "⏸ pr-review stopped at ${p_head:0:7}: $max_rounds automatic rounds in a row, and $open_after comments are still open.$(footer "$p_head" "$round")"
      s_auto="$auto"; s_stall="$stall"; s_session=""; remove_worktree "$dir" ;;
  esac
  s_save
  o_status="$status"; message "$status" "$summary" "$tmp/pr2.json"
}

emit() {
  jq -nc --arg url "$url" --arg status "$r_status" --arg head "$r_head" --argjson round "${r_round:-0}" \
         --arg origin "$r_origin" --arg message "$r_message" --arg note "$r_note" \
    '{url: $url, status: $status, head_sha: $head, round: $round, origin: $origin, message: $message, note: $note}'
}

cmd_run() {
  local reason="${2:-new-sha}" chained=0
  parse_pr "$1"
  case "$reason" in opened|new-sha|reply|threads-resolved|recheck) ;; *) die "unknown reason: $reason" ;; esac
  mkdir -p "$home/prs" "$home/pending"
  trap cleanup EXIT
  r_status=""; r_head=""; r_round=0; r_origin="-"; r_message=""; r_note=""

  if ! lock_take "$home/locks/$key"; then
    # A round is running. Leave it a note; it looks for one before it lets go.
    echo "$reason" > "$home/pending/$key"
    sleep 2
    if ! lock_take "$home/locks/$key"; then
      r_status=BUSY; r_note="a round for this PR is running and will pick this up"; emit; return 0
    fi
    rm -f "$home/pending/$key"
  fi
  held_lock="$home/locks/$key"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/pr-review.XXXXXX")
  slot_take

  while :; do
    round_once "$reason"
    # A follow-up that had nothing to do must not hide the result of the round before it.
    if [ -z "$r_status" ] || [ "$o_status" != SKIPPED ]; then
      r_status="$o_status"; r_head="$o_head"; r_round="$o_round"; r_origin="$o_origin"
      r_message="$o_message"; r_note="$o_note"
    fi
    [ -e "$home/pending/$key" ] || break
    reason=$(cat "$home/pending/$key" 2>/dev/null || echo new-sha)
    rm -f "$home/pending/$key"
    case "$reason" in opened|new-sha|reply|threads-resolved|recheck) ;; *) reason=new-sha ;; esac
    chained=$((chained + 1))
    [ "$chained" -le 3 ] || break
    case "$o_status" in CLOSED|NO-CHECKOUT) break ;; esac
  done
  emit
}

cmd_stop() {
  parse_pr "$1"
  s_load
  remove_worktree
  rm -f "$(s_file)" "$home/pending/$key"
  echo "stopped $name"
}

cmd_reset() {
  parse_pr "$1"
  [ -f "$(s_file)" ] || die "not tracking $url"
  s_load
  s_auto=0; s_stall=0; s_save
  echo "counters reset for $url"
}

cmd_sweep() {
  local f u state
  for f in "$home"/prs/*.json; do
    [ -e "$f" ] || continue
    u=$(jq -r '.url // ""' "$f" 2>/dev/null || true)
    [ -n "$u" ] || continue
    state=$(gh pr view "$u" --json state -q .state 2>/dev/null || echo UNKNOWN)
    if [ "$state" = MERGED ] || [ "$state" = CLOSED ]; then
      ( cmd_stop "$u" >/dev/null ) && echo "swept $u ($(lc "$state"))"
    fi
  done
}

cmd_status() {
  local f
  for f in "$home"/prs/*.json; do
    [ -e "$f" ] || continue
    jq -r '"\(.url)  \(.status)  round \(.round)  automatic \(.auto)  no-progress \(.stall)  at \(.last_sha[0:7])"' "$f" 2>/dev/null || true
  done
}

case "${1:-}" in
  run)    [ $# -ge 2 ] || die "usage: ctl.sh run <pr_url> [reason]"; cmd_run "$2" "${3:-new-sha}" ;;
  stop)   [ $# -eq 2 ] || die "usage: ctl.sh stop <pr_url>"; cmd_stop "$2" ;;
  reset)  [ $# -eq 2 ] || die "usage: ctl.sh reset <pr_url>"; cmd_reset "$2" ;;
  sweep)  cmd_sweep ;;
  status) cmd_status ;;
  *)      sed -n '2,28p' "$0"; exit 2 ;;
esac
