#!/usr/bin/env bash
# The listener's background watcher. It blocks until there is work, prints one JSON event
# per line, and exits (the listener is re-invoked when it exits, handles the events and
# starts it again).
#
# Events come only from GitHub's own state, polled and compared with the last snapshot:
#   baseline          first run ever: the PRs that are already open
#   pr-opened         a PR appeared
#   new-sha           a PR's head commit changed
#   reply             you answered one of the reviewer's threads without pushing
#   threads-resolved  the reviewer's last open thread was resolved without a push
#   pr-closed         a PR was merged or closed (confirmed with a second request)
#   error             GitHub can't be reached, or another watcher is running
#
# The hook's push log is only a hint to poll now instead of at the next interval.
#
# Which PRs: open, authored by you, in repos you can push to (so never somebody else's
# project). PR_REVIEW_OWNERS=a,b narrows that to those owners; PR_REVIEW_SKIP_DRAFTS=1
# leaves drafts out. At most your 50 newest open PRs are watched.
set -u

home="${PR_REVIEW_HOME:-$HOME/.claude/pr-review}"
snap="$home/snapshot.json"
pushes="$home/pushes.jsonl"
seen="$home/pushes.seen"
pidfile="$home/watch.pid"
poll_every="${PR_REVIEW_POLL_SECONDS:-90}"
mkdir -p "$home"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pr-review.XXXXXX")

# One watcher at a time: two would share the snapshot and start every round twice.
old=$(cat "$pidfile" 2>/dev/null || true)
if [ -n "$old" ] && [ "$old" != "$$" ] && kill -0 "$old" 2>/dev/null &&
   ps -p "$old" -o command= 2>/dev/null | grep -q 'watch\.sh'; then
  jq -nc --arg p "$old" '{type: "error", message: "another pr-review watcher is already running (pid \($p)); only one listener can run at a time"}'
  rm -rf "$tmp"; exit 0
fi
echo $$ > "$pidfile"
trap 'rm -rf "$tmp"; [ "$(cat "$pidfile" 2>/dev/null)" = "$$" ] && rm -f "$pidfile"' EXIT

# Keep the push log small.
if [ -f "$pushes" ] && [ "$(wc -l < "$pushes" | tr -d ' ')" -gt 400 ]; then
  tail -n 200 "$pushes" > "$tmp/pushes" && mv "$tmp/pushes" "$pushes"
fi

query='query($q: String!) {
  viewer { login }
  search(query: $q, type: ISSUE, first: 50) {
    nodes { ... on PullRequest {
      url number headRefName headRefOid isDraft
      repository { nameWithOwner viewerPermission owner { login } }
      reviewThreads(first: 100) { nodes {
        isResolved
        first: comments(first: 1) { nodes { body author { login } } }
        last: comments(last: 1) { nodes { body author { login } } }
      } }
    } }
  }
}'

owners=$(printf '%s' "${PR_REVIEW_OWNERS:-}" | tr 'A-Z' 'a-z' | jq -R -c 'split(",") | map(gsub("\\s"; "")) | map(select(length > 0))')
skip_drafts=false
[ "${PR_REVIEW_SKIP_DRAFTS:-0}" = 1 ] && skip_drafts=true

# poll: prints the current list, or fails (and never prints a partial one).
poll() {
  gh api graphql -f query="$query" -f q='is:pr is:open author:@me archived:false sort:created-desc' \
      > "$tmp/raw.json" 2> "$tmp/poll.err" || return 1
  jq -c --argjson owners "${owners:-[]}" --argjson skip_drafts "$skip_drafts" '
    if ((.errors // []) | length) > 0 or ((.data.search.nodes | type) != "array") then error("incomplete response") else . end
    | .data.viewer.login as $me
    | [ .data.search.nodes[] | select(.url != null)
        | select(.repository.viewerPermission as $p | ["ADMIN", "MAINTAIN", "WRITE"] | index($p))
        | select(($owners | length) == 0 or ((.repository.owner.login | ascii_downcase) as $o | $owners | index($o)))
        | select(($skip_drafts | not) or (.isDraft | not))
        | [ .reviewThreads.nodes[] | select(.isResolved | not)
            | select((.first.nodes[0].author.login // "") == $me
                     and ((.first.nodes[0].body // "") | contains("<!-- pr-review"))) ] as $open
        | { url, number, repo: .repository.nameWithOwner, branch: .headRefName, head_sha: .headRefOid,
            draft: .isDraft, open_threads: ($open | length),
            awaiting: ([ $open[] | select((.last.nodes[0].author.login // "") == $me
                                          and (((.last.nodes[0].body // "") | contains("<!-- pr-review")) | not)) ] | length) } ]
  ' "$tmp/raw.json" 2>> "$tmp/poll.err"
}

# diff_events <old> <new>: prints events; pr-closed ones are only candidates.
diff_events() {
  jq -nc --argjson old "$1" --argjson new "$2" '
    ($old | map({(.url): .}) | add // {}) as $o
    | ($new | map({(.url): .}) | add // {}) as $n
    | ( $new[] | . as $p | $o[$p.url] as $q
        | if $q == null then {type: "pr-opened"} + $p
          elif $q.head_sha != $p.head_sha then {type: "new-sha", previous_sha: $q.head_sha} + $p
          elif ($q.open_threads // 0) > 0 and $p.open_threads == 0 then {type: "threads-resolved"} + $p
          elif $p.awaiting > ($q.awaiting // 0) then {type: "reply"} + $p
          else empty end ),
      ( $old[] | select($n[.url] == null) | {type: "pr-closed"} + . )'
}

pushes_size() { if [ -f "$pushes" ]; then wc -c < "$pushes" | tr -d ' '; else echo 0; fi; }

next_poll=0; fast_until=0; fails=0
while :; do
  had_events=1
  now=$(date +%s)

  # A session just pushed: look at GitHub now, and keep looking closely for a while,
  # because GitHub can take a few seconds to show a new head.
  size=$(pushes_size)
  if [ "${size:-0}" != "$(cat "$seen" 2>/dev/null || echo 0)" ]; then
    echo "${size:-0}" > "$seen"
    fast_until=$((now + 90))
    [ "$next_poll" -gt $((now + 3)) ] && next_poll=$((now + 3))
  fi

  if [ "$now" -ge "$next_poll" ]; then
    if current=$(poll) && [ -n "$current" ]; then
      fails=0
      if [ ! -s "$snap" ]; then
        jq -c '{type: "baseline", prs: .}' <<<"$current"
        had_events=0
      else
        diff_events "$(cat "$snap")" "$current" > "$tmp/events" 2>/dev/null || : > "$tmp/events"
        while IFS= read -r ev; do
          [ -n "$ev" ] || continue
          if [ "$(jq -r .type <<<"$ev")" = pr-closed ]; then
            # Missing from the list is not proof. Ask GitHub about this one PR.
            state=$(gh pr view "$(jq -r .url <<<"$ev")" --json state -q .state 2>/dev/null || echo UNKNOWN)
            if [ "$state" != MERGED ] && [ "$state" != CLOSED ]; then
              current=$(jq -c --argjson e "$ev" '. + [$e | del(.type)]' <<<"$current")
              continue
            fi
          fi
          printf '%s\n' "$ev"
          had_events=0
        done < "$tmp/events"
      fi
      printf '%s\n' "$current" > "$snap.tmp" && mv "$snap.tmp" "$snap"
    else
      fails=$((fails + 1))
      if [ "$fails" -ge 5 ]; then
        jq -nc --arg m "$(head -1 "$tmp/poll.err" 2>/dev/null | cut -c1-200)" \
          '{type: "error", message: ("GitHub polling keeps failing: " + (if $m == "" then "no details" else $m end) + ". Check `gh auth status` and the network.")}'
        had_events=0; fails=0
      fi
    fi
    if [ "$now" -lt "$fast_until" ]; then next_poll=$((now + 10)); else next_poll=$((now + poll_every)); fi
  fi

  [ "$had_events" -eq 0 ] && exit 0
  sleep "${PR_REVIEW_TICK:-5}"
done
