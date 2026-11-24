# Builds one inbox record from a Stop or Notification hook input.
# Args: $type ("reply" | "waiting"), $text, $name, $pane, $window, $now (epoch seconds),
#       $max (preview length; 0 = keep the whole text).
($text | length) as $n
| ($text | split("\n") | map(select(test("\\S"))) | (last // "")) as $last
| {
    type: $type,
    ts: ($now | tonumber),
    session_id: (.session_id // ""),
    name: $name,
    cwd: (.cwd // ""),
    pane: $pane,
    window: $window,
    kind: (.notification_type // ""),
    needs: (
      if $type == "waiting" then "dialog"
      elif ($last | test("\\?[\\s*_`)\"»]*$")) then "question"
      else "" end
    ),
    chars: $n,
    truncated: (($max | tonumber) > 0 and $n > ($max | tonumber)),
    text: (
      if ($max | tonumber) > 0 and $n > ($max | tonumber)
      then $text[0:($max | tonumber)] + "…"
      else $text end
    )
  }
