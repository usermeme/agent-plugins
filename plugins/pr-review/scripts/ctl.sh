#!/usr/bin/env bash
# Control helper for the pr-review listener. Deterministic plumbing only.
#
#   ctl.sh session-name <session_id>       -> name of a live session, or nothing
#   ctl.sh session-alive <name>            -> exit 0 if a session with that name is live
#   ctl.sh reviewer-name <owner/name> <n>  -> reviewer session name for a PR
#   ctl.sh spawn <pr_url> <listener_name> <origin_name|-> <permission_mode>
#                                          (env: PR_REVIEW_MAX_ROUNDS, default 10, 0 = no cap)
#   ctl.sh refresh <pr_url>                -> re-snapshot the reviewer folder at the PR head
#   ctl.sh stop <pr_url>
#
# Reviewers work in a plain snapshot of the PR head (no .git) under one folder the user
# trusts once in Claude Code. Trust is inherited by plain subfolders but not by git
# worktrees or clones (each is its own project), and a background session refuses an
# untrusted folder. A snapshot also needs no local clone of the repo.
set -euo pipefail

root="${PR_REVIEW_WORKTREES:-$HOME/.pr-review-worktrees}"

sessions() { claude agents --json 2>/dev/null || echo '[]'; }

reviewer_name() {
  local repo="${1##*/}"
  printf 'pr-review-%s-%s' "$(printf '%s' "$repo" | tr -c 'A-Za-z0-9-' '-')" "$2"
}

# parse_pr <pr_url> -> sets owner_repo, number, name, dir
parse_pr() {
  owner_repo=$(printf '%s' "$1" | sed -E 's#https://github.com/([^/]+/[^/]+)/pull/.*#\1#')
  number=$(printf '%s' "$1" | sed -E 's#.*/pull/([0-9]+).*#\1#')
  name=$(reviewer_name "$owner_repo" "$number")
  dir="$root/$name"
}

# snapshot -> replace the contents of $dir with the files at the PR's current head.
# The directory itself is kept, so a reviewer whose cwd is inside it is unaffected.
snapshot() {
  local sha tmp
  sha=$(gh pr view "https://github.com/$owner_repo/pull/$number" --json headRefOid -q .headRefOid)
  tmp=$(mktemp -d)
  gh api "repos/$owner_repo/tarball/$sha" > "$tmp/src.tgz"
  mkdir -p "$dir"
  find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  tar -xzf "$tmp/src.tgz" --strip-components=1 -C "$dir"
  rm -rf "$tmp"
  echo "$sha"
}

case "${1:-}" in
  session-name)
    sessions | jq -r --arg id "$2" '.[] | select(.sessionId == $id) | .name' | head -1 ;;

  session-alive)
    sessions | jq -e --arg n "$2" 'any(.[]; .name == $n)' >/dev/null ;;

  reviewer-name)
    reviewer_name "$2" "$3" ;;

  spawn)
    pr_url="$2"; listener="$3"; origin="$4"; mode="$5"
    parse_pr "$pr_url"
    sha=$(snapshot)

    # Backstop on automatic rounds; 0 = no cap (no-progress detection still applies).
    max_rounds="${PR_REVIEW_MAX_ROUNDS:-10}"
    prompt="/pr-review:review pr=$pr_url listener=$listener origin=$origin max_rounds=$max_rounds"

    # PR_REVIEW_PLUGIN_DIR: load the plugin from a checkout instead of the installed
    # copy (development and testing).
    plugin_args=()
    [ -n "${PR_REVIEW_PLUGIN_DIR:-}" ] && plugin_args=(--plugin-dir "$PR_REVIEW_PLUGIN_DIR")

    cd "$dir"
    claude --bg -n "$name" --permission-mode "$mode" ${plugin_args[@]+"${plugin_args[@]}"} \
      --allowedTools "Read" "Glob" "Grep" "Agent" "Skill" "ListAgents" "SendMessage" \
        "Bash(gh pr view *)" "Bash(gh pr diff *)" "Bash(gh api *)" "Bash(jq *)" \
      -- "$prompt" | head -1
    echo "name=$name dir=$dir sha=$sha" ;;

  refresh)
    parse_pr "$2"
    echo "refreshed $name at $(snapshot)" ;;

  stop)
    parse_pr "$2"
    # `claude stop` / `rm` take the short id (first 8 chars of the session id), not a name.
    id=$(sessions | jq -r --arg n "$name" '.[] | select(.name == $n and .kind == "background") | .sessionId' | head -1)
    if [ -n "$id" ]; then
      claude stop "${id:0:8}" >/dev/null
      claude rm "${id:0:8}" >/dev/null
    fi
    if sessions | jq -e --arg n "$name" 'any(.[]; .name == $n)' >/dev/null; then
      echo "failed to stop $name" >&2; exit 1
    fi
    rm -rf "$dir"
    echo "stopped $name" ;;

  *)
    sed -n '2,10p' "$0"; exit 2 ;;
esac
