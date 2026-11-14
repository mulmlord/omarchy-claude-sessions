#!/bin/bash
# Claude Code usage for the widget's panel, read through tokscale.
#   usage.sh stats [max-age-sec]  -> {days:[…], hours:[…], time:{…}} from the local transcripts
#   usage.sh quota [max-age-sec]  -> {plan, metrics:[{label, used, resets|resetsMs}], at, source} (subscription limits)
#   usage.sh sessions [max-age-sec] [window-start-sec] -> {ws, windowCost, sessions:{<id>:{all, main, agents}}} (per-session tokens)
# The bar runs one widget per monitor, so answers are cached and serialized
# with flock, so every instance shares one tokscale run.
# Prints {"error": "..."} when tokscale is missing or fails.
# The shell's PATH often lacks mise/npm global bins, so look there too.
tokscale=$(command -v tokscale || ls -1d "$HOME"/.local/share/mise/installs/node/*/bin/tokscale "$HOME"/.npm-global/bin/tokscale 2>/dev/null | tail -1)
[[ -n $tokscale && -x $tokscale ]] || { echo '{"error":"tokscale not found"}'; exit 0; }

cache=${XDG_CACHE_HOME:-$HOME/.cache}/mulm.claude-sessions
mkdir -p "$cache"
mode=$1 max_age=${2:-60}
[[ $max_age =~ ^[0-9]+$ ]] || max_age=60
age() { [[ -s $1 ]] && echo $(( $(date +%s) - $(stat -c %Y "$1") )) || echo 999999; }
publish() { local tmp; tmp=$(mktemp "$1.XXXX") && cat > "$tmp" && mv -f "$tmp" "$1"; }

case $mode in
  stats)
    exec 9> "$cache/stats.lock"; flock -w 90 9
    out=$cache/stats.json
    if (( $(age "$out") >= max_age )); then
      jq -cn --slurpfile g <(timeout 60 "$tokscale" graph -c claude --no-spinner 2>/dev/null || echo '{}') \
             --slurpfile h <(timeout 60 "$tokscale" hourly --json --today -c claude --no-spinner 2>/dev/null || echo '{}') '
        ($g[0] // {}) as $graph | ($h[0] // {}) as $hourly |
        if $graph.contributions == null then {error: "tokscale graph failed"} else {
          days: [ $graph.contributions[] | {
            d: .date, c: (.totals.cost // 0), t: (.totals.tokens // 0), m: (.totals.messages // 0),
            a: (.activeTimeMs // 0), l: (.intensity // 0),
            b: [ .tokenBreakdown | (.input // 0), (.output // 0), (.cacheRead // 0), (.cacheWrite // 0) ],
            mo: (reduce (.clients // [])[] as $x ({};
                  .[$x.modelId] |= { c: ((.c // 0) + ($x.cost // 0)),
                                     t: ((.t // 0) + ($x.tokens | (.input // 0) + (.output // 0) + (.cacheRead // 0) + (.cacheWrite // 0) + (.reasoning // 0))),
                                     m: ((.m // 0) + ($x.messages // 0)) }))
          } ],
          hours: [ ($hourly.entries // [])[] | {
            h: (.hour[11:13] | tonumber), c: (.cost // 0),
            t: ((.input // 0) + (.output // 0) + (.cacheRead // 0) + (.cacheWrite // 0)), m: (.messageCount // 0)
          } ],
          time: ($graph.timeMetrics // {})
        } end' 2>/dev/null > "$cache/stats.new" || echo '{"error":"could not parse tokscale output"}' > "$cache/stats.new"
      # Keep the last good answer when this run failed.
      if jq -e '.days' "$cache/stats.new" > /dev/null 2>&1 || [[ ! -s $out ]]; then
        publish "$out" < "$cache/stats.new"
      else
        touch "$out"
      fi
      rm -f "$cache/stats.new"
    fi
    cat "$out" ;;

  quota)
    # Two sources: Claude Code's statusline input (rate_limits, refreshed with
    # every API response, written by ~/.claude/statusline.sh) and tokscale's
    # call to Anthropic's usage endpoint, which adds the plan and per-model
    # weekly limits but answers HTTP 429 when asked often. So tokscale is asked
    # at most every 5 min (15 min while the statusline is fresh), never twice
    # within a minute, and the newest reading per limit wins.
    exec 9> "$cache/quota.lock"; flock -w 60 9
    out=$cache/quota.json tried=$cache/quota.tried sl=$cache/ratelimits.json
    (( max_age < 60 )) && max_age=60
    (( $(age "$sl") < 600 && max_age < 900 )) && max_age=900
    if (( $(age "$out") >= max_age && $(age "$tried") >= 60 )); then
      touch "$tried"
      fresh=$(timeout 30 "$tokscale" usage --json 2>/dev/null | jq -c --argjson at "$(date +%s%3N)" '
        ([ .[]? | select(.provider == "Claude") ][0] // {}) as $c
        | { plan: ($c.plan // ""), metrics: [ ($c.metrics // [])[] | { label, used: .used_percent, resets: .resets_at } ], at: $at }
        | select(.metrics | length > 0)' 2>/dev/null)
      [[ -n $fresh ]] && publish "$out" <<< "$fresh"
    fi
    jq -cn --slurpfile t <(cat "$out" 2>/dev/null || echo '{}') --slurpfile s <(cat "$sl" 2>/dev/null || echo '{}') '
      ($t[0] // {}) as $t | ($s[0] // {}) as $s | ($s.at // 0) as $sat | ($t.at // 0) as $tat
      | [ (if $s.five_hour then { label: "Session", used: $s.five_hour.used_percentage, resetsMs: ($s.five_hour.resets_at * 1000) } else empty end),
          (if $s.seven_day then { label: "Weekly", used: $s.seven_day.used_percentage, resetsMs: ($s.seven_day.resets_at * 1000) } else empty end) ] as $sm
      | if $sat > $tat and ($sm | length) > 0 then
          { plan: ($t.plan // ""), at: $sat, source: "statusline",
            metrics: ($sm + [ ($t.metrics // [])[] | select(.label as $l | $sm | map(.label) | index($l) | not) ]) }
        elif ($t.metrics // [] | length) > 0 then $t + { source: "tokscale" }
        else { metrics: [] } end' 2>/dev/null || echo '{"metrics":[]}' ;;

  sessions)
    # Token use of each live session for the panel, read from the transcripts
    # (tokscale's per-session report has no window, cache-write split or
    # subagents): per main transcript and per subagent the tokens by type
    # [input, output, cache read, cache write], message count, API-equivalent
    # cost c, and wc, the part of c spent since the 5-hour window started.
    # windowCost is wc over every transcript written in the window, so the
    # widget can split the window's limit use across sessions by cost.
    ws=${3:-0}
    [[ $ws =~ ^[0-9]+$ ]] && ((ws > 0)) || ws=$(( $(date +%s) - 18000 ))
    exec 9> "$cache/sessions.lock"; flock -w 30 9
    out=$cache/sessions.json price=$cache/pricing.json
    if (( $(age "$out") >= max_age )) || [[ $(jq -r '.ws // 0' "$out" 2>/dev/null) != "$ws" ]]; then
      projects=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects
      # A session moved into a background job runs on in the job's transcript
      # (which repeats the earlier conversation): its files count for the
      # session, and the message-id dedupe below drops the repeated part.
      shopt -s nullglob
      files=()
      declare -A owner=()
      while read -r sid own; do
        [[ $sid =~ ^[0-9a-f-]+$ && $own =~ ^[0-9a-f-]+$ ]] || continue
        owner[$sid]=$own
        files+=("$projects"/*/"$sid".jsonl "$projects"/*/"$sid"/subagents/agent-*.jsonl)
      done < <("${BASH_SOURCE[0]%/*}/sessions.sh" | jq -r '.[] | "\(.sessionId) \(.sessionId)",
                 (select(.jobSessionId) | "\(.jobSessionId) \(.sessionId)")' 2>/dev/null)
      live=$(printf '%s\n' "${owner[@]}" | jq -Rsc 'split("\n") | map(select(. != "")) | unique')
      mapfile -t -O "${#files[@]}" files < <(find "$projects" -name '*.jsonl' -newermt "@$ws" 2>/dev/null)
      rows=$(
        printf '%s\n' "${files[@]}" | sort -u | while read -r f; do
          [[ -n $f ]] || continue
          rel=${f#"$projects"/}
          case $rel in
            */*/subagents/agent-*.jsonl) sid=${rel#*/}; sid=${sid%%/*}; agent=${rel##*/agent-}; agent=${agent%.jsonl} ;;
            */*/*) continue ;;
            */*.jsonl) sid=${rel#*/}; sid=${sid%.jsonl}; agent="" ;;
            *) continue ;;
          esac
          sid=${owner[$sid]:-$sid}
          printf '{"__f":{"s":"%s","a":"%s"}}\n' "$sid" "$agent"
          grep -F '"type":"assistant"' "$f"
        done | jq -Rnc --arg ws "$(date -u -d "@$ws" +%Y-%m-%dT%H:%M:%SZ)" '
          # One record per API response: streamed blocks repeat its usage.
          reduce (inputs | fromjson? | objects) as $l ({ f: null, m: {} };
            if $l.__f then .f = $l.__f
            elif .f != null and $l.type == "assistant" and ($l.message.usage | type) == "object" then
              ($l.message.usage) as $u | ($u.cache_creation.ephemeral_1h_input_tokens // 0) as $c1
              | .m[.f.s + "/" + .f.a + "/" + ($l.message.id // $l.uuid // "")] =
                  [ .f.s, .f.a, ($l.message.model // ""), (($l.timestamp // "") >= $ws),
                    ($u.input_tokens // 0), ($u.output_tokens // 0), ($u.cache_read_input_tokens // 0),
                    ([($u.cache_creation_input_tokens // 0) - $c1, 0] | max), $c1 ]
            else . end)
          | [ .m[] ] | group_by(.[0:4])
          | map({ s: .[0][0], a: .[0][1], model: .[0][2], w: .[0][3], n: length,
                  i: (map(.[4]) | add), o: (map(.[5]) | add), r: (map(.[6]) | add), c5: (map(.[7]) | add), c1: (map(.[8]) | add) })' 2>/dev/null
      )
      [[ -n $rows ]] || rows='[]'

      # Rates per model from tokscale (LiteLLM), kept for a week. A model it
      # can't price is stored as {} so it isn't asked again every refresh.
      [[ -s $price ]] && (( $(age "$price") < 7 * 86400 )) || echo '{}' > "$price"
      for m in $(jq -r '[.[].model] | unique | .[]' <<< "$rows"); do
        [[ $m =~ ^[A-Za-z0-9._-]+$ ]] || continue
        jq -e --arg m "$m" 'has($m)' "$price" > /dev/null 2>&1 && continue
        r=$(timeout 20 "$tokscale" pricing "$m" --json 2>/dev/null | jq -c '.allRates // {} | {
              i: .input_cost_per_token, o: .output_cost_per_token, r: .cache_read_input_token_cost,
              w: .cache_creation_input_token_cost, w1: .cache_creation_input_token_cost_above_1hr }
            | with_entries(select(.value | type == "number"))' 2>/dev/null)
        [[ -n $r ]] || r='{}'
        jq -c --arg m "$m" --argjson r "$r" '.[$m] = $r' "$price" 2>/dev/null | publish "$price"
      done

      jq -cn --argjson rows "$rows" --argjson live "$live" --slurpfile p <(cat "$price" 2>/dev/null || echo '{}') \
             --argjson ws "$ws" --argjson at "$(date +%s%3N)" '
        def agg: { t: [ (map(.i) | add // 0), (map(.o) | add // 0), (map(.r) | add // 0), (map(.c5 + .c1) | add // 0) ],
                   n: (map(.n) | add // 0), c: (map(.cost) | add // 0), wc: (map(select(.w) | .cost) | add // 0) };
        ($p[0] // {}) as $price
        | [ $rows[] | (($price[.model] // {}) as $q
            | . + { cost: (.i * ($q.i // 0) + .o * ($q.o // 0) + .r * ($q.r // 0) + .c5 * ($q.w // 0) + .c1 * ($q.w1 // $q.w // 0)) }) ]
        | { ws: $ws, at: $at, windowCost: (map(select(.w) | .cost) | add // 0),
            sessions: (map(select(.s as $s | $live | index($s))) | group_by(.s) | map({ key: .[0].s, value: {
              all: agg, main: (map(select(.a == "")) | agg),
              agents: (map(select(.a != "")) | group_by(.a) | map({ key: .[0].a, value: agg }) | from_entries) } }) | from_entries) }' \
        2>/dev/null | publish "$out"
    fi
    cat "$out" 2>/dev/null || echo '{}' ;;

  *) echo "usage: $0 stats|quota|sessions [max-age-sec]" >&2; exit 2 ;;
esac
