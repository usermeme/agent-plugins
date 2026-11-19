#!/usr/bin/env bash
# The only command the headless reviewer may run, and only in the exact forms below (the
# permission rules in ctl.sh list them one by one, so no extra argument, pipe or redirect
# gets through).
#
#   prr.sh context          the PR, the round, the mode, and the reviewer's own threads
#   prr.sh diff             the whole PR diff
#   prr.sh diff --since     only what changed since the last reviewed commit
#   prr.sh diff --names     the changed files
#   prr.sh log              the PR's commits
#   prr.sh log --since      only the commits since the last reviewed one
#   prr.sh submit           carry out .pr-review/actions.json and end the run
#
# It is pinned to one PR by a context file that ctl.sh writes into the worktree's private
# git dir, which the reviewer cannot write. Nothing the reviewer passes or writes can point
# it at another PR, another repo or a local file.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

[ $# -ge 1 ] && [ $# -le 2 ] || { sed -n '2,12p' "$0" >&2; exit 2; }
top=$(git rev-parse --show-toplevel 2>/dev/null) || die "run this from the reviewer worktree"
gitdir=$(git rev-parse --absolute-git-dir)
ctx="$gitdir/pr-review-context.json"
[ -f "$ctx" ] || die "this folder is not a pr-review worktree"

c() { jq -r "$1" "$ctx"; }
parse_pr "$(c .url)"
head=$(c .head); previous=$(c '.previous // ""'); round=$(c .round); run_id=$(c .id)

tmp=$(mktemp -d "${TMPDIR:-/tmp}/pr-review.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# since_ok: is the last reviewed commit an ancestor of HEAD (no force-push in between)?
since_ok() {
  [ -n "$previous" ] && git cat-file -e "$previous^{commit}" 2>/dev/null &&
    git merge-base --is-ancestor "$previous" HEAD 2>/dev/null
}

full_diff() { gh pr diff "$number" -R "$owner_repo"; }

case "${1:-} ${2:-}" in
  "context ")
    pr_fetch > "$tmp/pr.json" || die "could not read the PR from GitHub"
    jq --slurpfile c "$ctx" '
      def cut(n): if length > n then .[0:n] + " …[cut]" else . end;
      { repo: $c[0].repo, number: $c[0].number, title, description: (.body | cut(6000)),
        base, branch, head: $c[0].head, previous: $c[0].previous,
        round: $c[0].round, mode: $c[0].mode,
        threads_open: [ .threads[] | select(.resolved | not)
          | { id, path, line, outdated, awaiting_your_answer: .awaiting,
              comments: [ .comments[] | .body |= cut(4000) ],
              hidden_comments_from_other_people: .hidden } ],
        threads_resolved: [ .threads[] | select(.resolved)
          | { path, line, was: (.comments[0].body | split("\n")[0] | cut(200)) } ] }' "$tmp/pr.json" ;;

  "diff ")
    full_diff ;;

  "diff --since")
    if since_ok; then
      git diff "$previous" HEAD
    else
      echo "note: the last reviewed commit is not part of this branch any more (force-push or rebase)."
      echo "note: showing the whole PR diff instead."
      full_diff
    fi ;;

  "diff --names")
    gh pr diff "$number" -R "$owner_repo" --name-only ;;

  "log ")
    gh api "repos/$owner_repo/pulls/$number/commits" --paginate \
      --jq '.[] | "\(.sha[0:7]) \(.commit.message | split("\n")[0])"' ;;

  "log --since")
    if since_ok; then
      git log --format='%h %s' "$previous..HEAD"
    else
      echo "note: the last reviewed commit is not part of this branch any more; showing every commit."
      gh api "repos/$owner_repo/pulls/$number/commits" --paginate \
        --jq '.[] | "\(.sha[0:7]) \(.commit.message | split("\n")[0])"'
    fi ;;

  "submit ")
    act="$top/.pr-review/actions.json"
    [ ! -L "$top/.pr-review" ] && [ ! -L "$act" ] || die ".pr-review must be a plain folder"
    [ -f "$act" ] || die "write .pr-review/actions.json first"
    result="$gitdir/pr-review-result.json"
    progress="$gitdir/pr-review-progress.json"
    if [ "$(jq -r '.id // ""' "$result" 2>/dev/null)" = "$run_id" ]; then
      echo "already submitted for this run; nothing more to do."; exit 0
    fi
    [ "$(jq -r '.id // ""' "$progress" 2>/dev/null)" = "$run_id" ] ||
      jq -n --arg id "$run_id" '{id: $id, review_posted: false, threads_done: []}' > "$progress"

    # 1. Shape of the file.
    jq -e 'type == "object"' "$act" >/dev/null 2>&1 ||
      die "actions.json is not a JSON object: $(jq . "$act" 2>&1 | head -1)"
    problems=$(jq -r '
      [ (if (.summary | type) != "string" or (.summary | length) == 0
           then "summary: required, a non-empty string" else empty end),
        ((.comments // []) | if type != "array" then "comments: must be an array" else
           (if length > 40 then "comments: at most 40 per round" else empty end),
           (to_entries[] | .key as $i | .value
            | (if type != "object" then "comments[\($i)]: must be an object" else
                (if (.path | type) != "string" then "comments[\($i)].path: required, a string" else empty end),
                (if (.line | type) != "number" then "comments[\($i)].line: required, a number" else empty end),
                (if .start_line != null and ((.start_line | type) != "number" or ((.line | type) == "number" and .start_line > .line))
                   then "comments[\($i)].start_line: a number no greater than line" else empty end),
                (if (.body | type) != "string" or (.body | length) == 0
                   then "comments[\($i)].body: required, a non-empty string" else empty end)
               end)) end),
        ((.threads // []) | if type != "array" then "threads: must be an array" else
           (to_entries[] | .key as $i | .value
            | (if type != "object" then "threads[\($i)]: must be an object" else
                (if (.id | type) != "string" then "threads[\($i)].id: required, a string" else empty end),
                (if .action != "resolve" and .action != "reply"
                   then "threads[\($i)].action: \"resolve\" or \"reply\"" else empty end),
                (if (.body | type) != "string" or (.body | length) == 0
                   then "threads[\($i)].body: required, a non-empty string" else empty end)
               end)) end)
      ] | .[]' "$act")
    if [ -n "$problems" ]; then echo "actions.json has problems; fix them and run submit again:"; echo "$problems"; exit 1; fi

    # 2. Threads must be the reviewer's own threads on this PR.
    pr_fetch > "$tmp/pr.json" || die "could not read the PR from GitHub"
    problems=$(jq -r --slurpfile pr "$tmp/pr.json" '
      [ $pr[0].threads[].id ] as $mine
      | (.threads // []) | to_entries[] | .key as $i | .value.id as $id
      | select($mine | index($id) | not)
      | "threads[\($i)].id: \($id) is not one of your threads on this PR (see: context)"' "$act")
    if [ -n "$problems" ]; then echo "actions.json has problems; fix them and run submit again:"; echo "$problems"; exit 1; fi

    # 3. Comments must sit on lines GitHub accepts: inside a hunk, on the new side.
    n_comments=$(jq '(.comments // []) | length' "$act")
    if [ "$n_comments" -gt 0 ] && full_diff > "$tmp/diff.txt" 2>/dev/null; then
      awk '
        /^diff --git / { hdr = 1; f = ""; next }
        hdr && /^\+\+\+ / { f = ""; if ($2 != "/dev/null") { f = substr($0, 5); sub(/^b\//, "", f); sub(/\t.*$/, "", f) } next }
        /^@@ / { hdr = 0
                 if (f != "") { split($3, a, ","); s = substr(a[1], 2) + 0; n = (a[2] == "" ? 1 : a[2] + 0)
                                if (n > 0) printf "%s\t%d\t%d\n", f, s, s + n - 1 } }
      ' "$tmp/diff.txt" |
        jq -R -s '[ split("\n")[] | select(length > 0) | split("\t") | {path: .[0], s: (.[1] | tonumber), e: (.[2] | tonumber)} ]' > "$tmp/ranges.json"
      problems=$(jq -r --slurpfile r "$tmp/ranges.json" '
        (.comments // []) | to_entries[] | .key as $i | .value as $c
        | [ $r[0][] | select(.path == $c.path) ] as $fr
        | if ($fr | length) == 0 then
            "comments[\($i)]: \($c.path) is not a changed file in this PR (see: diff --names)"
          elif ([ $fr[] | select(.s <= ($c.start_line // $c.line) and $c.line <= .e) ] | length) == 0 then
            "comments[\($i)]: \($c.path):\($c.line) is not inside a diff hunk. Lines you can comment on in that file: \([ $fr[] | "\(.s)-\(.e)" ] | join(", "))"
          else empty end' "$act")
      if [ -n "$problems" ]; then echo "actions.json has problems; fix them and run submit again:"; echo "$problems"; exit 1; fi
    fi

    # 4. Post the new findings as one review.
    if [ "$n_comments" -gt 0 ] && [ "$(jq -r .review_posted "$progress")" != true ]; then
      jq --arg sha "$head" --arg foot "$(footer "$head" "$round")" '
        { commit_id: $sha, event: "COMMENT", body: (.summary + $foot),
          comments: [ .comments[]
            | { path, line, side: "RIGHT", body: (.body + $foot) }
              + (if .start_line != null and .start_line < .line then {start_line, start_side: "RIGHT"} else {} end) ] }' "$act" > "$tmp/review.json"
      if ! gh api "repos/$owner_repo/pulls/$number/reviews" --input "$tmp/review.json" > "$tmp/review.out" 2> "$tmp/review.err"; then
        echo "GitHub refused the review; nothing was posted. Fix actions.json and run submit again:"
        jq -r '.message // empty, (.errors // [] | .[] | tostring)' "$tmp/review.out" 2>/dev/null || true
        head -3 "$tmp/review.err"
        exit 1
      fi
      jq '.review_posted = true' "$progress" > "$tmp/p.json" && mv "$tmp/p.json" "$progress"
    fi

    # 5. Decisions on existing threads. Each is recorded as it lands, so a retry after a
    #    failure does not repeat the ones already done.
    n_reply=0; n_resolve=0
    jq -c '(.threads // [])[]' "$act" > "$tmp/threads.jsonl"
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      id=$(jq -r .id <<<"$t"); action=$(jq -r .action <<<"$t")
      if jq -e --arg id "$id" '.threads_done | index($id)' "$progress" >/dev/null; then continue; fi
      body="$(jq -r .body <<<"$t")$(footer "$head" "$round")"
      gh api graphql -f query='mutation($t: ID!, $b: String!) { addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $t, body: $b}) { comment { id } } }' \
        -f t="$id" -f b="$body" >/dev/null 2> "$tmp/err" || { echo "could not reply on thread $id: $(head -1 "$tmp/err")"; exit 1; }
      n_reply=$((n_reply + 1))
      if [ "$action" = resolve ]; then
        gh api graphql -f query='mutation($t: ID!) { resolveReviewThread(input: {threadId: $t}) { thread { isResolved } } }' \
          -f t="$id" >/dev/null 2> "$tmp/err" || { echo "could not resolve thread $id: $(head -1 "$tmp/err")"; exit 1; }
        n_resolve=$((n_resolve + 1))
      fi
      jq --arg id "$id" '.threads_done += [$id]' "$progress" > "$tmp/p.json" && mv "$tmp/p.json" "$progress"
    done < "$tmp/threads.jsonl"

    # 6. Done: this file is what tells ctl.sh the run completed.
    jq --arg id "$run_id" --argjson c "$n_comments" --argjson r "$n_reply" --argjson x "$n_resolve" \
      '{id: $id, summary, comments: $c, replies: $r, resolved: $x}' "$act" > "$tmp/result.json"
    mv "$tmp/result.json" "$result"
    echo "submitted: $n_comments new comment(s), $n_reply repl(ies), $n_resolve thread(s) resolved. The run is complete." ;;

  *)
    sed -n '2,12p' "$0" >&2; exit 2 ;;
esac
