#!/usr/bin/env bash
set -euo pipefail

cat >/dev/null

plugin_root="$(cd "$(dirname "$0")/.." && pwd)"
style="$plugin_root/output-styles/terse.md"

rules="$(awk 'NR == 1 && /^---$/ { in_frontmatter = 1; next }
              in_frontmatter && /^---$/ { in_frontmatter = 0; next }
              !in_frontmatter' "$style")"

preface="You are a subagent. The rules below are the user's standing rules and apply to you too, with one change: your reply goes to the agent that launched you, not to the user. Skip preamble and recap, but include every result the task asked for. Never drop findings, file paths or evidence to make the reply shorter."

jq -n --arg context "$preface"$'\n'"$rules" \
  '{hookSpecificOutput: {hookEventName: "SubagentStart", additionalContext: $context}}'
