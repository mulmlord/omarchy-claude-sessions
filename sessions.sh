#!/bin/bash
# Print the live Claude Code sessions as one JSON array.
# Claude Code keeps ~/.claude/sessions/<pid>.json per running process; a file
# whose pid is gone (or was reused, procStart mismatch) is stale and skipped,
# and background sessions (kind "bg") are left to the session that spawned them.
#
# Each session also carries `agents`, its subagents that are still running.
# Their transcripts live in ~/.claude/projects/<project>/<sessionId>/subagents/
# as agent-<id>.jsonl beside agent-<id>.meta.json (type, description). A
# subagent is done once its last assistant message calls SubagentHandback or
# ends the turn, its meta says `finished`, or a <task-notification> for it
# (completed/killed/failed) is newer than its transcript. One whose transcript
# hasn't been written for 15 minutes, or predates the session's process,
# counts as gone (stopped or interrupted).
#
# A session whose conversation was moved into a background job (`parkedJobId`
# = the bg session's `jobId`) keeps running there, so that job's subagents are
# counted for the session too. Agents present in both folders (same id) are
# counted once, from the copy written last. The job doesn't keep the status in
# its session file current, so its transcript says too: a finished turn
# (system turn_duration) is idle, any later message busy. The newest of the
# session's, the job file's and the job transcript's status wins.
#
# Claude Code can also leave an interactive session at `busy` after its turn
# has ended (seen while background subagents run), so a busy session whose
# transcript ends with a finished turn written after that status counts as
# idle, and gets its shells and agents like any finished turn.
#
# `jobSessionId` names that job's session, so usage.sh can count its tokens here.
#
# `context` is how full the conversation's context window is: the last main
# assistant message's input + cache read + cache write tokens (what Claude
# Code's statusline counts) over the window size the statusline hook (statusline-hook.sh) saw
# for that session (cache ctx/<sessionId>.json), else for its model.
#
# Cost: the bar runs one widget per monitor and each polls this script, so a
# result less than 1.5 s old is shared (cache live.json) and, under flock, only
# one instance recomputes. Before recomputing it compares a fingerprint (size
# and mtime of this script, the session files and every transcript, subagent folder and
# context file the last result was built from, the live pids, a 30 s tick for
# the 15-minute cutoff); while nothing changed the last result stands. What
# a recompute needs from each transcript is cached as compact facts under its
# size and mtime (scan/), so only transcripts that grew are read again, all
# through one jq, and the merge parses a few KB. Most of a run is process
# startup, hence builtins over cat/$(<…) and subshells.
config="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
dir="$config/sessions"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/mulm.claude-sessions"
scan=$cache/scan
stale=900
shareMs=1500
shopt -s nullglob

out=$cache/live.json stamp=$cache/live.stamp
nowMs() { local t=${EPOCHREALTIME/./}; REPLY=$((10#$t / 1000)); }
fresh() {
  local at
  { read -r at < "$stamp"; } 2>/dev/null && [[ $at =~ ^[0-9]+$ && -s $out ]] || return 1
  nowMs; ((REPLY - at < shareMs))
}
emit() { local lines; mapfile -t lines < "$out"; printf '%s\n' "${lines[@]}"; exit 0; }

[[ -d $scan ]] || mkdir -p "$scan"
fresh && emit
exec 9> "$cache/live.lock"
flock -w 5 9
fresh && emit

files=("$dir"/*.json)
live=""
for f in "${files[@]}"; do
  pid=${f##*/}; pid=${pid%.json}
  { read -r stat < "/proc/$pid/stat"; } 2>/dev/null || continue
  read -ra fields <<< "${stat##*) }"   # fields after "(comm)": state=0 … starttime=19
  live+="\"$pid\":\"${fields[19]}\","
done

fingerprint() {  # paths…
  REPLY="$live|$((EPOCHSECONDS / 30))"
  (($#)) && REPLY+=$'\n'$(stat -c '%n %s %Y' -- "$@" 2>/dev/null)
}
watch=()
[[ -r $cache/live.watch ]] && mapfile -t watch < "$cache/live.watch"
fingerprint "${BASH_SOURCE[0]}" "${files[@]}" "${watch[@]}"   # the script too: an edit invalidates
fp=$REPLY
oldfp=""
{ IFS= read -r -d '' oldfp < "$cache/live.fp"; } 2>/dev/null
if [[ -s $out && $oldfp == "$fp" ]]; then
  nowMs; printf '%s\n' "$REPLY" > "$stamp"; emit
fi

# The sessions as JSON on the first line, then "<sessionId> <job sessionId|-> <startedAt>" each.
declare -A started=() owner=() isJob=()
sessions='[]' agentFiles=() transcripts=() newWatch=()
{
  read -r sessions
  while read -r sid job at; do
    for s in "$sid" "$job"; do
      [[ $s =~ ^[0-9a-f-]{36}$ ]] || continue
      [[ $s == "$job" ]] && isJob[$s]=1
      [[ -n ${owner[$s]} ]] && continue   # an orphaned job is its own job
      owner[$s]=$sid
      started[$s]=$((${at:-0} / 1000))
      agentFiles+=("$config"/projects/*/"$s"/subagents/agent-*.jsonl)
      transcripts+=("$config"/projects/*/"$s".jsonl)
      newWatch+=("$config"/projects/*/"$s" "$config"/projects/*/"$s"/subagents "$config"/projects/*/"$s".jsonl
                 "$config"/projects/*/"$s"/subagents/agent-*.json* "$cache/ctx/$s.json")
    done
  done
} < <( ((${#files[@]})) && jq -rs --argjson live "{${live%,}}" '
  [ .[]
    | select(type == "object" and .pid != null)
    | select($live[.pid | tostring] == (.procStart | tostring)) ] as $all
  | ($all | map(select(.kind == "bg" and .jobId != null)
                | { key: .jobId, value: { sessionId, status, waitingFor, statusUpdatedAt } }) | from_entries) as $jobs
  | [ $all[] | select(.kind != "bg") | .parkedJobId // empty ] as $parked
  | [ $all[]
      | select(.kind != "bg"
               or (.jobId != null and .spare != true and ((.jobId | IN($parked[])) | not)))
      | { pid, sessionId, name, cwd, kind, status, waitingFor, statusUpdatedAt, startedAt,
          job: (if .kind == "bg" then { sessionId, status, waitingFor, statusUpdatedAt }
                elif .parkedJobId then $jobs[.parkedJobId] else null end) } ]
  | sort_by(.startedAt)
  | tojson, (.[] | "\(.sessionId) \(.job.sessionId // "-") \(.startedAt // 0)")' "${files[@]}" 2>/dev/null)
[[ $sessions ]] || sessions='[]'

# Size/mtime of the transcripts; subagents written in the last 15 minutes,
# after their session started, are the candidates for running.
now=$EPOCHSECONDS
declare -A key=()
liveAgents=() livePaths=()
((${#transcripts[@]} + ${#agentFiles[@]})) && while read -r mtime birth size path; do
  key[$path]="$size $mtime"
  [[ $path == */subagents/* ]] || continue
  sid=${path%/subagents/*}; sid=${sid##*/}
  ((now - mtime < stale && mtime >= ${started[$sid]:-0})) || continue
  liveAgents+=("$mtime $birth $path"); livePaths+=("$path")
done < <(stat -c '%Y %W %s %n' -- "${transcripts[@]}" "${agentFiles[@]}" 2>/dev/null)

# What each transcript contributes, cached as compact facts under its size and
# mtime (scan/), one JSON object per line after the key line:
#   {"ctx":{model,at,tokens}}   the last main assistant message (context)
#   {"act":{ended,at}}          the last turn activity, a message or the end of a turn (status)
#   {"launch":{tu,kind,description,at,until}}  a Bash run_in_background / Monitor call
#   {"task":{tu,id}}            its start result, which names the task id
#   {"end":{id,t}}              a task ended: a notification with a status, a
#                               monitor's expiry, or a TaskStop result
#   {"done":bool} {"action":{tool,detail}}  agents: last message ends it? last tool call
# Quotes inside JSON strings are escaped, so the grep patterns only hit real
# record keys and a few matches from the end suffice; api-request records
# repeat the whole conversation, so they are skipped. All stale files are
# re-read in one pass, through one jq, and split back into their cache files.
scanVersion=v8
cacheOf() { local c=${1#"$config"/projects/}; REPLY=$scan/${c//\//%}; }
declare -A modeOf=()
for t in "${transcripts[@]}"; do
  s=${t##*/}; s=${s%.jsonl}
  if [[ ${isJob[$s]} ]]; then modeOf[$t]=job; else modeOf[$t]=tx; fi
done
for p in "${livePaths[@]}"; do modeOf[$p]=agent; done
staleFiles=()
for p in "${!modeOf[@]}"; do
  cacheOf "$p"; head=""
  { IFS= read -r head < "$REPLY"; } 2>/dev/null
  [[ $head == "${key[$p]} ${modeOf[$p]} $scanVersion" ]] || staleFiles+=("$p")
done
((${#staleFiles[@]})) && for p in "${staleFiles[@]}"; do
  mode=${modeOf[$p]}; cacheOf "$p"
  printf '{"__file":"%s","key":"%s","mode":"%s"}\n' "$REPLY" "${key[$p]} $mode $scanVersion" "$mode"
  # From the end: the last 3 assistant lines (context, an agent's state) and,
  # outside agents, the last 4 messages or turn ends (status), in one pass.
  tac -- "$p" | awk -v acts=$([[ $mode == agent ]] && echo 0 || echo 4) '
    { hit = 0; asst = index($0, "\"type\":\"assistant\"") }
    asst && na < 3 { na++; hit = 1 }
    acts > 0 && (asst || index($0, "\"type\":\"user\"") || index($0, "\"subtype\":\"turn_duration\"")) { acts--; hit = 1 }
    hit { print }
    na >= 3 && acts <= 0 { exit }'
  printf '{"__bg":true}\n'
  if [[ $mode == agent ]]; then   # its own agents' and shells' ends
    grep -E '"operation":"enqueue".*"content":"<task-notification>.*(<status>|\[Monitor expired)|Successfully stopped task: ' -- "$p"
  else
    grep -E '"operation":"enqueue".*"content":"<task-notification>.*(<status>|\[Monitor expired)|"run_in_background":true|"type":"tool_use","id":"toolu_[A-Za-z0-9]+","name":"Monitor"|running in background with ID: |Monitor started \(task |Successfully stopped task: ' -- "$p"
  fi | grep -v '^{"type":"api-request'
done | jq -Rnc '
  def ts: (. // "" | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch null);
  def done: (.message.stop_reason // "") as $r
    | $r == "end_turn" or $r == "stop_sequence"
      or any(.message.content[]?; .type? == "tool_use" and .name? == "SubagentHandback");
  def firstLine: tostring | split("\n")[0];
  # A tool call in a few words: what it runs, edits or looks for.
  def action: .name as $n | (.input // {}) as $i
    | { tool: $n,
        detail: (if $n == "Bash" then ($i.description // ($i.command // "" | firstLine))
                 elif ($n | IN("Read", "Edit", "Write", "NotebookEdit")) then
                   ($i.file_path // $i.notebook_path // "" | tostring | split("/") | last)
                 elif ($n | IN("Grep", "Glob")) then ($i.pattern // "")
                 elif $n == "WebFetch" then ($i.url // "" | tostring | sub("^[a-z]+://"; "") | split("/")[0])
                 elif $n == "WebSearch" then ($i.query // "")
                 else ($i.description // $i.prompt // "" | firstLine) end | tostring | .[0:80]) };
  # A tool result as text, whether a string or a list of blocks.
  def resultText: if (.content | type) == "string" then .content
                  else [.content[]? | select(.type? == "text") | .text] | join("\n") end;
  foreach (inputs | fromjson? | objects) as $l ({ file: null };
    .out = []
    | if $l.__file then { file: $l.__file, mode: $l.mode, out: [{ __file: $l.__file, key: $l.key }] }
      elif $l.__bg then .bg = true
      elif .file == null or ($l.isSidechain == true and .mode != "agent") then .   # agents are sidechains
      else
        ($l.timestamp | ts) as $t
        | if $l.type == "queue-operation" then
            if $t and ($l.content | type) == "string" and ($l.content | startswith("<task-notification>")) then
              .out += [$l.content | split("<task-notification>")[] | select(test("<status>|\\[Monitor expired"))
                       | capture("<task-id>(?<id>[a-z0-9]+)</task-id>") | { end: { id, t: $t } }]
            else . end
          elif .bg then
            if $l.type == "assistant" and .mode != "agent" then
              .out += [$l.message.content[]?
                       | select(.type? == "tool_use"
                                and ((.name == "Bash" and .input.run_in_background == true) or .name == "Monitor"))
                       | { launch: { tu: .id, kind: (if .name == "Monitor" then "monitor" else "shell" end),
                                     description: (action | .detail), at: ($t // 0),
                                     until: (if .name == "Monitor" then ($t // 0) + ((.input.timeout_ms // 300000) / 1000) else null end) } }]
            elif $l.type == "user" then
              # A start result names the task; a TaskStop result ends one (no notification follows).
              .out += [$l.message.content[]? | select(.type? == "tool_result") | { tu: .tool_use_id, text: resultText }
                       | . as $r
                       | (($r.text | capture("^(Command running in background with ID: |Monitor started \\(task )(?<id>[a-z0-9]+)")
                           | { task: { tu: $r.tu, id } }) // empty),
                         (($r.text | capture("Successfully stopped task: (?<id>[a-z0-9]+)") | { end: { id, t: ($t // 0) } }) // empty)]
            else . end
          elif .mode == "agent" then
            if $l.type == "assistant" then
              ([$l.message.content[]? | select(.type? == "tool_use")] | last) as $call
              | (if .seen | not then .seen = true | .out += [{ done: ($l | done) }] else . end)
              | (if $call and (.acted | not) then .acted = true | .out += [{ action: ($call | action) }] else . end)
            else . end
          elif $t == null then .
          else
            (if (.ctx | not) and $l.type == "assistant" and $l.message.usage != null
                and ($l.message.model // "") != "<synthetic>"
             then .ctx = true | .out += [{ ctx: { model: $l.message.model, at: $t,
                    tokens: ($l.message.usage | (.input_tokens // 0) + (.cache_read_input_tokens // 0)
                                               + (.cache_creation_input_tokens // 0)) } }]
             else . end)
            | (if (.act | not)
                  and ($l.type == "assistant" or ($l.type == "user" and ($l.isMeta | not))
                       or ($l.type == "system" and $l.subtype == "turn_duration"))
               then .act = true | .out += [{ act: { ended: ($l.type == "system"), at: $t } }]
               else . end)
          end
      end;
    .out[])' 2>/dev/null | awk '
  /^\{"__file":"/ { if (f != "") close(f); split($0, a, "\""); f = a[4]; print a[8] > f; next }
  f != "" { print > f }
  END { if (f != "") close(f) }'

# Window sizes the statusline reported.
sizes=""
for f in "$cache"/ctx/*.json; do
  { IFS= read -r line < "$f"; } 2>/dev/null && [[ $line == '{"session":"'*'}' ]] && sizes+="$line,"
done

facts() {  # path → its cached facts
  local lines=()
  cacheOf "$1"
  [[ -r $REPLY ]] && mapfile -t lines < "$REPLY"
  ((${#lines[@]} > 1)) && printf '%s\n' "${lines[@]:1}"
}

result=$(
{
  for t in "${transcripts[@]}"; do
    s=${t##*/}; s=${s%.jsonl}
    printf '{"__tx":"%s","owner":"%s"}\n' "$s" "${owner[$s]:-$s}"
    facts "$t"
  done
  for a in "${liveAgents[@]}"; do
    read -r mtime birth path <<< "$a"
    sid=${path%/subagents/*}; sid=${sid##*/}
    ((birth > 0)) || birth=$mtime
    id=${path##*/agent-}; id=${id%.jsonl}
    printf '{"__agent":{"sid":"%s","id":"%s","started":%s,"mtime":%s}}\n' "${owner[$sid]:-$sid}" "$id" "$birth" "$mtime"
    meta=${path%.jsonl}.meta.json
    [[ -r $meta ]] && { mapfile -t m < "$meta"; printf '%s\n' "${m[@]}"; }
    facts "$path"
  done
} | jq -Rnc --argjson sessions "$sessions" --argjson sizes "[${sizes%,}]" --argjson now "$now" '
  def lastAgent(f): .agents[(.agents | length) - 1] |= f;
  reduce (inputs | fromjson? | objects) as $l
         ({ cur: null, tx: {}, agents: [], notified: {}, launches: {}, taskOf: {} };
    if $l.end then .notified[$l.end.id] = ([.notified[$l.end.id] // 0, $l.end.t] | max)
    elif $l.__tx then .cur = { tx: $l.__tx, owner: $l.owner } | .tx[$l.__tx] = {}
    elif $l.__agent then .cur = { agent: true } | .agents += [$l.__agent + { done: false, action: null }]
    elif .cur == null then .
    elif .cur.agent then
      if ($l | has("agentType")) then
        lastAgent(. + { type: $l.agentType, description: $l.description, depth: ($l.spawnDepth // 1),
                        finished: ($l.finished == true) })
      elif ($l | has("done")) then lastAgent(.done = $l.done)
      elif $l.action then lastAgent(.action = $l.action)
      else . end
    elif $l.ctx then .tx[.cur.tx].ctx = $l.ctx
    elif $l.act then .tx[.cur.tx].act = $l.act
    elif $l.launch then .launches[$l.launch.tu] = ($l.launch + { owner: .cur.owner })
    elif $l.task then .taskOf[$l.task.tu] = $l.task.id
    else . end)
  | .notified as $notified | .tx as $tails | .taskOf as $taskOf
  # Background tasks that started and never reported an end (a monitor also
  # ends at its timeout).
  | [ .launches | to_entries[] | .value + { task: $taskOf[.key] }
      | select(.task != null and ($notified[.task] // 0) < .at and (.until == null or .until > $now)) ] as $running
  | { session: ($sizes | map({ key: .session, value: .size }) | from_entries),
      model: ($sizes | map({ key: .model, value: .size }) | from_entries) } as $size
  | .agents
  | group_by(.sid + .id) | map(max_by(.mtime))
  | map(select((.done or .finished or (($notified[.id] // -1) + 5 >= .mtime)) | not))
  | group_by(.sid)
  | map({ key: .[0].sid,
          value: (sort_by(.started) | map({ id, type, description, depth, startedAt: (.started * 1000), action })) })
  | from_entries as $agents
  | $sessions | map(
      [.sessionId, (.job.sessionId // empty)] as $ids
      | .sessionId as $sid | ((.startedAt // 0) / 1000) as $since
      | ([{ status, waitingFor, at: (.statusUpdatedAt // 0) }]
         + (if .job then
              [{ status: .job.status, waitingFor: .job.waitingFor, at: (.job.statusUpdatedAt // 0) }]
              + [$tails[.job.sessionId].act // empty
                 | { status: (if .ended then "idle" else "busy" end), waitingFor: null, at: (.at * 1000) }]
            else [] end)
         | max_by(.at)) as $st
      | .status = $st.status | .waitingFor = $st.waitingFor | .statusUpdatedAt = $st.at
      # A busy status older than a finished turn in the transcript is stale.
      | ($tails[.sessionId].act // null) as $own
      | (if .status == "busy" and (.job | not) and $own != null and $own.ended
            and $own.at * 1000 > .statusUpdatedAt
         then .status = "idle" | .statusUpdatedAt = $own.at * 1000 | .turnEnded = true else . end)
      # Claude Code reports idle only once no shell or monitor runs; a job
      # (status from its transcript) cannot tell, so it takes what was found.
      | .shells = (if .status == "idle" and (.job | not) and (.turnEnded | not) then [] else
          [$running[] | select(.owner == $sid and .at >= $since)] | unique_by(.task) | sort_by(.at)
          | map({ kind, description, startedAt: (.at * 1000) }) end)
      | (if .status == "idle" and (.shells | length) > 0 then .status = "shell" else . end)
      | ([$ids[] | $tails[.].ctx // empty] | max_by(.at)) as $ctx
      | .context = (if $ctx then
          ([$ids[] | $size.session[.] // empty][0] // $size.model[$ctx.model]
           // (if $ctx.tokens > 200000 then 1000000 else 200000 end)) as $win
          | { tokens: $ctx.tokens, size: $win, pct: ([$ctx.tokens * 100 / $win | floor, 100] | min) }
        else null end)
      | .agents = ($agents[.sessionId] // [])
      | .jobSessionId = (.job.sessionId // null)
      | del(.job, .turnEnded))' 2>/dev/null) || result=$(jq -c 'map(.jobSessionId = (.job.sessionId // null) | del(.job))' <<< "$sessions")

printf '%s\n' "$result" > "$out.$$" && mv -f "$out.$$" "$out"
# Keep the fingerprint taken before reading, so a write made meanwhile still
# counts as a change; if the set of watched paths changed, force a re-read
# (and drop the cached facts of transcripts no longer looked at).
if [[ ${newWatch[*]} != "${watch[*]}" ]]; then
  fp=""
  declare -A keep=()
  for p in "${!modeOf[@]}"; do cacheOf "$p"; keep[$REPLY]=1; done
  drop=()
  for f in "$scan"/*; do [[ ${keep[$f]} ]] || drop+=("$f"); done
  ((${#drop[@]})) && rm -f -- "${drop[@]}"
fi
printf '%s\n' "${newWatch[@]}" > "$cache/live.watch"
printf '%s' "$fp" > "$cache/live.fp"
nowMs; printf '%s\n' "$REPLY" > "$stamp"
printf '%s\n' "$result"
