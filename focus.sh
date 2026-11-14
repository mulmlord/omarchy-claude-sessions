#!/bin/bash
# Jump to the Hyprland window hosting the given process: walk up its parents
# until one owns a window, switch to that window's workspace (showing it if
# it lives on a special workspace), then focus the window.
pid=$1
clients=$(hyprctl clients -j)

window=""
while [[ $pid =~ ^[0-9]+$ ]] && ((pid > 1)); do
  window=$(jq -c --argjson pid "$pid" 'first(.[] | select(.pid == $pid)) // empty' <<< "$clients")
  [[ -n $window ]] && break
  { stat=$(< "/proc/$pid/stat"); } 2>/dev/null || exit 1
  read -ra fields <<< "${stat##*) }"   # ppid is the second field after "(comm)"
  pid=${fields[1]}
done
[[ -n $window ]] || exit 1

address=$(jq -r '.address' <<< "$window")
workspace=$(jq -r '.workspace.name' <<< "$window")
workspace_id=$(jq -r '.workspace.id' <<< "$window")

if [[ $workspace == special:* ]]; then
  shown=$(hyprctl monitors -j | jq -r --arg ws "$workspace" 'any(.[]; .specialWorkspace.name == $ws)')
  [[ $shown == true ]] || hyprctl dispatch "hl.dsp.workspace.toggle_special(\"${workspace#special:}\")" > /dev/null
else
  hyprctl dispatch "hl.dsp.focus({ workspace = \"$workspace_id\" })" > /dev/null
fi

exec hyprctl dispatch "hl.dsp.focus({ window = \"address:$address\" })"
