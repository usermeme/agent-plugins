# switchboard

Run all your Claude Code sessions from one place, typically your phone.

One session is the **operator**. Every other interactive session forwards its final reply
to it, and tells it when it gets stuck on a permission prompt or a dialog. You talk to the
operator through Remote Control: it relays what comes in, pushes a notification when a
session needs you, and on your word messages a session back, shows or answers its dialog,
or opens a new Claude session in tmux.

## Install

```bash
claude plugin install switchboard --marketplace usermeme/claude-plugins
```

## Start

In a tmux window:

```bash
claude --remote-control switchboard
```

then, in that session:

```
/switchboard:operate
```

Open the `switchboard` session in the Claude app on your phone. Sessions that were running
before the plugin was installed pick up its hooks only after a restart.

## Talking to the operator

| Say | It does |
|---|---|
| `tell landing-a7 run the tests again` | sends `run the tests again` to that session, word for word (`SendMessage`) |
| `show landing-a7` | the full last reply (relays are cut to a short preview on a phone) |
| `list` | running sessions: name, state, tmux window, folder |
| `screen landing-a7` | what that session's tmux pane shows now, e.g. a permission dialog |
| `pick 2 in landing-a7`, `press Enter in landing-a7` | presses those keys in its pane |
| `new api in ~/git/api to fix the failing build` | opens `claude -n api "fix the failing build"` in a new window of the `main` tmux session |
| `switchboard off` | stops forwarding |

It pushes a notification only when a session needs you: it is waiting on a dialog, its
reply ends with a question, or it reports that it is blocked or failed.

## How it works

```
session ──Stop / Notification hook──▶ ~/.claude/switchboard/inbox.jsonl
                                              │
                         watch.sh (background) exits on new lines
                                              ▼
                                         operator ──▶ you (Remote Control, push)
                                              │
              you ──▶ operator ──SendMessage / ctl.sh press / ctl.sh new──▶ sessions
```

- **`scripts/on-hook.sh`** (`Stop`, and `Notification` for `permission_prompt` and
  `elicitation_dialog`) writes one record per event: session name, folder, tmux pane, needs
  (`question`, `dialog` or nothing), and the text, cut to `SWITCHBOARD_PREVIEW` characters
  (default 1200). The whole text goes to `last/<session>.json` for `show`. It writes only
  while an operator is running and only for interactive sessions
  (`CLAUDE_CODE_ENTRYPOINT=cli` and `CLAUDE_CODE_SESSION_ATTENDED=1`), so `claude -p` runs
  such as pr-review's reviewers and the operator itself are never forwarded. It always exits
  0 with no output, so it can't block or change a session.
- **`scripts/watch.sh`** waits for new records, prints up to 20 and exits, which wakes the
  operator. It also exits if another session takes over as operator.
- **`scripts/ctl.sh`** does the rest: `register`, `unregister`, `status`, `list`, `show`,
  `screen`, `press`, `new`. Run it with no arguments for help. You can use it from a
  terminal too.
- **Messages back** use Claude Code's own `SendMessage`, which wakes an idle session.

State lives in `~/.claude/switchboard` (`SWITCHBOARD_HOME`): `operator.json`, `inbox.jsonl`,
`offset`, `last/`. Registering a new operator empties the inbox.

## Settings

| Variable | Default | |
|---|---|---|
| `SWITCHBOARD_TMUX_SESSION` | `main` | tmux session that `new` opens windows in (created if missing) |
| `SWITCHBOARD_PREVIEW` | `1200` | characters of each reply sent to the operator |
| `SWITCHBOARD_START_WAIT` | `20` | seconds `new` waits for the session to show up |

## Limits

- **Folder trust.** A session opened in a folder Claude doesn't trust yet stops at the trust
  prompt. `new` reports `TRUST`, and the operator asks before pressing Enter to trust it.
- **Dialogs need tmux.** `screen` and `press` work only for sessions running in a tmux pane.
  `press` accepts only `Enter Escape Tab BTab Space Up Down Left Right 0-9 y n`, at most
  five at a time. It can't type text, and it won't press keys in the operator's own pane.
- **A question in a dialog** (`AskUserQuestion`) may not raise a `Notification`. If a session
  goes quiet, ask for `screen <name>`.
- **One operator** at a time. `ctl.sh register --force` takes over from a live one.
- **Push notifications** use Claude Code's `PushNotification` tool. Where it isn't available,
  the operator only relays in its chat.

## Security

Whoever controls the operator can drive every session, so the operator is only as safe as
your Remote Control account and the operator's permission mode. The operator treats
forwarded replies as data: it relays and summarises them and never follows instructions
inside them. It messages sessions, presses keys and opens sessions only when you ask in its
chat. To avoid a permission prompt for every relay, allow the plugin's `ctl.sh` and
`watch.sh` in the operator session (`/permissions`).

## Develop

```bash
tests/run.sh          # 64 checks; stub claude and tmux, nothing real is touched
tests/run.sh hook     # one group: hook | watch | ctl
```
