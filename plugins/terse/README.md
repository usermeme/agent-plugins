# terse

An output style that is on whenever the plugin is enabled. It adds two rules to Claude
Code's default instructions:

- **Short replies.** Lead with the answer, no preamble or recap, usually under about 150
  words. Ask for an explanation or a write-up and you still get one.
- **No code comments unless you ask.** No new inline comments, docstrings or TODOs.
  Existing comments are kept, and updated when Claude's change makes them wrong.
  Directives such as `// eslint-disable-next-line`,
  `# noqa` or `//go:build` are still written when the code needs them.

The rules live in [`output-styles/terse.md`](output-styles/terse.md).

## Install

```bash
claude plugin install terse --marketplace usermeme/agent-plugins
```

Restart running sessions to pick it up.

## What it changes for you

- It **replaces your selected output style** in every project while the plugin is
  enabled. To go back to your own style, disable the plugin:
  `claude plugin disable terse@usermeme`.
- If another enabled plugin also forces an output style, the first plugin loaded wins.
- Subagents get the same rules. Output styles only reach the main conversation and forks,
  so a `SubagentStart` hook ([`scripts/subagent-context.sh`](scripts/subagent-context.sh))
  adds the style's text to every other subagent's context when it starts. Subagents are told
  to keep their reports free of preamble but never drop findings to be shorter, because the
  agent that launched them acts only on what they report. The hook needs `jq`; without it,
  subagents start without the rules and Claude Code shows a hook error.
- Claude Code's default coding instructions stay in place (`keep-coding-instructions: true`).
