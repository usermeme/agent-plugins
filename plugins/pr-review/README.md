# pr-review

Automatic review loop for every open GitHub PR you authored.

1. **Detect.** A shell watcher polls your open PRs (one GraphQL query every 90 s). A
   `PostToolUse` hook in every Claude session records which session ran `gh pr create`
   or `git push`.
2. **Review.** For each new PR or new commit, a headless reviewer (`claude -p`) runs in a
   detached git worktree of your local checkout, at the PR head. It loads that repo's
   `CLAUDE.md`, `AGENTS.md` and skills, and uses your `code-review` skill if you have one.
3. **Comment.** Findings are posted on the PR, signed `— 🤖 reviewed by pr-review plugin`.
4. **Fix.** The session that opened the PR gets the findings, fixes them, and pushes with a
   `PR-Review-Round: <n>` trailer on each fix commit.
5. **Repeat.** Each push resumes the same reviewer conversation (`--resume`). It resolves
   fixed threads and looks for new problems, until one of these happens:

| Stop | When |
|---|---|
| ✅ Finished | No open threads and no new findings |
| ⏸ Stalled | Two rounds in a row resolve nothing |
| 🛑 Round cap | `PR_REVIEW_MAX_ROUNDS` automatic rounds (default 10) |
| Merged / closed | The PR is no longer open |

A push without the trailer is treated as yours and resets the counters.

## Install

```bash
claude plugin install pr-review --marketplace usermeme/claude-plugins
```

This adds the `usermeme` marketplace if needed. Restart running sessions so the hook
loads in them.

## Use

Start the listener in any Claude Code session. Keep that session open, in tmux, the
desktop app or a plain terminal:

```
/pr-review:listen
```

On its first start it lists the PRs that are already open and asks whether to review them.

## Requirements

- `gh` (logged in), `git`, `jq`
- A local checkout of each PR's repo under `~/git`. Set `PR_REVIEW_SEARCH_ROOTS` for other
  locations. Nothing is cloned or downloaded.
- The listener and the sessions that open PRs must share a permission mode, or messages
  between them wait for your approval.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `PR_REVIEW_MAX_ROUNDS` | `10` | Backstop on automatic rounds; `0` = no cap |
| `PR_REVIEW_POLL_SECONDS` | `90` | GitHub poll interval |
| `PR_REVIEW_SEARCH_ROOTS` | `~/git` | Colon-separated folders searched for local checkouts |
| `PR_REVIEW_HOME` | `~/.claude/pr-review` | Hook inbox and poll state |
| `PR_REVIEW_PLUGIN_DIR` | (unset) | Run reviewers with this plugin checkout (development) |

## Footprint

- Reviewer worktrees: `<repo>/.claude/worktrees/pr-review-<repo>-<n>`. They're detached, use
  no branch, and are hidden from `git status` through `.git/info/exclude`. Each one is
  removed when its review ends, and the listener sweeps leftovers on start.
- Nothing runs between rounds. There's no idle reviewer process.

## Security

- Headless runs skip Claude Code's folder-trust prompt, so a repo's `.claude/settings.json`
  hooks and MCP servers load without asking. That's acceptable here because every PR
  reviewed is your own (`author:@me`).
- Reviewers use `--permission-mode dontAsk` with a read-only allowlist (Read, Grep, `gh`,
  read-only `git`). They never edit, commit or push.
- PR text and reviewer output are handled as data, never as instructions.
- Comments are posted as your GitHub account, using the `COMMENT` review type (GitHub
  doesn't allow approving or requesting changes on your own PR).
