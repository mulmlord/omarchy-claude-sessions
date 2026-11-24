# Claude sessions for Omarchy

An [Omarchy](https://omarchy.org) bar widget for [Claude Code](https://claude.com/claude-code). It shows every running session and what it is doing, and has a usage panel in the style of tokscale.

## In the bar

- **Usage gauge**: how much of the 5-hour session limit is used and today's estimated cost. Click it, or run `omarchy-shell mulm.claude-sessions toggle`, to open the usage panel.
- **One pill per session**:
  - yellow spinner + elapsed time: working
  - blue terminal: the turn ended but background shells or monitors are still running
  - purple robot: the turn ended but subagents are still running
  - indigo terminal + robot: both, shells and subagents (the hue halfway between blue and purple)
  - red bell: waiting for you (a permission prompt or other dialog)
  - orange question mark: Claude asks you something, in a question box or at the end of a finished turn (its last message asks a question; questions in code, tables, headings and quotes don't count)
  - green check: done
- A thin line under each pill shows how full the context window is: dim below 70 %, yellow from 70 %, red from 90 %.
- Hover a pill to see its subagents, background tasks and context. Click it to focus the terminal the session runs in; a session in a [herdr](https://herdr.dev) pane gets its space, tab and pane focused in the herdr window (one opens if none is attached).
- When the bar runs out of room, pills shorten step by step, down to one pill per state with a count. They never push into the clock.

## Usage panel

- Subscription limits (5-hour, weekly, per-model weekly), each with a pace marker.
- Today / 7 days / 30 days / all-time tiles.
- Usage per hour or per day, stacked by model.
- Breakdowns by model and by token type, plus a heatmap.
- Every live session with its tokens, cost, messages and estimated share of the 5-hour limit. Its subagents are listed below it.

Keys: `1`–`4` period · `m` cost/tokens · `r` refresh · `t` open tokscale.

## Requirements

- Omarchy with shell plugins (Quickshell bar), Hyprland
- Claude Code
- `jq`, `flock` (util-linux)
- [tokscale](https://www.npmjs.com/package/tokscale) for the usage panel: `npm i -g tokscale`. The session pills work without it.

## Install

```bash
omarchy plugin add https://github.com/mulmlord/omarchy-claude-sessions.git --enable
```

Update with `omarchy plugin update mulm.claude-sessions`.

## Remove

```bash
omarchy plugin remove mulm.claude-sessions
```

This removes the widget from the bar and deletes its folder. Its cache in `~/.cache/mulm.claude-sessions/` stays behind. Delete it by hand if you like, and remove the statusline hook line if you added one.

## Optional: statusline hook

Limits and context window sizes are most accurate when Claude Code's statusline passes them on. Add this to your statusline script:

```bash
input=$(cat)
printf '%s' "$input" | ~/.config/omarchy/plugins/mulm.claude-sessions/statusline-hook.sh
# ... your statusline output ...
```

Without the hook, limits come from tokscale (`tokscale usage`). Context sizes are then guessed: 200k, or 1M once a session passes 200k tokens.

## Settings

Change these in Omarchy's settings panel for the widget:

| Setting | Default | |
|---|---|---|
| Session poll interval | 2000 ms | How often sessions are re-read |
| Usage in bar | Both | Quota, cost, both, or icon only |
| Usage refresh | 120 s | How often tokscale re-reads the transcripts |
| Limits refresh | 60 s | How often limits are re-read |

## Data and network

The widget reads local files only: `~/.claude/sessions/`, `~/.claude/projects/` (respects `CLAUDE_CONFIG_DIR`). It caches in `~/.cache/mulm.claude-sessions/`.

Network access goes only through tokscale. Anthropic's usage endpoint is asked at most every 5–15 minutes, because it rate-limits frequent polling. Model prices are looked up once a week. The bar draws one widget per monitor; all of them share one cached result.

## License

MIT
