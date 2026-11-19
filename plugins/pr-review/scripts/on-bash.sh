#!/usr/bin/env bash
# PostToolUse(Bash) hook, active in every session that has the plugin.
# When a session runs `gh pr create` or `git push`, drop one event file into the
# pr-review inbox so the listener knows which session authored the PR.
# Contract: never block or fail the session -> no network calls, always exit 0.
set -u

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0

case "$cmd" in
  *"gh pr create"*) kind="pr-create" ;;
  *"git push"*)     kind="push" ;;
  *)                exit 0 ;;
esac

inbox="${PR_REVIEW_HOME:-$HOME/.claude/pr-review}/inbox"
mkdir -p "$inbox" 2>/dev/null || exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
# tool_response shape varies; search every string in it for a PR URL.
output=$(printf '%s' "$input" | jq -r '[.tool_response | .. | strings] | join("\n")' 2>/dev/null)
pr_url=$(printf '%s' "$output" | grep -oE 'https://github\.com/[^/[:space:]]+/[^/[:space:]]+/pull/[0-9]+' | tail -1)

repo_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
branch=$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null)
head_sha=$(git -C "$cwd" rev-parse --verify -q HEAD 2>/dev/null)

event="$inbox/$(date +%s)-$$-$RANDOM.json"
jq -n \
  --arg kind "$kind" --arg session_id "$session_id" --arg cwd "$cwd" \
  --arg repo_root "$repo_root" --arg branch "$branch" --arg head_sha "$head_sha" \
  --arg pr_url "$pr_url" --arg at "$(date -u +%FT%TZ)" \
  '{type: $kind, session_id: $session_id, cwd: $cwd, repo_root: $repo_root,
    branch: $branch, head_sha: $head_sha, pr_url: $pr_url, at: $at}' \
  > "$event.tmp" 2>/dev/null && mv "$event.tmp" "$event"

exit 0
