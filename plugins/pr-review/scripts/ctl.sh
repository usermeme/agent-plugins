#!/usr/bin/env bash
# Control helper for the pr-review listener. Deterministic plumbing only.
#
#   ctl.sh session-name <session_id>       -> name of a live session, or nothing
#   ctl.sh session-alive <name>            -> exit 0 if a session with that name is live
#   ctl.sh find-repo <owner/name>          -> path of a local clone, or nothing
#   ctl.sh reviewer-name <owner/name> <n>  -> reviewer session name for a PR
#   ctl.sh spawn <pr_url> <repo_path> <listener_name> <origin_name|-> <permission_mode>
#                                         (env: PR_REVIEW_MAX_ROUNDS, default 10, 0 = no cap)
#   ctl.sh stop <owner/name> <n> <repo_path>
set -euo pipefail

sessions() { claude agents --json 2>/dev/null || echo '[]'; }

reviewer_name() {
  local repo="${1##*/}"
  printf 'pr-review-%s-%s' "$(printf '%s' "$repo" | tr -c 'A-Za-z0-9-' '-')" "$2"
}

# All reviewer worktrees live under one folder that the user trusts once in Claude Code
# (trust is inherited by subfolders); a worktree inside an untrusted repo can't host a
# background session.
worktrees_root="${PR_REVIEW_WORKTREES:-$HOME/.pr-review-worktrees}"
# worktree_path <owner/name> <n>
worktree_path() { printf '%s/%s' "$worktrees_root" "$(reviewer_name "$1" "$2")"; }

case "${1:-}" in
  session-name)
    sessions | jq -r --arg id "$2" '.[] | select(.sessionId == $id) | .name' | head -1 ;;

  session-alive)
    sessions | jq -e --arg n "$2" 'any(.[]; .name == $n)' >/dev/null ;;

  reviewer-name)
    reviewer_name "$2" "$3" ;;

  find-repo)
    # Search roots: PR_REVIEW_SEARCH_ROOTS (colon-separated), default ~/git.
    want=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
    IFS=':' read -r -a roots <<<"${PR_REVIEW_SEARCH_ROOTS:-$HOME/git}"
    for root in "${roots[@]}"; do
      find "$root" -maxdepth 5 -name .git -prune -print 2>/dev/null | while read -r g; do
        dir=$(dirname "$g")
        url=$(git -C "$dir" remote get-url origin 2>/dev/null | tr 'A-Z' 'a-z') || continue
        case "$url" in
          *"github.com:$want.git"|*"github.com:$want"|*"github.com/$want.git"|*"github.com/$want")
            echo "$dir"; exit 0 ;;
        esac
      done
    done | head -1 ;;

  spawn)
    pr_url="$2"; repo_path="$3"; listener="$4"; origin="$5"; mode="$6"
    number=$(gh pr view "$pr_url" --json number -q .number)
    owner_repo=$(printf '%s' "$pr_url" | sed -E 's#https://github.com/([^/]+/[^/]+)/pull/.*#\1#')
    name=$(reviewer_name "$owner_repo" "$number")
    wt=$(worktree_path "$owner_repo" "$number")
    mkdir -p "$worktrees_root"

    # Detached checkout of the PR head: works for forks, and the branch can stay
    # checked out in the author's working copy.
    git -C "$repo_path" fetch --quiet origin "pull/$number/head"
    if [ -d "$wt" ]; then
      git -C "$wt" checkout --quiet --detach FETCH_HEAD
    else
      git -C "$repo_path" worktree add --quiet --detach "$wt" FETCH_HEAD
    fi

    # Backstop on automatic rounds; 0 = no cap (no-progress detection still applies).
    max_rounds="${PR_REVIEW_MAX_ROUNDS:-10}"
    prompt="/pr-review:review pr=$pr_url listener=$listener origin=$origin max_rounds=$max_rounds"
    # PR_REVIEW_PLUGIN_DIR: load the plugin from a checkout instead of the installed
    # copy (development and testing).
    plugin_args=()
    [ -n "${PR_REVIEW_PLUGIN_DIR:-}" ] && plugin_args=(--plugin-dir "$PR_REVIEW_PLUGIN_DIR")
    cd "$wt"
    claude --bg -n "$name" --permission-mode "$mode" ${plugin_args[@]+"${plugin_args[@]}"} \
      --allowedTools "Read" "Glob" "Grep" "Agent" "Skill" "ListAgents" "SendMessage" \
        "Bash(gh pr view *)" "Bash(gh pr diff *)" "Bash(gh api *)" \
        "Bash(git fetch *)" "Bash(git checkout --detach *)" "Bash(git diff *)" \
        "Bash(git log *)" "Bash(git show *)" "Bash(git rev-parse *)" "Bash(git status*)" \
        "Bash(jq *)" \
      -- "$prompt" | head -1
    echo "name=$name worktree=$wt" ;;

  stop)
    owner_repo="$2"; number="$3"; repo_path="$4"
    name=$(reviewer_name "$owner_repo" "$number")
    if sessions | jq -e --arg n "$name" 'any(.[]; .name == $n)' >/dev/null; then
      claude stop "$name" >/dev/null 2>&1 || true
      claude rm "$name" >/dev/null 2>&1 || true
    fi
    wt=$(worktree_path "$owner_repo" "$number")
    [ -d "$wt" ] && git -C "$repo_path" worktree remove --force "$wt"
    echo "stopped $name" ;;

  *)
    sed -n '2,10p' "$0"; exit 2 ;;
esac
