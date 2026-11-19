#!/usr/bin/env bash
# Shared by ctl.sh and prr.sh. Sourced, never executed.

home="${PR_REVIEW_HOME:-$HOME/.claude/pr-review}"
MARK='<!-- pr-review'

die() { echo "pr-review: $*" >&2; exit 1; }
lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# parse_pr <pr_url> -> url, owner, repo, owner_repo, number, key (state file name), name (worktree name)
parse_pr() {
  case "$1" in
    https://github.com/*/*/pull/[0-9]*) ;;
    *) die "not a GitHub pull request URL: $1" ;;
  esac
  owner_repo=$(printf '%s' "$1" | sed -E 's#^https://github.com/([^/]+/[^/]+)/pull/.*#\1#')
  number=$(printf '%s' "$1" | sed -E 's#^https://github.com/[^/]+/[^/]+/pull/([0-9]+).*#\1#')
  owner="${owner_repo%%/*}"
  repo="${owner_repo#*/}"
  url="https://github.com/$owner_repo/pull/$number"
  key=$(printf '%s__%s__%s' "$owner" "$repo" "$number" | tr -c 'A-Za-z0-9_.-' '-')
  name=$(printf 'pr-review-%s-%s' "$(printf '%s' "$repo" | tr -c 'A-Za-z0-9-' '-')" "$number")
}

# footer <sha> <round> [clean]: signs everything the plugin posts. The marker is how the
# plugin finds its own threads again, and how it recovers the last reviewed commit and
# round when its local state is gone.
footer() {
  printf '\n\n— 🤖 reviewed by pr-review plugin\n<!-- pr-review sha=%s round=%s%s -->' "$1" "$2" "${3:+ $3}"
}

PR_QUERY='query($owner: String!, $name: String!, $number: Int!) {
  viewer { login }
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      state isDraft title body baseRefName headRefName headRefOid
      author { login }
      comments(last: 40) { nodes { body author { login } } }
      reviewThreads(first: 100) { nodes {
        id isResolved isOutdated path line originalLine
        comments(first: 60) { nodes { body author { login } } }
      } }
    }
  }
}'

# pr_fetch: prints one normalized JSON object for the PR ($owner, $repo, $number).
#   threads  only the plugin's own threads: opened by you (the gh user) and signed with
#            the marker. Comments from anyone but you are dropped and only counted, so
#            text written by other people never reaches the reviewer.
#   marker   {sha, round} of the newest signed comment
#   clean    commits that already carry a "no open findings" comment
pr_fetch() {
  local raw
  raw=$(gh api graphql -f query="$PR_QUERY" -f owner="$owner" -f name="$repo" -F number="$number" 2>/dev/null) || return 1
  printf '%s' "$raw" | jq -e --arg mark "$MARK" '
    def strip: sub("\\s*— 🤖 reviewed by pr-review plugin\\s*<!-- pr-review[^>]*-->\\s*$"; "");
    .data.viewer.login as $me
    | .data.repository.pullRequest as $p
    | if $p == null then error("no such pull request") else . end
    | ($p.author.login // "") as $author
    | [ $p.comments.nodes[] | select((.author.login // "") == $me and (.body | contains($mark))) | .body ] as $notes
    | [ $p.reviewThreads.nodes[]
        | select((.comments.nodes[0].author.login // "") == $me
                 and ((.comments.nodes[0].body // "") | contains($mark)))
        | { id, resolved: .isResolved, outdated: .isOutdated, path, line: (.line // .originalLine),
            hidden: ([ .comments.nodes[] | select((.author.login // "") != $me) ] | length),
            comments: [ .comments.nodes[] | select((.author.login // "") == $me)
                        | { who: (if (.body | contains($mark)) then "reviewer" else "author" end),
                            body: (.body | strip) } ] }
        | .awaiting = ((.resolved | not) and (.comments[-1].who == "author")) ] as $threads
    | [ ($notes[]), ($p.reviewThreads.nodes[] | .comments.nodes[] | select((.author.login // "") == $me) | .body)
        | capture("<!-- pr-review sha=(?<sha>[0-9a-f]+) round=(?<round>[0-9]+)")
        | .round |= tonumber ] as $marks
    | { viewer: $me, author: $author, state: $p.state, draft: $p.isDraft,
        title: $p.title, body: ($p.body // ""),
        base: $p.baseRefName, branch: $p.headRefName, head: $p.headRefOid,
        marker: ($marks | max_by(.round)),
        clean: [ $notes[] | select(test("<!-- pr-review sha=[0-9a-f]+ round=[0-9]+ clean"))
                 | capture("sha=(?<sha>[0-9a-f]+)").sha ],
        threads: $threads }'
}
