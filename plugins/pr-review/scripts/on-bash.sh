#!/usr/bin/env bash
# PostToolUse(Bash) hook, active in every Claude Code session that has the plugin.
# When a session runs `git push` or `gh pr create`, it appends one line to the push log:
# which session, which checkout, which branch and which commit.
#
# The log answers two questions for ctl.sh: which session should hear about review
# comments on a PR, and was this commit pushed by a session or by hand. It never starts a
# review; only GitHub's own state does that. So a wrong or stale line can't cause a round.
#
# Contract: never block or fail the session. No network calls, always exit 0.
set -u
here=$(cd "$(dirname "$0")" && pwd)
input=$(cat)

parsed=$(printf '%s' "$input" | jq -c -f "$here/hook-parse.jq" 2>/dev/null) || exit 0
[ -n "$parsed" ] || exit 0

field() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }
cwd=$(field "$input" '.cwd // ""')
session_id=$(field "$input" '.session_id // ""')
kind=$(field "$parsed" .type)
cd_to=$(field "$parsed" .cd)
git_c=$(field "$parsed" .git_c)

# Where the command really ran: the session's folder, then `cd <dir>`, then `git -C <dir>`.
# A session often pushes to a repo it was not started in.
resolve() {
  case "$2" in
    "")    printf '%s' "$1" ;;
    "~")   printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "$HOME/${2#\~/}" ;;
    /*)    printf '%s' "$2" ;;
    *)     printf '%s' "$1/$2" ;;
  esac
}
case "$cd_to$git_c" in *'$'*|*'`'*) cd_to=""; git_c="" ;; esac   # can't expand variables here
dir=$(resolve "$(resolve "$cwd" "$cd_to")" "$git_c")
[ -d "$dir" ] || dir="$cwd"

# The reviewer's own worktree is never the author of anything.
case "$cwd/ $dir/" in *"/.claude/worktrees/pr-review-"*) exit 0 ;; esac

pr_url=""
if [ "$kind" = pr-create ]; then
  # tool_response's shape varies; search every string in it for the PR URL gh printed.
  pr_url=$(field "$input" '[.tool_response | .. | strings] | join("\n")' |
           grep -oE 'https://github\.com/[^/[:space:]]+/[^/[:space:]]+/pull/[0-9]+' | tail -1)
fi

top=""; branch=""; head_sha=""; repos="[]"
if [ -n "$dir" ] && top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null); then
  branch=$(git -C "$top" symbolic-ref --short -q HEAD 2>/dev/null)
  head_sha=$(git -C "$top" rev-parse --verify -q HEAD 2>/dev/null)
  # Every remote, as owner/repo: with a fork, the PR's repo is not `origin`.
  repos=$(git -C "$top" remote -v 2>/dev/null | awk '{print $2}' | sort -u | tr 'A-Z' 'a-z' |
          sed -E 's#\.git$##; s#/$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#' | jq -R . 2>/dev/null | jq -cs 'unique' 2>/dev/null)
else
  top=""
fi
[ -n "$top" ] || [ -n "$pr_url" ] || exit 0

home="${PR_REVIEW_HOME:-$HOME/.claude/pr-review}"
mkdir -p "$home" 2>/dev/null || exit 0
line=$(jq -nc --arg type "$kind" --arg session_id "$session_id" --arg dir "$top" \
  --argjson repos "${repos:-[]}" --arg branch "$branch" --arg head_sha "$head_sha" \
  --arg pr_url "$pr_url" --argjson at "$(date +%s)" \
  '{type: $type, session_id: $session_id, dir: $dir, repos: $repos, branch: $branch,
    head_sha: $head_sha, pr_url: $pr_url, at: $at}' 2>/dev/null) || exit 0
# One short line per append, so concurrent hooks can't interleave.
printf '%s\n' "$line" >> "$home/pushes.jsonl"
exit 0
