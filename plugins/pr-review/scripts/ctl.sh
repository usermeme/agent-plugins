#!/usr/bin/env bash
# Control helper for the pr-review listener. Deterministic plumbing only.
#
#   ctl.sh session-name <session_id>          -> name of a live session, or nothing
#   ctl.sh find-repo <owner/name>             -> path of a local checkout, or nothing
#   ctl.sh launch-dir <path>                  -> the checkout to put reviewer worktrees in
#   ctl.sh run <pr_url> <launch_dir> <origin_name|-> [<reviewer_session_id> <message>]
#        one headless review round; prints {"session_id", "head_sha", "result"} as JSON
#        (env: PR_REVIEW_MAX_ROUNDS, default 10, 0 = no cap)
#   ctl.sh stop <pr_url> <launch_dir>         -> remove the PR's reviewer worktree
#   ctl.sh sweep                              -> remove worktrees of PRs that are no longer open
#
# The reviewer is headless (`claude -p`), one run per round, resumed with `--resume` so it
# keeps its memory. Nothing runs between rounds. It works in a detached `git worktree` of
# the local checkout at <launch_dir>/.claude/worktrees/<name>, so nothing is cloned or
# downloaded and no temporary branch is created. Headless mode doesn't need folder trust.
set -euo pipefail

sessions() { claude agents --json 2>/dev/null || echo '[]'; }

reviewer_name() {
  local repo="${1##*/}"
  printf 'pr-review-%s-%s' "$(printf '%s' "$repo" | tr -c 'A-Za-z0-9-' '-')" "$2"
}

# parse_pr <pr_url> -> sets owner_repo, number, name
parse_pr() {
  owner_repo=$(printf '%s' "$1" | sed -E 's#https://github.com/([^/]+/[^/]+)/pull/.*#\1#')
  number=$(printf '%s' "$1" | sed -E 's#.*/pull/([0-9]+).*#\1#')
  name=$(reviewer_name "$owner_repo" "$number")
}

is_temp() { case "$1" in /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) return 0 ;; esac; return 1; }

# launch_dir <path>: that path's checkout, unless it lives in a temp folder (a session's
# scratchpad worktree gets cleaned up); then another non-temp checkout of the same repo.
launch_dir() {
  local top
  top=$(git -C "$1" rev-parse --show-toplevel)
  if ! is_temp "$top"; then echo "$top"; return; fi
  git -C "$top" worktree list --porcelain | sed -n 's/^worktree //p' | while read -r wt; do
    [ -e "$wt/.git" ] || continue          # skip the bare entry
    is_temp "$wt" || { echo "$wt"; break; }
  done
}

# Keep reviewer worktrees out of `git status`, so an authoring session's `git add -A`
# can't commit one as an embedded repo. info/exclude is local and never committed.
exclude_worktrees() {
  local ex
  ex="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
  mkdir -p "$(dirname "$ex")"
  grep -qxF '.claude/worktrees/' "$ex" 2>/dev/null || echo '.claude/worktrees/' >> "$ex"
}

# prepare <launch_dir>: put the reviewer worktree at the PR's current head; prints the SHA.
# The commit is normally already local (the author pushed from this machine); otherwise
# fetch just the PR head.
prepare() {
  local dir="$1" wt sha
  wt="$dir/.claude/worktrees/$name"
  sha=$(gh pr view "https://github.com/$owner_repo/pull/$number" --json headRefOid -q .headRefOid)
  git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null ||
    git -C "$dir" fetch --quiet origin "pull/$number/head"
  exclude_worktrees "$dir"
  if [ -e "$wt/.git" ]; then
    git -C "$wt" checkout --quiet --detach "$sha"
  else
    mkdir -p "$(dirname "$wt")"
    git -C "$dir" worktree add --quiet --detach "$wt" "$sha"
  fi
  echo "$sha"
}

case "${1:-}" in
  session-name)
    sessions | jq -r --arg id "$2" '.[] | select(.sessionId == $id) | .name' | head -1 ;;

  launch-dir)
    launch_dir "$2" ;;

  find-repo)
    # Search roots: PR_REVIEW_SEARCH_ROOTS (colon-separated), default ~/git.
    want=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
    IFS=':' read -r -a roots <<<"${PR_REVIEW_SEARCH_ROOTS:-$HOME/git}"
    for root in "${roots[@]}"; do
      find "$root" -maxdepth 5 -name .git -prune -print 2>/dev/null | while read -r g; do
        dir=$(dirname "$g")
        case "$dir" in */.claude/worktrees/*) continue ;; esac
        url=$(git -C "$dir" remote get-url origin 2>/dev/null | tr 'A-Z' 'a-z') || continue
        case "$url" in
          *"github.com:$want.git"|*"github.com:$want"|*"github.com/$want.git"|*"github.com/$want")
            echo "$dir"; exit 0 ;;
        esac
      done
    done | head -1 ;;

  run)
    pr_url="$2"; dir="$3"; origin="$4"; resume_id="${5:-}"; message="${6:-}"
    parse_pr "$pr_url"
    sha=$(prepare "$dir")
    wt="$dir/.claude/worktrees/$name"

    if [ -n "$resume_id" ]; then
      prompt="$message"; resume=(--resume "$resume_id")
    else
      max_rounds="${PR_REVIEW_MAX_ROUNDS:-10}"
      prompt="/pr-review:review pr=$pr_url origin=$origin max_rounds=$max_rounds"; resume=()
    fi

    # PR_REVIEW_PLUGIN_DIR: load the plugin from a checkout instead of the installed copy.
    plugin_args=()
    [ -n "${PR_REVIEW_PLUGIN_DIR:-}" ] && plugin_args=(--plugin-dir "$PR_REVIEW_PLUGIN_DIR")

    # dontAsk: anything outside this list is denied instead of waiting for a prompt that
    # nobody can answer. The reviewer only reads code and talks to GitHub.
    cd "$wt"
    claude -p --output-format json --permission-mode dontAsk \
      ${resume[@]+"${resume[@]}"} ${plugin_args[@]+"${plugin_args[@]}"} \
      --allowedTools "Read" "Glob" "Grep" "Agent" "Skill" \
        "Bash(gh pr view *)" "Bash(gh pr diff *)" "Bash(gh api *)" "Bash(jq *)" \
        "Bash(git diff *)" "Bash(git log *)" "Bash(git show *)" "Bash(git rev-parse *)" \
        "Bash(git status*)" \
      -- "$prompt" |
      jq -c --arg sha "$sha" '{session_id, head_sha: $sha, is_error, result}' ;;

  stop)
    parse_pr "$2"; dir="$3"
    wt="$dir/.claude/worktrees/$name"
    # Detached and read-only: the reviewer never commits, so nothing can be lost here.
    [ -e "$wt" ] && git -C "$dir" worktree remove --force "$wt"
    rmdir "$dir/.claude/worktrees" "$dir/.claude" 2>/dev/null || true
    echo "stopped $name" ;;

  sweep)
    IFS=':' read -r -a roots <<<"${PR_REVIEW_SEARCH_ROOTS:-$HOME/git}"
    for root in "${roots[@]}"; do
      find "$root" -maxdepth 6 -type d -path '*/.claude/worktrees/pr-review-*' -prune -print 2>/dev/null
    done | while read -r wt; do
      dir="${wt%/.claude/worktrees/*}"
      url=$(git -C "$dir" remote get-url origin 2>/dev/null | sed -E 's#^git@github.com:#https://github.com/#; s#\.git$##')
      n="${wt##*-}"
      state=$(gh pr view "$url/pull/$n" --json state -q .state 2>/dev/null || echo UNKNOWN)
      if [ "$state" = "MERGED" ] || [ "$state" = "CLOSED" ]; then
        git -C "$dir" worktree remove --force "$wt" && echo "swept $wt ($state)"
      fi
    done ;;

  *)
    sed -n '2,14p' "$0"; exit 2 ;;
esac
