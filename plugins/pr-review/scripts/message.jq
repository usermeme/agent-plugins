# The message for the PR's authoring session while comments are open.
# Input: the normalized PR object (lib.sh: pr_fetch). Args: $repo $num $sha $sum $url.
# The first line has to stand on its own: it is all the session's user sees at a glance.

[ .threads[] | select(.resolved | not) ] as $open
| "pr-review: \($open | length) open comment(s) on \($repo)#\($num) at \($sha). Please address them and push.",
  ( $open[]
    | "- \(.path):\(.line // "?") \(
        [ .comments[] | select(.who == "reviewer") ] | last | .body // ""
        | split("\n") | map(select(length > 0)) | .[0] // "" | .[0:200])  (thread \(.id))" ),
  ( if $sum != "" then "Reviewer: \($sum)" else empty end ),
  "Full text: \($url)/files",
  "What to do: fix the ones that are right, then commit and push to the PR branch. If one is wrong, do not change code for it: reply on its thread, and the reviewer will answer or resolve it:",
  "  gh api graphql -f query='mutation($t: ID!, $b: String!) { addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $t, body: $b}) { comment { id } } }' -f t=<thread id> -f b='<your reason>'",
  "Do not resolve threads yourself. The reviewer re-checks after your push or reply."
