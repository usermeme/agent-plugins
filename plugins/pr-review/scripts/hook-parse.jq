# Reads a PostToolUse(Bash) hook payload. Prints one object when the command really runs
# `git push` or `gh pr create`, and nothing otherwise.
#
# "Really runs" means the words stand at a command position: the start of the command, or
# right after ; & | ( or a newline. The same words inside a commit message or a comment
# body ("... then git push") do not count.
#
# Output: {type, cd, git_c}
#   cd     the last `cd <dir>` before the command, or ""
#   git_c  the `git -C <dir>` of a push, or ""

def unquote: if test("^\".*\"$") or test("^'.*'$") then .[1:-1] else . end;

(.tool_input.command // "") as $c
| "(?:^|[;&|(\\n])\\s*(?:[A-Za-z_][A-Za-z0-9_]*=\\S*\\s+)*" as $start
| "(?:\"[^\"]*\"|'[^']*'|[^\\s;&|)]+)" as $word
| ( [ $c | match($start + "git((?:\\s+-C\\s+" + $word + "|\\s+-c\\s+" + $word + "|\\s+--[A-Za-z-]+(?:=\\S+)?)*)\\s+push\\b([^;&|\\n]*)"; "g") ]
    | last ) as $push
| ( [ $c | match($start + "gh\\s+(?:(?:-R|--repo)\\s+" + $word + "\\s+)?pr\\s+create\\b([^;&|\\n]*)"; "g") ]
    | last ) as $create
| ( if $create != null then
      { type: "pr-create", at: $create.offset, opts: "", rest: ($create.captures[0].string // "") }
    elif $push != null then
      { type: "push", at: $push.offset, opts: ($push.captures[0].string // ""), rest: ($push.captures[1].string // "") }
    else empty end ) as $m
| select(($m.type == "push" and ($m.rest | test("(^|\\s)(--dry-run|-n)(\\s|$)"))) | not)
| ( [ $m.opts | match("-C\\s+(" + $word + ")"; "g") | .captures[0].string | unquote ] | last ) as $gitc
| ( [ $c[0:$m.at] | match($start + "cd\\s+(" + $word + ")"; "g") | .captures[0].string | unquote ] | last ) as $cd
| { type: $m.type, cd: ($cd // ""), git_c: ($gitc // "") }
