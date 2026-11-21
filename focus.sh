#!/bin/bash
# Jump to the Hyprland window hosting the given process: walk up its parents
# until one owns a window, switch to that window's workspace (showing it if
# it lives on a special workspace), then focus the window.
#
# A session in a herdr pane (HERDR_PANE_ID in its environment) has the herdr
# server as its parent, which owns no window. herdr brings that pane to the
# front instead, and the walk starts from the attached herdr clients; with none
# attached, a herdr window opens on it.
pid=$1
clients=$(hyprctl clients -j)

window_of() {
  local pid=$1 stat fields
  window=""
  while [[ $pid =~ ^[0-9]+$ ]] && ((pid > 1)); do
    window=$(jq -c --argjson pid "$pid" 'first(.[] | select(.pid == $pid)) // empty' <<< "$clients")
    [[ -n $window ]] && return 0
    { stat=$(< "/proc/$pid/stat"); } 2>/dev/null || return 1
    read -ra fields <<< "${stat##*) }"   # ppid is the second field after "(comm)"
    pid=${fields[1]}
  done
  return 1
}

pane="" sock=""
if [[ -r /proc/$pid/environ ]]; then
  while IFS= read -r -d '' var; do
    case $var in
      HERDR_PANE_ID=*) pane=${var#*=} ;;
      HERDR_SOCKET_PATH=*) sock=${var#*=} ;;
    esac
  done < "/proc/$pid/environ"
fi

if [[ -n $pane ]] && command -v herdr > /dev/null; then
  [[ -n $sock ]] && export HERDR_SOCKET_PATH=$sock   # a named herdr session's server
  herdr agent focus "$pane" > /dev/null 2>&1
  for c in $(pgrep -x herdr); do
    mapfile -d '' -t args < "/proc/$c/cmdline" 2>/dev/null || continue
    [[ ${args[1]:-} == server ]] && continue
    window_of "$c" && break
  done
  [[ -n $window ]] || exec omarchy-launch-tui --app-id=org.omarchy.agent herdr
else
  window_of "$pid" || exit 1
fi

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
