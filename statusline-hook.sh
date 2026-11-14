#!/bin/bash
# Optional: feed the widget from Claude Code's statusline. Pipe the statusline
# input JSON into this script; it prints nothing.
#
#   input=$(cat)
#   printf '%s' "$input" | ~/.config/omarchy/plugins/mulm.claude-sessions/statusline-hook.sh
#
# It keeps two things the widget can't read from the transcripts:
#   ratelimits.json   the subscription limits (5-hour / weekly), so the widget
#                     rarely has to ask Anthropic's usage endpoint via tokscale
#   ctx/<session>.json the context window size, for the context-fill line
input=$(cat)
dir="${XDG_CACHE_HOME:-$HOME/.cache}/mulm.claude-sessions"

rl=$(jq -c 'select((.rate_limits.five_hour // .rate_limits.seven_day) != null) | .rate_limits + {at: (now * 1000 | floor)}' <<< "$input" 2>/dev/null)
if [[ -n $rl ]]; then
  mkdir -p "$dir" && printf '%s\n' "$rl" > "$dir/ratelimits.json.$$" && mv -f "$dir/ratelimits.json.$$" "$dir/ratelimits.json"
fi

read -r sid model size <<< "$(jq -r '"\(.session_id // "-") \(.model.id // "-" | sub("\\[.*\\]$"; "")) \(.context_window.context_window_size // 0)"' <<< "$input" 2>/dev/null)"
if [[ $sid =~ ^[0-9a-f-]{36}$ && $model =~ ^[A-Za-z0-9._:@-]+$ && $size =~ ^[1-9][0-9]*$ ]]; then
  ctx="{\"session\":\"$sid\",\"model\":\"$model\",\"size\":$size}"
  { old=$(< "$dir/ctx/$sid.json"); } 2>/dev/null
  if [[ $old != "$ctx" ]]; then
    mkdir -p "$dir/ctx" && printf '%s\n' "$ctx" > "$dir/ctx/$sid.json.$$" && mv -f "$dir/ctx/$sid.json.$$" "$dir/ctx/$sid.json"
    find "$dir/ctx" -name '*.json' -mtime +14 -delete 2>/dev/null
  fi
fi
exit 0
