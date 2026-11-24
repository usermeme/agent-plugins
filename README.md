# agent-plugins

A personal [Claude Code](https://claude.com/claude-code) plugin marketplace.

| Plugin | What it does |
|---|---|
| [`pr-review`](plugins/pr-review) | Automatic review loop for your own GitHub PRs: reviews each PR, sends findings to the Claude session that opened it, and re-reviews every push until all threads are resolved. |

## Install

In Claude Code:

```
/plugin marketplace add usermeme/agent-plugins
/plugin install pr-review@usermeme
```

Or from a terminal, in one step:

```bash
claude plugin install pr-review --marketplace usermeme/agent-plugins
```

The repo is private. Claude Code clones it with your normal git credentials, so you need
read access via SSH or `gh auth`.

Sessions that are already running pick up a new plugin's hooks only after a restart.

## Update

```bash
claude plugin marketplace update usermeme
```

## Develop

Try a change without installing:

```bash
claude --plugin-dir ./plugins/pr-review
```

Validate before you push:

```bash
claude plugin validate .
claude plugin validate plugins/pr-review
```

Add a plugin: create `plugins/<name>/.claude-plugin/plugin.json`, then list it in
[`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json).
