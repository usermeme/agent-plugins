#!/usr/bin/env bash
# Listener's background watcher. Blocks until there is work, prints one JSON event
# per line on stdout, then exits (the listener is re-invoked when it exits).
#
# Event sources:
#   1. hook events from the inbox (written by on-bash.sh) -> pr-create | push
#   2. GitHub poll of your open PRs, diffed against the previous snapshot:
#        baseline          first run: the PRs that were already open
#        pr-opened         a PR appeared
#        new-sha           a PR's head commit changed
#        pr-closed         a PR is no longer open (merged or closed)
#        threads-resolved  unresolved pr-review threads dropped to 0 without a push
#
# The snapshot is shell-side bookkeeping only; the model never reads it.
set -u

home="${PR_REVIEW_HOME:-$HOME/.claude/pr-review}"
inbox="$home/inbox"
snap="$home/snapshot.json"
poll_every="${PR_REVIEW_POLL_SECONDS:-90}"
mkdir -p "$inbox"

query='query($q: String!) {
  search(query: $q, type: ISSUE, first: 50) {
    nodes { ... on PullRequest {
      url number headRefName headRefOid isDraft
      repository { nameWithOwner }
      reviewThreads(first: 100) { nodes { isResolved comments(first: 1) { nodes { body } } } }
    } }
  }
}'

poll() {
  gh api graphql -f query="$query" -f q='is:pr is:open author:@me archived:false' 2>/dev/null |
    jq -c '[.data.search.nodes[] | select(.url != null) | {
      url, number, repo: .repository.nameWithOwner, branch: .headRefName,
      head_sha: .headRefOid, draft: .isDraft,
      open_threads: ([.reviewThreads.nodes[]
        | select(.isResolved == false)
        | select(.comments.nodes[0].body // "" | contains("<!-- pr-review"))] | length)
    }]'
}

drain_inbox() {
  found=1
  for f in "$inbox"/*.json; do
    [ -e "$f" ] || break
    jq -c '.' "$f" 2>/dev/null && found=0
    rm -f "$f"
  done
  return $found
}

diff_snapshot() {
  # $1 = previous snapshot, $2 = current snapshot; prints events, returns 0 if any.
  jq -nc --argjson old "$1" --argjson new "$2" '
    ($old | map({(.url): .}) | add // {}) as $o
    | ($new | map({(.url): .}) | add // {}) as $n
    | ( $new[] | . as $p | $o[$p.url] as $q
        | if $q == null then {type: "pr-opened"} + $p
          elif $q.head_sha != $p.head_sha then {type: "new-sha", previous_sha: $q.head_sha} + $p
          elif $q.open_threads > 0 and $p.open_threads == 0 then {type: "threads-resolved"} + $p
          else empty end ),
      ( $old[] | select($n[.url] == null) | {type: "pr-closed"} + . )
  ' | grep .
}

last_poll=0
while :; do
  had_events=1
  drain_inbox && had_events=0

  now=$(date +%s)
  if [ $((now - last_poll)) -ge "$poll_every" ]; then
    last_poll=$now
    current=$(poll)
    if [ -n "$current" ]; then
      if [ ! -s "$snap" ]; then
        jq -c '{type: "baseline", prs: .}' <<<"$current"
        had_events=0
      elif diff_snapshot "$(cat "$snap")" "$current"; then
        had_events=0
      fi
      printf '%s\n' "$current" > "$snap"
    fi
  fi

  [ "$had_events" -eq 0 ] && exit 0
  sleep 5
done
