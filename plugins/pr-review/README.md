# pr-review

An automatic review loop for the GitHub PRs you open.

1. **Detect.** A shell watcher asks GitHub for your open PRs (one request every 90 s, and
   right after one of your Claude sessions pushes). Only GitHub's own state starts a
   review: a new PR, a new head commit, a reply on a review thread, or a thread resolved
   by hand.
2. **Review.** A headless reviewer (`claude -p`) runs in a detached git worktree of your
   local checkout, at the PR's head commit. It reads the repo's `CLAUDE.md` and
   `AGENTS.md`, and uses your `code-review` skill if you have one.
3. **Comment.** Findings are posted as one review with inline comments, each signed
   `— 🤖 reviewed by pr-review plugin`.
4. **Fix.** The Claude session that pushed the PR gets the list. It fixes what is right
   and pushes, or replies on a thread it disagrees with.
5. **Repeat.** Each push or reply resumes the same reviewer conversation. It resolves
   what was fixed, answers replies, and looks for new problems.

## When it stops

| Stop | When |
|---|---|
| ✅ Finished | None of its threads are open (fixed, accepted, or resolved by hand) |
| ⏸ Stalled | Two rounds in a row resolved nothing |
| 🛑 Round cap | `PR_REVIEW_MAX_ROUNDS` automatic rounds in a row (default 10) with comments still open |
| Merged / closed | The PR is no longer open |

A round is **automatic** when a Claude Code session pushed the commit under review. A
push from a terminal or the GitHub UI is yours: it resets both counters. After a stall or
the cap, tell the listener "continue" to reset them and go on.

A later push to a finished PR starts a fresh review of the new commits.

## Install

```bash
claude plugin install pr-review --marketplace usermeme/claude-plugins
```

Restart running sessions so the hook loads in them.

## Use

Start the listener in any Claude Code session and keep that session open (tmux, the
desktop app or a plain terminal all work):

```
/pr-review:listen
```

On its first start it lists the PRs that are already open and asks whether to review
them. Only one listener can run at a time.

`scripts/ctl.sh status` shows every PR it tracks, with the round and the counters.

## Which PRs

Open PRs you authored, in repos you can push to. That leaves out PRs you send to other
people's projects, so the plugin never comments there. Drafts are included.

| Variable | Effect |
|---|---|
| `PR_REVIEW_OWNERS=me,my-org` | Only repos of these owners |
| `PR_REVIEW_SKIP_DRAFTS=1` | Leave draft PRs out |

The watcher follows your 50 newest open PRs.

## Requirements

- `gh` (logged in), `git`, `jq`.
- A local checkout of each PR's repo. The folder a session pushed from is used; for a PR
  nobody pushed from a session, `~/git` is searched (`PR_REVIEW_SEARCH_ROOTS` for other
  places). Nothing is cloned or downloaded.
- The listener and the sessions that push PRs must share a permission mode. Otherwise the
  messages between them wait for your approval.
- The listener runs the plugin's scripts on its own. In a mode that asks before each
  shell command, allow `scripts/ctl.sh` and `scripts/watch.sh`, or it will stop to ask.

## Configuration

Set these in the environment of the session that runs the listener.

| Variable | Default | Meaning |
|---|---|---|
| `PR_REVIEW_MODEL` | Claude Code's default | Model for the reviewer (`sonnet`, `opus`, …) |
| `PR_REVIEW_EFFORT` | Claude Code's default | Effort level for the reviewer |
| `PR_REVIEW_MAX_BUDGET_USD` | none | Spending limit for one review round |
| `PR_REVIEW_TIMEOUT` | `1800` | Seconds before a round is stopped |
| `PR_REVIEW_MAX_ROUNDS` | `10` | Automatic rounds in a row before the cap; `0` = no cap |
| `PR_REVIEW_MAX_PARALLEL` | `3` | Reviewers running at once |
| `PR_REVIEW_POLL_SECONDS` | `90` | Seconds between GitHub requests |
| `PR_REVIEW_SEARCH_ROOTS` | `~/git` | Colon-separated folders searched for checkouts |
| `PR_REVIEW_HOME` | `~/.claude/pr-review` | The plugin's state |

The reviewer does not read your Claude Code settings file (see Security), so your default
model and effort there don't apply to it. Use the two variables above.

## Footprint

- **Worktree:** `<repo>/.claude/worktrees/pr-review-<repo>-<n>`, one per PR under review.
  It is detached (no branch), hidden from `git status` through `.git/info/exclude`, and
  removed when the review ends.
- **State:** small JSON files under `~/.claude/pr-review`: the last GitHub snapshot, a log
  of pushes made by your sessions, and per PR the last reviewed commit and the counters.
  If it is deleted, the plugin recovers the last reviewed commit from its signed comments.
- **Processes:** the watcher (a shell loop). Nothing else runs between rounds.

## Security

The reviewer reads code and text it didn't write and runs unattended, so it is boxed in:

- **Restricted mode** (`claude --restricted`). Its file tools can't leave the worktree,
  and the repo's own `.claude` settings, hooks and MCP servers are not loaded. It reads
  `CLAUDE.md` and `AGENTS.md` as guidance for the review.
- **One tool.** The only shell commands it may run are seven exact forms of
  `scripts/prr.sh` (context, diff, log, submit). No `gh`, no `git`, no pipes or redirects.
- **One writable file,** `.pr-review/actions.json` in its worktree, where it lists its
  findings and thread decisions.
- **`prr.sh` does the GitHub work,** and only this: post one review on that PR, reply on
  and resolve the reviewer's own threads. It is pinned to the PR by a file the reviewer
  can't write.
- **Only your words reach it.** Review-thread comments by anyone but you are dropped
  before the reviewer sees them, and only PRs in repos you can push to are reviewed.
- **The message to your session** is built by a script from the thread list plus the
  reviewer's summary.

What remains: the reviewer's comments and summary are written by a model that read the
PR's code, and your authoring session acts on them. Review what it pushes as you would
any change. Comments are posted as your GitHub account, with the `COMMENT` review type
(GitHub doesn't let you approve or request changes on your own PR).

## Develop

```bash
tests/run.sh            # stub gh and claude, throwaway repos; no network, no model
claude plugin validate .
```
