import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Claude Code in the bar. A usage button (gauge + session limit + today's
// cost) opens a tokscale-style panel: subscription limits with pace, cost /
// tokens / messages / active time for a period, a per-hour or per-day chart
// stacked by model, the model and token-type breakdown, an activity heatmap
// and the running sessions. Usage comes from tokscale via usage.sh.
//
// Next to it, one indicator per running Claude Code session, read from the
// per-process records in ~/.claude/sessions/. Working sessions spin and show
// how long the turn has run, sessions waiting on you ring in the urgent
// color, sessions asking you something (a question box, or a finished turn
// that ends with a question) show an orange question mark, finished ones
// settle into a green check. Running subagents add a
// robot with their count to the pill. Once the turn has ended, what still runs
// in the background colors the pill: background shells or monitors only
// (status "shell") a blue terminal, subagents only (status "agents") a
// purple robot, both a terminal and robot in the hue halfway between the two
// (shellAgentMix). Hovering the pill lists them numbered with their last tool call, plus
// the background shells and monitors still running. A background job that
// no open session points to gets a pill of its own. A thin line along the pill's
// bottom shows how full the session's context window is (yellow from 70%,
// red from 90%, as the statusline colors it). The panel's session list adds
// each session's context, tokens by type, cost and estimated share of the
// 5-hour limit, and its running subagents with theirs (usage.sh sessions).
// Click a session to focus its terminal, right-click for the usage panel.
//
// IPC: omarchy-shell mulm.claude-sessions toggle
Panel {
  id: root
  moduleName: "mulm.claude-sessions"
  ipcTarget: "mulm.claude-sessions"

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, ""))
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int pollIntervalMs: Math.max(500, Number(setting("pollIntervalMs", 2000)) || 2000)
  readonly property int statsIntervalMs: Math.max(30, Number(setting("statsIntervalSec", 120)) || 120) * 1000
  readonly property int quotaIntervalMs: Math.max(15, Number(setting("quotaIntervalSec", 60)) || 60) * 1000
  readonly property string barLabel: String(setting("barLabel", "Both"))
  readonly property var spinnerFrames: ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

  // Nerd Font glyphs, spelled as code points so no editor or tool mangles them.
  readonly property var glyph: ({
    gauge: String.fromCodePoint(0xF029A),
    check: String.fromCodePoint(0xF012C),
    bell: String.fromCodePoint(0xF009E),
    question: String.fromCodePoint(0xF1738),
    terminal: String.fromCodePoint(0xF018D),
    refresh: String.fromCodePoint(0xF0450),
    loading: String.fromCodePoint(0xF0996),
    chart: String.fromCodePoint(0xF0128),
    robot: String.fromCodePoint(0xF06A9),
    eye: String.fromCodePoint(0xF0208)
  })

  // ---------- sessions ----------
  // [{ pid, sessionId, kind, name, cwd, status, waitingFor, since, context: { tokens, size, pct } | null,
  //    agents: [{ id, type, description, depth, startedAt, action: { tool, detail } | null }],
  //    shells: [{ kind: "shell" | "monitor", description, startedAt }] }]
  // kind "bg" is a background job no open session points to.
  // status is Claude Code's (busy | shell | waiting | idle), or "agents" for an
  // idle session whose subagents are still running.
  property var sessions: []
  property string sessionsSig: ""   // JSON of `sessions`, to skip polls that changed nothing
  // Stands in for a session while a Repeater shrinks and a delegate's index
  // briefly points past the end of the list.
  readonly property var blankSession: ({ pid: 0, sessionId: "", name: "", cwd: "", status: "idle",
                                         waitingFor: "", since: 0, context: null, agents: [] })
  property real nowMs: Date.now()
  property int spinnerFrame: 0
  readonly property bool anyBusy: sessions.some(function(s) { return s.status === "busy" })

  // ---------- usage ----------
  property var stats: ({})          // usage.sh stats
  property var quota: ({})          // usage.sh quota (last non-empty answer)
  property var sessionUsage: ({})   // usage.sh sessions: { windowCost, sessions: { <id>: { all, main, agents } } }
  property string statsError: ""
  property real statsAtMs: 0
  property real quotaAtMs: 0
  property string todayKey: dayKey(new Date())
  property string period: "today"   // today | 7d | 30d | all
  property string metric: "cost"    // chart metric: cost | tokens
  property int hoverBar: -1
  property var hoverDay: null
  readonly property var periods: [
    { value: "today", label: "Today" },
    { value: "7d", label: "7 days" },
    { value: "30d", label: "30 days" },
    { value: "all", label: "All time" }
  ]

  // ---------- colors ----------
  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property color faint: Qt.darker(fg, 1.9)
  readonly property color track: alpha(fg, 0.1)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // The theme's red is the bar's urgent color; the other hues are not exposed,
  // so read them from the theme palette (see pickHue).
  readonly property color red: bar ? bar.urgent : Commons.Color.urgent
  property color yellow: Commons.Color.accent
  property color green: "#8fbf6a"
  property color blue: "#7aa2f7"
  property color orange: "#e0915c"
  property color magenta: "#bb9af7"
  // Background shells and subagents at once: the hue halfway between the
  // shells' blue and the agents' purple.
  readonly property color shellAgentMix: mixHue(blue, magenta)

  // Themes don't agree on which key holds which color (matte-black keeps its
  // amber under `green` and has no green at all), so take the palette entry
  // whose hue is closest to the target, or the fallback when none is close.
  function pickHue(raw, targetHue, tolerance, fallback) {
    var best = null, bestScore = Infinity
    var re = /^\s*([a-z_0-9]+)\s*=\s*"(#[0-9a-fA-F]{6})"/gm, m
    while ((m = re.exec(String(raw || ""))) !== null) {
      var c = Qt.color(m[2])
      if (c.hslHue < 0 || c.hslSaturation < 0.3 || c.hslLightness < 0.35 || c.hslLightness > 0.85) continue
      var d = Math.abs(c.hslHue * 360 - targetHue)
      var score = Math.min(d, 360 - d)
      if (score < bestScore) { bestScore = score; best = c }
    }
    return best && bestScore <= tolerance ? best : fallback
  }

  FileView {
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.yellow = root.pickHue(text(), 48, 20, Commons.Color.accent)
      root.green = root.pickHue(text(), 115, 35, "#8fbf6a")
      root.blue = root.pickHue(text(), 210, 30, "#7aa2f7")
      root.orange = root.pickHue(text(), 22, 14, "#e0915c")
      root.magenta = root.pickHue(text(), 290, 35, "#bb9af7")
    }
  }

  // ---------- helpers ----------
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  // Halfway between two colors along the shorter way around the hue circle,
  // keeping their saturation, so the mix stays as vivid as both (an RGB
  // average of complementary hues turns grey). Gray inputs fall back to RGB.
  function mixHue(a, b) {
    if (a.hslHue < 0 || b.hslHue < 0) return Qt.rgba((a.r + b.r) / 2, (a.g + b.g) / 2, (a.b + b.b) / 2, 1)
    var d = b.hslHue - a.hslHue
    if (d > 0.5) d -= 1
    else if (d < -0.5) d += 1
    var h = a.hslHue + d / 2
    return Qt.hsla(h < 0 ? h + 1 : h, (a.hslSaturation + b.hslSaturation) / 2, (a.hslLightness + b.hslLightness) / 2, 1)
  }
  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  // Values from tokscale end up in Omarchy-owned sinks (tooltips, buttons)
  // whose text format the plugin can't set, so strip markup-shaped characters.
  function plain(s, max) {
    var t = String(s === undefined || s === null ? "" : s).replace(/[<>&]/g, "")
    return t.length > max ? t.slice(0, max - 1) + "…" : t
  }

  function num(v, decimals) { return Commons.I18n.formatNumber(v, decimals) }
  function grouped(v) {
    var digits = num(Math.round(Number(v) || 0), 0)
    var sep = Commons.I18n.decimal === "," ? "." : ","
    return digits.replace(/\B(?=(\d{3})+(?!\d))/g, sep)
  }
  function money(v) {
    v = Number(v) || 0
    return "$" + (v >= 1000 ? grouped(v) : num(v, v >= 100 ? 0 : 2))
  }
  function tokens(v) {
    v = Number(v) || 0
    if (v >= 1e9) return num(v / 1e9, 2) + "B"
    if (v >= 1e6) return num(v / 1e6, 1) + "M"
    if (v >= 1e3) return num(v / 1e3, 1) + "K"
    return num(v, 0)
  }
  function duration(ms) {
    var min = Math.round(Math.max(0, Number(ms) || 0) / 60000)
    if (min < 60) return min + "m"
    if (min < 60 * 48) return Math.floor(min / 60) + "h " + String(min % 60).padStart(2, "0") + "m"
    return Math.floor(min / 1440) + "d " + Math.floor((min % 1440) / 60) + "h"
  }
  function elapsed(ms) {
    var sec = Math.max(0, Math.floor(ms / 1000))
    if (sec < 60) return sec + "s"
    var min = Math.floor(sec / 60)
    if (min < 60) return min + "m"
    var h = Math.floor(min / 60)
    return h + "h" + String(min % 60).padStart(2, "0")
  }
  function ago(ms) {
    if (!ms) return "never"
    var sec = Math.max(0, Math.floor((nowMs - ms) / 1000))
    if (sec < 60) return "just now"
    if (sec < 3600) return Math.floor(sec / 60) + "m ago"
    return Math.floor(sec / 3600) + "h ago"
  }

  function dayKey(date) { return Qt.formatDate(date, "yyyy-MM-dd") }
  function dateOf(key) { return new Date(key + "T12:00:00") }
  function shiftDays(key, n) {
    var d = dateOf(key)
    return dayKey(new Date(d.getFullYear(), d.getMonth(), d.getDate() + n, 12))
  }
  function locale() { return Qt.locale(Commons.I18n.formatLocale) }
  function shortDate(key) { return key === todayKey ? "today" : dateOf(key).toLocaleDateString(locale(), "MMM d") }
  function longDate(key) { return dateOf(key).toLocaleDateString(locale(), "ddd, MMM d yyyy") }

  function modelName(id) {
    var s = String(id || "")
    var m = s.match(/^claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?$/)
    if (m) return m[1].charAt(0).toUpperCase() + m[1].slice(1) + " " + m[2] + (m[3] !== undefined ? "." + m[3] : "")
    m = s.match(/^claude-(\d+)(?:-(\d{1,2}))?-([a-z]+)(?:-\d{8})?$/)
    if (m) return m[3].charAt(0).toUpperCase() + m[3].slice(1) + " " + m[1] + (m[2] !== undefined ? "." + m[2] : "")
    return plain(s, 28)
  }
  function modelColor(id) {
    var s = String(id || "")
    if (s.indexOf("opus") >= 0) return orange
    if (s.indexOf("sonnet") >= 0) return blue
    if (s.indexOf("haiku") >= 0) return green
    if (s.indexOf("fable") >= 0) return magenta
    return yellow
  }
  function levelColor(level) {
    if (!level) return alpha(fg, 0.08)
    return alpha(blue, [0.3, 0.5, 0.75, 1.0][Math.min(4, level) - 1])
  }
  function limitColor(used) { return used >= 0.9 ? red : (used >= 0.7 ? yellow : fg) }
  function meterColor(used) { return used >= 0.9 ? red : (used >= 0.7 ? yellow : orange) }
  function resetLabel(ms) {
    if (!isFinite(ms)) return ""
    var left = ms - nowMs
    if (left <= 0) return "resetting"
    if (left < 86400000) return "resets in " + duration(left)
    return "resets " + new Date(ms).toLocaleString(locale(), "ddd HH:mm")
  }

  // ---------- derived usage ----------
  readonly property var dayMap: {
    var map = {}
    var days = stats && Array.isArray(stats.days) ? stats.days : []
    for (var i = 0; i < days.length; i++) map[days[i].d] = days[i]
    return map
  }
  readonly property var timeMetrics: stats && stats.time ? stats.time : ({})

  // Calendar days of the selected period, oldest first; days without usage
  // stay in the list so the chart keeps its gaps.
  readonly property var periodKeys: {
    var count = period === "today" ? 1 : (period === "7d" ? 7 : (period === "30d" ? 30 : 0))
    if (count === 0) {
      var keys = Object.keys(dayMap).sort()
      count = keys.length === 0 ? 1 : Math.max(1, Math.round((dateOf(todayKey) - dateOf(keys[0])) / 86400000) + 1)
    }
    var list = []
    for (var i = count - 1; i >= 0; i--) list.push(shiftDays(todayKey, -i))
    return list
  }

  readonly property var totals: {
    var t = { c: 0, t: 0, m: 0, a: 0, days: 0, b: [0, 0, 0, 0], models: {} }
    for (var i = 0; i < periodKeys.length; i++) {
      var d = dayMap[periodKeys[i]]
      if (!d) continue
      t.c += d.c; t.t += d.t; t.m += d.m; t.a += d.a
      if (d.t > 0) t.days++
      for (var j = 0; j < 4; j++) t.b[j] += Number(d.b[j]) || 0
      for (var id in d.mo) {
        var x = t.models[id] || (t.models[id] = { c: 0, t: 0, m: 0 })
        x.c += d.mo[id].c; x.t += d.mo[id].t; x.m += d.mo[id].m
      }
    }
    return t
  }

  // All-time cost order, so a model keeps its place in the stacks across periods.
  readonly property var modelOrder: {
    var sum = {}
    for (var k in dayMap) for (var id in dayMap[k].mo) sum[id] = (sum[id] || 0) + dayMap[k].mo[id].c
    return Object.keys(sum).sort(function(a, b) { return sum[b] - sum[a] })
  }

  readonly property var modelRows: {
    var rows = []
    for (var id in totals.models) {
      var x = totals.models[id]
      rows.push({ id: id, name: modelName(id), color: modelColor(id), c: x.c, t: x.t, m: x.m,
                  share: totals.c > 0 ? x.c / totals.c : (totals.t > 0 ? x.t / totals.t : 0) })
    }
    rows.sort(function(a, b) { return b.c - a.c || b.t - a.t })
    return rows
  }

  // Chart bars: 24 hours for today (tokscale has no per-model split per
  // hour), one bar per day otherwise, one per week past ~two months.
  readonly property var bars: {
    var out = []
    if (period === "today") {
      var hours = stats && Array.isArray(stats.hours) ? stats.hours : []
      var byHour = {}
      for (var i = 0; i < hours.length; i++) byHour[hours[i].h] = hours[i]
      var hourColor = modelRows.length === 1 ? modelRows[0].color : yellow
      for (var h = 0; h < 24; h++) {
        var e = byHour[h] || { c: 0, t: 0, m: 0 }
        var hh = String(h).padStart(2, "0") + ":00"
        out.push({ label: hh, short: hh, c: e.c, t: e.t, m: e.m,
                   segs: e.t > 0 ? [{ color: hourColor, c: e.c, t: e.t }] : [] })
      }
      return out
    }
    var keys = periodKeys
    var step = keys.length > 62 ? 7 : 1
    for (var s = keys.length; s > 0; s -= step) {
      var chunk = keys.slice(Math.max(0, s - step), s)
      var bar = { c: 0, t: 0, m: 0, segs: [],
                  label: chunk.length === 1 ? longDate(chunk[0]) : shortDate(chunk[0]) + " – " + shortDate(chunk[chunk.length - 1]),
                  short: shortDate(chunk[0]) }
      var per = {}
      for (var q = 0; q < chunk.length; q++) {
        var d = dayMap[chunk[q]]
        if (!d) continue
        bar.c += d.c; bar.t += d.t; bar.m += d.m
        for (var id in d.mo) {
          var p = per[id] || (per[id] = { c: 0, t: 0 })
          p.c += d.mo[id].c; p.t += d.mo[id].t
        }
      }
      bar.segs = modelOrder.filter(function(id) { return per[id] }).map(function(id) {
        return { color: modelColor(id), c: per[id].c, t: per[id].t }
      })
      out.unshift(bar)
    }
    return out
  }
  readonly property real barMax: bars.reduce(function(m, b) { return Math.max(m, metric === "cost" ? b.c : b.t) }, 0)
  readonly property int peakBar: {
    var best = -1, v = 0
    for (var i = 0; i < bars.length; i++) {
      var x = metric === "cost" ? bars[i].c : bars[i].t
      if (x > v) { v = x; best = i }
    }
    return best
  }

  readonly property var quotaRows: {
    var list = quota && Array.isArray(quota.metrics) ? quota.metrics : []
    return list.slice(0, 6).map(function(q) {
      var label = plain(q.label, 24)
      return { label: label, used: clamp((Number(q.used) || 0) / 100, 0, 1), resetsMs: Number(q.resetsMs) || Date.parse(q.resets),
               windowMs: /session/i.test(label) ? 5 * 3600000 : 7 * 86400000 }
    })
  }
  readonly property var sessionLimit: quotaRows.filter(function(q) { return /session/i.test(q.label) })[0] || null
  readonly property bool limitHot: sessionLimit !== null && sessionLimit.used >= 0.7
  readonly property real todayCost: dayMap[todayKey] ? dayMap[todayKey].c : 0

  readonly property int streak: {
    var n = 0
    for (var i = 0; i < 3660; i++) {
      var d = dayMap[shiftDays(todayKey, -i)]
      if (d && d.t > 0) n++
      else if (i > 0) break   // no usage yet today doesn't end the streak
    }
    return n
  }

  // 53 weeks ending this week, Monday first; the view shows as many as fit.
  readonly property var heatWeeks: {
    var today = dateOf(todayKey)
    var monday = shiftDays(todayKey, -((today.getDay() + 6) % 7) - 52 * 7)
    var weeks = []
    for (var w = 0; w < 53; w++) {
      var col = []
      for (var wd = 0; wd < 7; wd++) {
        var k = shiftDays(monday, w * 7 + wd)
        if (k > todayKey) break
        var d = dayMap[k]
        col.push({ d: k, wd: wd, l: d ? d.l : 0, c: d ? d.c : 0, t: d ? d.t : 0, m: d ? d.m : 0 })
      }
      weeks.push(col)
    }
    return weeks
  }

  // ---------- bar text ----------
  readonly property string usageText: {
    var parts = [glyph.gauge]
    if ((barLabel === "Both" || barLabel === "Quota") && sessionLimit) parts.push(Math.round(sessionLimit.used * 100) + "%")
    if ((barLabel === "Both" || barLabel === "Cost") && statsAtMs > 0) parts.push("$" + Math.round(todayCost))
    return parts.join(" ")
  }
  readonly property color usageColor: limitHot ? limitColor(sessionLimit.used) : barForeground
  readonly property string usageTooltip: {
    var lines = ["Claude usage"]
    for (var i = 0; i < quotaRows.length; i++) {
      var q = quotaRows[i]
      lines.push(q.label + " " + Math.round(q.used * 100) + "% used · " + resetLabel(q.resetsMs))
    }
    var d = dayMap[todayKey]
    lines.push("Today " + money(d ? d.c : 0) + " · " + tokens(d ? d.t : 0) + " tokens · " + (d ? d.m : 0) + " messages")
    if (statsError !== "") lines.push("tokscale: " + statsError)
    lines.push("Click: usage panel · Right-click: refresh")
    return lines.join("\n")
  }

  // ---------- data ----------
  function applySessions(text) {
    var list
    try { list = JSON.parse(String(text || "[]")) } catch (e) { return }
    if (!Array.isArray(list)) return

    // statusUpdatedAt is the last write that carried a status, so carry our own
    // "since" forward while a session stays in the same state.
    var previous = {}
    for (var i = 0; i < sessions.length; i++) previous[sessions[i].sessionId] = sessions[i]
    var next = []
    for (var j = 0; j < list.length; j++) {
      var s = list[j]
      var old = previous[s.sessionId]
      var agents = (Array.isArray(s.agents) ? s.agents : []).slice(0, 24).map(function(a) {
        var act = a.action && a.action.tool ? { tool: plain(a.action.tool, 24), detail: plain(a.action.detail, 60) } : null
        return { id: String(a.id || ""), type: plain(a.type, 24) || "agent", description: plain(a.description, 64),
                 depth: clamp(Number(a.depth) || 1, 1, 4), startedAt: Number(a.startedAt) || Date.now(), action: act }
      })
      var shells = (Array.isArray(s.shells) ? s.shells : []).slice(0, 24).map(function(b) {
        return { kind: b.kind === "monitor" ? "monitor" : "shell", description: plain(b.description, 64),
                 startedAt: Number(b.startedAt) || Date.now() }
      })
      var status = String(s.status || "idle")
      // Claude Code's "shell" means something still runs in the background;
      // if that is only subagents, show it as such.
      if ((status === "idle" || (status === "shell" && shells.length === 0)) && agents.length > 0) status = "agents"
      var ctx = s.context && Number(s.context.size) > 0
        ? { tokens: Number(s.context.tokens) || 0, size: Number(s.context.size), pct: clamp(Math.floor(Number(s.context.pct) || 0), 0, 100) }
        : null
      next.push({
        context: ctx,
        pid: s.pid,
        sessionId: s.sessionId,
        name: s.name || String(s.cwd || "").split("/").pop() || "claude",
        cwd: String(s.cwd || ""),
        kind: s.kind === "bg" ? "bg" : "interactive",
        status: status,
        waitingFor: s.waitingFor || "",
        agents: agents,
        shells: shells,
        since: old && old.status === status ? old.since : (Number(s.statusUpdatedAt) || Date.now())
      })
    }
    nowMs = Date.now()
    var sig = JSON.stringify(next)
    if (sig === sessionsSig) return
    sessionsSig = sig
    sessions = next
  }

  function applyStats(text) {
    var data
    try { data = JSON.parse(String(text || "{}")) } catch (e) { statsError = "unreadable output"; return }
    if (!data || data.error || !Array.isArray(data.days)) {
      statsError = data && data.error ? plain(data.error, 80) : "no data"
      return
    }
    var days = data.days.filter(function(d) { return d && /^\d{4}-\d{2}-\d{2}$/.test(String(d.d)) }).slice(-1200).map(function(d) {
      var mo = {}, n = 0
      for (var id in (d.mo || {})) {
        if (++n > 24) break
        var x = d.mo[id] || {}
        mo[plain(id, 64)] = { c: Number(x.c) || 0, t: Number(x.t) || 0, m: Number(x.m) || 0 }
      }
      var b = Array.isArray(d.b) ? d.b : []
      return { d: String(d.d), c: Number(d.c) || 0, t: Number(d.t) || 0, m: Number(d.m) || 0, a: Number(d.a) || 0,
               l: clamp(Math.round(Number(d.l) || 0), 0, 4), b: [0, 1, 2, 3].map(function(i) { return Number(b[i]) || 0 }), mo: mo }
    })
    var hours = (Array.isArray(data.hours) ? data.hours : []).slice(0, 48).map(function(h) {
      return { h: clamp(Math.round(Number(h.h) || 0), 0, 23), c: Number(h.c) || 0, t: Number(h.t) || 0, m: Number(h.m) || 0 }
    })
    var t = data.time || {}
    stats = { days: days, hours: hours, time: {
      totalActiveTimeMs: Number(t.totalActiveTimeMs) || 0, longestContinuousMs: Number(t.longestContinuousMs) || 0,
      maxConcurrentSessions: Number(t.maxConcurrentSessions) || 0, sessionCount: Number(t.sessionCount) || 0 } }
    statsError = ""
    statsAtMs = Date.now()
  }

  function applyQuota(text) {
    var data
    try { data = JSON.parse(String(text || "{}")) } catch (e) { return }
    // tokscale answers [] during its cooldown; keep the last good reading.
    if (!data || !Array.isArray(data.metrics) || data.metrics.length === 0) {
      if (quotaAtMs === 0) quotaRetry.restart()
      return
    }
    quota = { plan: plain(data.plan, 24), metrics: data.metrics }
    quotaAtMs = Number(data.at) || Date.now()
  }

  function applySessionUsage(text) {
    var data
    try { data = JSON.parse(String(text || "{}")) } catch (e) { return }
    if (!data || typeof data.sessions !== "object" || data.sessions === null) return
    sessionUsage = { windowCost: Number(data.windowCost) || 0, sessions: data.sessions }
  }

  // usage.sh caches across the per-monitor instances; maxAge (seconds) is how
  // old a shared answer may be. 0 forces a fresh tokscale run. Limits come
  // from the statusline file when it is fresh; usage.sh asks Anthropic's
  // endpoint at most every 5 minutes (15 while the statusline is live).
  function refreshStats(maxAge) {
    if (statsProc.running) return
    statsProc.command = [root.pluginDir + "/usage.sh", "stats", String(maxAge === undefined ? 60 : maxAge)]
    statsProc.running = true
  }
  function refreshQuota(maxAge) {
    if (quotaProc.running) return
    quotaProc.command = [root.pluginDir + "/usage.sh", "quota", String(maxAge === undefined ? 300 : maxAge)]
    quotaProc.running = true
  }
  // Per-session usage is only shown in the panel. The window start lets
  // usage.sh tell what each session spent inside the current 5-hour window.
  function refreshSessionUsage(maxAge) {
    if (sessionUsageProc.running) return
    var lim = sessionLimit
    var ws = lim && lim.resetsMs > Date.now() ? Math.floor((lim.resetsMs - 5 * 3600000) / 1000) : 0
    sessionUsageProc.command = [root.pluginDir + "/usage.sh", "sessions", String(maxAge), String(ws)]
    sessionUsageProc.running = true
  }
  function refreshAll() { refreshStats(0); refreshQuota(60); refreshSessionUsage(0) }

  function setPeriod(p) { period = p; hoverBar = -1 }
  function cyclePeriod(dx) {
    var i = periods.map(function(p) { return p.value }).indexOf(period)
    setPeriod(periods[(i + dx + periods.length) % periods.length].value)
  }
  function openTokscale() {
    launchProc.command = ["omarchy-launch-tui", "tokscale"]
    launchProc.running = true
    close()
  }
  function focusSession(pid) {
    focusProc.command = [root.pluginDir + "/focus.sh", String(pid)]
    focusProc.running = true
  }
  function handleKey(t) {
    if (t >= "1" && t <= "4") setPeriod(periods[Number(t) - 1].value)
    else if (t === "m") metric = metric === "cost" ? "tokens" : "cost"
    else if (t === "r") refreshAll()
    else if (t === "t") openTokscale()
  }

  onOpenedChanged: {
    if (!opened) return
    hoverBar = -1
    hoverDay = null
    flick.contentY = 0
    refreshStats(30)
    refreshQuota(120)
  }

  // ---------- session glyphs ----------
  function stateLabel(s) {
    if (s.status === "busy") return "working for " + elapsed(nowMs - s.since)
    if (s.status === "waiting") return "waiting for you" + (s.waitingFor ? " (" + s.waitingFor + ")" : "") + " for " + elapsed(nowMs - s.since)
    if (s.status === "asking") return (s.waitingFor ? "question box open" : "asked you a question") + " for " + elapsed(nowMs - s.since)
    if (s.status === "shell") return "background shells/monitors running for " + elapsed(nowMs - s.since)
    if (s.status === "agents") return "subagents running for " + elapsed(nowMs - s.since)
    return "done " + elapsed(nowMs - s.since) + " ago"
  }
  // Robot + count after the status glyph; an "agents" session already shows the robot.
  function agentBadge(s) {
    var n = s.agents ? s.agents.length : 0
    if (n === 0) return ""
    // The glyph is wider than its advance and would cover a digit right after it.
    return (s.status === "agents" ? " " : " " + glyph.robot + " ") + n
  }
  // Numbered tooltip lines for a session's running subagents.
  function agentLines(s, indent) {
    var list = s.agents || []
    if (list.length === 0) return []
    var pad = indent || ""
    var lines = [pad + glyph.robot + " " + list.length + (list.length === 1 ? " subagent" : " subagents") + " running"]
    for (var i = 0; i < list.length; i++) {
      var a = list[i]
      lines.push(pad + "  ".repeat(a.depth) + (i + 1) + ". " + (a.description || a.type)
                 + " · " + a.type + " · " + elapsed(nowMs - a.startedAt) + actionText(a.action, " — "))
    }
    return lines
  }
  // An agent's last tool call: "Bash: run the tests".
  function actionText(act, prefix) {
    return act ? (prefix || "") + act.tool + (act.detail ? ": " + act.detail : "") : ""
  }
  // Numbered tooltip lines for a session's background shells and monitors.
  function shellLines(s, indent) {
    var list = s.shells || []
    if (list.length === 0) return []
    var pad = indent || ""
    var monitors = list.filter(function(b) { return b.kind === "monitor" }).length
    var shellCount = list.length - monitors
    var parts = []
    if (shellCount > 0) parts.push(shellCount + (shellCount === 1 ? " shell" : " shells"))
    if (monitors > 0) parts.push(monitors + (monitors === 1 ? " monitor" : " monitors"))
    var lines = [pad + glyph.terminal + " " + parts.join(" + ") + " in the background"]
    for (var i = 0; i < list.length; i++) {
      var b = list[i]
      lines.push(pad + "  " + (i + 1) + ". " + (b.kind === "monitor" ? glyph.eye + " " : "")
                 + (b.description || b.kind) + " · " + elapsed(nowMs - b.startedAt))
    }
    return lines
  }
  // ---------- context window ----------
  function contextColor(pct) { return pct >= 90 ? red : (pct >= 70 ? yellow : dim) }
  function contextLabel(c) {
    return c ? "context " + c.pct + "% · " + tokens(c.tokens) + " / " + tokens(c.size) + " tokens" : ""
  }
  // A pill's context: its session's, or for a group pill its fullest member's.
  function contextOf(item) {
    if (!item || !item.group) return item ? item.context : null
    var best = null
    for (var i = 0; i < item.members.length; i++) {
      var c = item.members[i].context
      if (c && (!best || c.pct > best.pct)) best = c
    }
    return best
  }

  function sessionTooltip(s) {
    return [s.name + " — " + (s.kind === "bg" ? "background job, " : "") + stateLabel(s),
            s.cwd.replace(/^\/home\/[^\/]+/, "~")]
      .concat(s.context ? [contextLabel(s.context)] : [])
      .concat(agentLines(s))
      .concat(shellLines(s))
      .concat(["Click: focus · Right-click: usage"]).join("\n")
  }

  // ---------- per-session usage ----------
  readonly property real sessionGutter: Style.space(16)
  function sessionUsageOf(sid) {
    return sessionUsage.sessions && sessionUsage.sessions[sid] || null
  }
  function agentUsageOf(u, id) {
    return u && u.agents && u.agents[id] || null
  }
  function tokenTotal(u) {
    var t = u && Array.isArray(u.t) ? u.t : []
    return (Number(t[0]) || 0) + (Number(t[1]) || 0) + (Number(t[2]) || 0) + (Number(t[3]) || 0)
  }
  function tokenTypesText(u) {
    var t = u && Array.isArray(u.t) ? u.t : []
    return "cache read " + tokens(t[2]) + " · cache write " + tokens(t[3]) + " · output " + tokens(t[1]) + " · input " + tokens(t[0])
  }
  // Anthropic reports the 5-hour limit only for the whole account, so a
  // session's share is the limit used times its part of the window's cost.
  // Usage outside this machine's Claude Code lands on the local sessions.
  function limitShare(u) {
    var lim = sessionLimit
    var total = Number(sessionUsage.windowCost) || 0
    if (!u || !lim || !(lim.resetsMs > nowMs) || total <= 0) return -1
    return lim.used * (Number(u.wc) || 0) / total
  }
  function percent(share) {
    var v = share * 100
    return num(v, v > 0 && v < 10 ? 1 : 0) + "%"
  }
  function project(s, max) {
    var limit = max || 18
    var name = s.cwd.split("/").filter(function(part) { return part !== "" }).pop() || s.name
    return name.length > limit ? name.slice(0, limit - 1) + "…" : name
  }
  function statusGlyph(s) {
    if (s.status === "busy") return spinnerFrames[spinnerFrame]
    if (s.status === "waiting") return glyph.bell
    if (s.status === "asking") return glyph.question
    if (s.status === "shell") return glyph.terminal
    if (s.status === "agents") return glyph.robot
    return glyph.check
  }

  // ---------- compaction ----------
  // The right section grows toward the clock, and the bar does not stop it,
  // so with many sessions the pills ran over the clock and the widgets beside
  // it. Each tick the widget measures the gap between its right edge and the
  // end of the center sections, and takes the least compact level whose
  // pills fit there:
  //   0–13 project names shorten one character per level (18 → 5) ·
  //   14 done sessions drop their name · 15 only waiting and asking sessions keep one ·
  //   16 icons only · 17 one pill per state with a count
  readonly property int nameLevels: 13
  readonly property int groupLevel: nameLevels + 4
  readonly property int maxCompactLevel: groupLevel
  property int compactLevel: 0
  property var centerSections: null
  readonly property var statusOrder: ["waiting", "asking", "busy", "shell", "agents", "idle"]
  readonly property var pillModel: compactLevel >= groupLevel ? groupSessions(sessions) : sessions

  function groupSessions(list) {
    var out = []
    for (var i = 0; i < statusOrder.length; i++) {
      var members = list.filter(function(s) { return s.status === statusOrder[i] })
      if (members.length > 0) out.push({ group: true, status: statusOrder[i], members: members })
    }
    return out
  }

  function sessionTextAt(s, level) {
    if (s.group) return statusGlyph(s) + " " + s.members.length
    var g = statusGlyph(s) + agentBadge(s)
    var timed = s.status === "busy" || s.status === "shell" || s.status === "agents"
    var time = timed ? " " + elapsed(nowMs - s.since) : ""
    var name = " " + project(s, 18 - Math.min(level, nameLevels))
    if (level >= nameLevels + 3) return g
    if (level >= nameLevels + 2) return s.status === "waiting" || s.status === "asking" ? g + name : g + time
    if (level >= nameLevels + 1 && s.status === "idle") return g
    return g + time + name
  }
  function sessionText(s) { return sessionTextAt(s, compactLevel) }

  function pillWidth(text) {
    // WidgetButton: label width + its margin on both sides; +2 for rounding.
    return Math.max(12, pillMetrics.advanceWidth(text) + Style.spaceReal(7) * 2) + 2
  }
  function rowWidth(level) {
    var list = level >= groupLevel ? groupSessions(sessions) : sessions
    var w = 0
    for (var i = 0; i < list.length; i++) w += pillWidth(sessionTextAt(list[i], level))
    return w
  }

  // The bar's CenterSections in this window that is drawn in the middle of
  // the bar (the other copy sits beside the right section for a notch).
  function findCenterSections() {
    var top = root
    while (top.parent) top = top.parent
    var stack = [top]
    for (var n = 0; stack.length > 0 && n < 4000; n++) {
      var it = stack.pop()
      if (it !== root && ("besideRight" in it) && ("boxStart" in it) && it.active && !it.besideRight) return it
      var kids = it.children || []
      for (var i = 0; i < kids.length; i++) stack.push(kids[i])
    }
    return null
  }

  // Pixels the session pills may take before they touch the center sections.
  function freeRoom() {
    if (vertical || !root.visible) return Infinity
    var cs = centerSections
    if (!cs || !cs.active || cs.besideRight) cs = centerSections = findCenterSections()
    if (!cs) return Infinity
    var end = -Infinity
    for (var i = 0; i < cs.children.length; i++) {
      var c = cs.children[i]
      if (!c.visible || c.width <= 0) continue
      end = Math.max(end, cs.mapToItem(null, c.x + c.width, 0).x)
    }
    if (end === -Infinity) return Infinity
    var mine = root.mapToItem(null, root.width, 0).x
    return mine - end - Style.spaceReal(14) - usageButton.width
  }

  // Compacts at once when the row no longer fits, but only relaxes once the
  // looser level fits with some slack, so a timer going from 59s to 1m does
  // not flip the level back and forth.
  function updateCompact() {
    if (sessions.length === 0) { compactLevel = 0; return }
    var room = freeRoom()
    var slack = Style.spaceReal(24)
    var fit = 0
    while (fit < maxCompactLevel && rowWidth(fit) > room) fit++
    if (fit >= compactLevel) { compactLevel = fit; return }
    var relaxed = fit
    while (relaxed < maxCompactLevel && rowWidth(relaxed) > room - slack) relaxed++
    compactLevel = Math.min(compactLevel, relaxed)
  }
  onNowMsChanged: updateCompact()

  FontMetrics {
    id: pillMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }
  function hasAgents(s) {
    if (s.group) return s.members.some(function(m) { return m.agents && m.agents.length > 0 })
    return !!s.agents && s.agents.length > 0
  }
  function statusColor(s) {
    if (s.status === "busy") return yellow
    if (s.status === "shell") return hasAgents(s) ? shellAgentMix : blue
    if (s.status === "agents") return magenta
    if (s.status === "waiting") return red
    if (s.status === "asking") return orange
    return green
  }

  // ---------- processes & timers ----------
  Process {
    id: poll
    command: [root.pluginDir + "/sessions.sh"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySessions(text)
    }
  }

  Process {
    id: statsProc
    command: [root.pluginDir + "/usage.sh", "stats", "60"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStats(text)
    }
  }

  Process {
    id: quotaProc
    command: [root.pluginDir + "/usage.sh", "quota", "300"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyQuota(text)
    }
  }

  Process {
    id: sessionUsageProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySessionUsage(text)
    }
  }

  Process { id: focusProc }
  Process { id: launchProc }

  Timer {
    interval: root.pollIntervalMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!poll.running) poll.running = true
  }

  Timer {
    interval: root.statsIntervalMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshStats()
  }

  Timer {
    interval: root.quotaIntervalMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshQuota()
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshSessionUsage(20)
  }

  // The first quota call can land in tokscale's cooldown; keep trying each
  // minute until a first reading arrives.
  Timer {
    id: quotaRetry
    interval: 65000
    onTriggered: root.refreshQuota()
  }

  Timer {
    interval: root.sessions.length > 0 || root.opened ? 1000 : 30000
    running: true
    repeat: true
    onTriggered: {
      root.nowMs = Date.now()
      var k = root.dayKey(new Date())
      if (k !== root.todayKey) { root.todayKey = k; root.refreshStats(0) }
    }
  }

  // Every frame redraws each bar window (one per monitor), whatever the
  // number of busy pills: at 120 ms that cost ~4% of a core all day long
  // (measured 2026-11-06), at 250 ms about 1.5%.
  Timer {
    interval: 250
    running: root.anyBusy && root.visible
    repeat: true
    onTriggered: root.spinnerFrame = (root.spinnerFrame + 1) % root.spinnerFrames.length
  }

  // ---------- bar ----------
  implicitWidth: grid.implicitWidth
  implicitHeight: grid.implicitHeight

  Grid {
    id: grid
    anchors.centerIn: parent
    columns: root.vertical ? 1 : Math.max(1, root.pillModel.length + 1)
    spacing: 0

    // The model is the count, not the array: a new array every poll would
    // make the Repeater destroy and rebuild every pill, which also cut the
    // width easing short; this way the pills stay and only their bindings
    // re-evaluate.
    Repeater {
      model: root.pillModel.length

      // The pill's width eases to its label's, so a label that changes
      // (a new compaction level, a timer gaining a digit) slides the row
      // instead of jumping; clip keeps the wider label inside meanwhile.
      Item {
        id: pill
        required property int index
        readonly property var modelData: root.pillModel[index] || root.blankSession
        readonly property bool grouped: !!modelData.group

        implicitWidth: button.implicitWidth
        implicitHeight: button.implicitHeight
        clip: true

        Behavior on implicitWidth {
          enabled: !root.vertical
          NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutCubic }
        }

        WidgetButton {
          id: button
          anchors.centerIn: parent
          bar: root.bar
          text: root.sessionText(pill.modelData)
          horizontalMargin: 7
          foreground: pill.modelData.status === "waiting" ? root.green : root.statusColor(pill.modelData)
          activeColor: root.red
          active: pill.modelData.status === "waiting"
          tooltipText: pill.grouped
            ? pill.modelData.members.map(function(s) {
                return [root.project(s) + " — " + root.stateLabel(s) + (s.context ? " · context " + s.context.pct + "%" : "")]
                  .concat(root.agentLines(s, "  ")).concat(root.shellLines(s, "  ")).join("\n")
              }).join("\n")
              + (pill.modelData.members.length === 1 ? "\nClick: focus · Right-click: usage" : "\nClick or right-click: usage")
            : root.sessionTooltip(pill.modelData)
          onPressed: function(button) {
            if (button === Qt.RightButton) root.toggle()
            else if (button !== Qt.LeftButton) return
            else if (!pill.grouped) root.focusSession(pill.modelData.pid)
            else if (pill.modelData.members.length === 1) root.focusSession(pill.modelData.members[0].pid)
            else root.toggle()
          }
        }

        // Context window fill along the pill's bottom edge, under the label.
        Item {
          readonly property var ctx: root.contextOf(pill.modelData)
          readonly property real fill: ctx ? ctx.pct / 100 : 0
          visible: !!ctx && !root.vertical
          x: Style.spaceReal(7)
          width: Math.max(0, pill.width - 2 * x)
          height: 2
          y: pill.height - height - Style.spaceReal(3)

          Rectangle { anchors.fill: parent; radius: 1; color: root.track }
          Rectangle {
            width: parent.width * parent.fill
            height: parent.height
            radius: 1
            color: root.contextColor(parent.ctx ? parent.ctx.pct : 0)
            Behavior on width { NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutCubic } }
          }
        }
      }
    }

    // Declared after the Repeater, so it sits right of the session indicators.
    WidgetButton {
      id: usageButton
      bar: root.bar
      text: root.usageText
      horizontalMargin: 7
      foreground: root.usageColor
      tooltipText: root.opened ? "" : root.usageTooltip
      onPressed: function(button) {
        if (button === Qt.RightButton) root.refreshAll()
        else root.toggle()
      }
    }
  }

  // ---------- popup ----------
  KeyboardPanel {
    id: panel
    anchorItem: usageButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(470))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.cyclePeriod(dx)
        if (dy !== 0) flick.contentY = root.clamp(flick.contentY + dy * Style.space(56), 0, Math.max(0, flick.contentHeight - flick.height))
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { root.handleKey(t) }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: column
          width: flick.width
          spacing: Style.space(14)

          // ---------- hero ----------
          PanelHero {
            foreground: root.fg
            fontFamily: root.fontFamily
            title: "Claude usage"
            meta: root.statsError !== "" && root.statsAtMs === 0 ? "tokscale: " + root.statsError
              : (root.statsAtMs === 0 ? "loading…" : "updated " + root.ago(root.statsAtMs))
            detail: root.quota.plan || ""
            iconComponent: Component {
              PlainLabel {
                text: root.glyph.gauge
                color: root.limitHot ? root.usageColor : root.orange
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              PanelActionButton {
                iconText: statsProc.running || quotaProc.running ? root.glyph.loading : root.glyph.refresh
                tooltipText: "Refresh (r)"
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: root.refreshAll()
              }
            }
          }

          // ---------- limits ----------
          Column {
            width: parent.width
            spacing: Style.space(12)
            visible: root.quotaRows.length > 0

            Item {
              width: parent.width
              implicitHeight: limitsHeader.implicitHeight

              PanelSectionHeader {
                id: limitsHeader
                text: "LIMITS"
                foreground: root.fg
                fontFamily: root.fontFamily
              }

              PlainLabel {
                anchors.right: parent.right
                anchors.verticalCenter: limitsHeader.verticalCenter
                text: "checked " + root.ago(root.quotaAtMs)
                color: root.nowMs - root.quotaAtMs > 900000 ? root.yellow : root.faint
                font.pixelSize: Style.font.caption
              }
            }

            Repeater {
              model: root.quotaRows

              LimitRow {
                required property var modelData
                width: parent.width
                limit: modelData
              }
            }

            // Legend for the two bars in each meter.
            Row {
              spacing: Style.space(14)

              Repeater {
                model: [
                  { label: "used", color: root.orange, gradient: true },
                  { label: "window elapsed", color: root.alpha(root.fg, 0.16), gradient: false }
                ]

                Row {
                  required property var modelData
                  spacing: Style.space(6)

                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(16)
                    height: Style.space(6)
                    radius: height / 2
                    color: modelData.color
                    gradient: modelData.gradient ? legendGradient : null

                    Gradient {
                      id: legendGradient
                      orientation: Gradient.Horizontal
                      GradientStop { position: 0; color: root.alpha(root.orange, 0.6) }
                      GradientStop { position: 1; color: root.orange }
                    }
                  }
                  PlainLabel {
                    text: modelData.label
                    color: root.dim
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              PlainLabel {
                text: "used past elapsed = runs out before reset"
                color: root.faint
                font.pixelSize: Style.font.caption
              }
            }
          }

          PanelSeparator { foreground: root.fg }

          // ---------- period + totals ----------
          ButtonGroup {
            options: root.periods
            value: root.period
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            focusable: false
            onChanged: function(value) { root.setPeriod(value) }
          }

          Row {
            id: tiles
            width: parent.width
            readonly property real cellWidth: width / 4

            StatTile { width: tiles.cellWidth; label: "COST"; value: root.money(root.totals.c) }
            StatTile { width: tiles.cellWidth; label: "TOKENS"; value: root.tokens(root.totals.t) }
            StatTile { width: tiles.cellWidth; label: "MESSAGES"; value: root.grouped(root.totals.m) }
            StatTile { width: tiles.cellWidth; label: "ACTIVE"; value: root.duration(root.totals.a) }
          }

          // ---------- chart ----------
          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: chartHeader.implicitHeight

              PanelSectionHeader {
                id: chartHeader
                text: (root.metric === "cost" ? "COST" : "TOKENS")
                  + (root.period === "today" ? " PER HOUR" : (root.periodKeys.length > 62 ? " PER WEEK" : " PER DAY"))
                foreground: root.fg
                fontFamily: root.fontFamily
              }

              PlainLabel {
                anchors.right: parent.right
                anchors.verticalCenter: chartHeader.verticalCenter
                text: "show " + (root.metric === "cost" ? "tokens" : "cost") + " (m)"
                color: metricMouse.containsMouse ? root.fg : root.dim
                font.pixelSize: Style.font.caption

                MouseArea {
                  id: metricMouse
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.metric = root.metric === "cost" ? "tokens" : "cost"
                }
              }
            }

            Item {
              id: chart
              width: parent.width
              implicitHeight: Style.space(96)
              readonly property real gap: root.bars.length > 40 ? 1 : Style.space(2)
              readonly property real step: root.bars.length > 0 ? (width + gap) / root.bars.length : width
              readonly property real barWidth: Math.max(1, step - gap)

              // Faint guide lines at full and half scale.
              Repeater {
                model: [0, 0.5]

                Rectangle {
                  required property var modelData
                  width: chart.width
                  height: 1
                  y: Math.round(chart.height * modelData)
                  color: root.alpha(root.fg, 0.06)
                }
              }

              Row {
                id: barRow
                anchors.bottom: parent.bottom
                spacing: chart.gap

                Repeater {
                  model: root.bars

                  Item {
                    id: barItem
                    required property var modelData
                    required property int index
                    width: chart.barWidth
                    height: chart.height
                    opacity: root.hoverBar < 0 || root.hoverBar === index ? 1 : 0.45

                    // Empty slots get a stub so the time axis stays readable.
                    Rectangle {
                      visible: barItem.modelData.segs.length === 0
                      anchors.bottom: parent.bottom
                      width: parent.width
                      height: 1
                      color: root.alpha(root.fg, 0.12)
                    }

                    Column {
                      anchors.bottom: parent.bottom
                      width: parent.width
                      spacing: 0

                      Repeater {
                        // Largest model at the bottom.
                        model: barItem.modelData.segs.slice().reverse()

                        Rectangle {
                          required property var modelData
                          width: barItem.width
                          height: root.barMax > 0
                            ? Math.max(1, chart.height * (root.metric === "cost" ? modelData.c : modelData.t) / root.barMax) : 0
                          color: modelData.color
                          radius: Math.min(1.5, Style.cornerRadius)
                        }
                      }
                    }
                  }
                }
              }

              MouseArea {
                anchors.fill: barRow
                hoverEnabled: true
                onExited: root.hoverBar = -1
                onPositionChanged: function(mouse) {
                  root.hoverBar = root.clamp(Math.floor(mouse.x / chart.step), 0, root.bars.length - 1)
                }
              }

              PlainLabel {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.topMargin: -Math.round(implicitHeight * 0.15)
                visible: root.barMax > 0
                text: root.metric === "cost" ? root.money(root.barMax) : root.tokens(root.barMax)
                color: root.faint
                font.pixelSize: Style.font.caption
              }
            }

            Item {
              width: parent.width
              implicitHeight: axisLeft.implicitHeight
              visible: root.bars.length > 1

              PlainLabel {
                id: axisLeft
                anchors.left: parent.left
                text: root.bars.length > 0 ? root.bars[0].short : ""
                color: root.faint
                font.pixelSize: Style.font.caption
              }
              PlainLabel {
                anchors.right: parent.right
                text: root.period === "today" ? "23:00" : "today"
                color: root.faint
                font.pixelSize: Style.font.caption
              }
            }

            PlainLabel {
              width: parent.width
              elide: Text.ElideRight
              color: root.dim
              font.pixelSize: Style.font.caption
              text: {
                var b = root.hoverBar >= 0 ? root.bars[root.hoverBar] : null
                if (b) return b.label + " · " + root.money(b.c) + " · " + root.tokens(b.t) + " tokens · " + b.m + " msgs"
                if (root.totals.t === 0) return root.statsAtMs === 0 ? "Reading usage from tokscale…" : "No usage in this period"
                var peak = root.peakBar >= 0 ? root.bars[root.peakBar] : null
                var peakText = peak ? "peak " + (root.metric === "cost" ? root.money(peak.c) : root.tokens(peak.t)) + " " + peak.short : ""
                if (root.period === "today")
                  return root.money(root.totals.c / Math.max(1, root.totals.a / 3600000)) + " per active hour · " + peakText
                return root.money(root.totals.c / Math.max(1, root.totals.days)) + " per active day · "
                  + root.totals.days + "/" + root.periodKeys.length + " days active · " + peakText
              }
            }
          }

          // ---------- models ----------
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.modelRows.length > 0

            PanelSectionHeader {
              text: "MODELS"
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.modelRows

              ModelRow {
                required property var modelData
                width: parent.width
                row: modelData
              }
            }
          }

          // ---------- token types ----------
          Column {
            id: tokenTypes
            width: parent.width
            spacing: Style.space(6)
            visible: root.totals.t > 0
            readonly property var parts: [
              { label: "Cache read", v: root.totals.b[2], color: root.blue },
              { label: "Cache write", v: root.totals.b[3], color: root.magenta },
              { label: "Output", v: root.totals.b[1], color: root.orange },
              { label: "Input", v: root.totals.b[0], color: root.green }
            ]
            readonly property real sum: Math.max(1, root.totals.b[0] + root.totals.b[1] + root.totals.b[2] + root.totals.b[3])

            Item {
              width: parent.width
              implicitHeight: tokensHeader.implicitHeight

              PanelSectionHeader {
                id: tokensHeader
                text: "TOKEN TYPES"
                foreground: root.fg
                fontFamily: root.fontFamily
              }

              PlainLabel {
                anchors.right: parent.right
                anchors.verticalCenter: tokensHeader.verticalCenter
                text: "cache hit " + root.num(100 * root.totals.b[2] / Math.max(1, root.totals.b[0] + root.totals.b[2] + root.totals.b[3]), 1) + "%"
                color: root.dim
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              width: parent.width
              height: Style.space(6)

              Repeater {
                model: tokenTypes.parts

                Rectangle {
                  required property var modelData
                  width: tokenTypes.width * modelData.v / tokenTypes.sum
                  height: parent.height
                  color: modelData.color
                }
              }
            }

            Flow {
              width: parent.width
              spacing: Style.space(12)

              Repeater {
                model: tokenTypes.parts

                Row {
                  required property var modelData
                  spacing: Style.space(5)

                  Rectangle {
                    width: Style.space(7)
                    height: width
                    radius: width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    color: modelData.color
                  }
                  PlainLabel {
                    text: modelData.label + " " + root.tokens(modelData.v)
                    color: root.dim
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          // ---------- activity ----------
          PanelSeparator { foreground: root.fg }

          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "ACTIVITY"
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            Item {
              id: heat
              width: parent.width
              readonly property int gap: Style.space(3)
              readonly property int cell: Style.space(11)
              readonly property int step: cell + gap
              readonly property int count: Math.min(root.heatWeeks.length, Math.floor((width + gap) / step))
              readonly property var shown: root.heatWeeks.slice(root.heatWeeks.length - count)
              implicitHeight: 7 * step - gap

              Row {
                id: heatRow
                anchors.right: parent.right
                spacing: heat.gap

                Repeater {
                  model: heat.shown

                  Item {
                    id: week
                    required property var modelData
                    width: heat.cell
                    height: heat.implicitHeight

                    Repeater {
                      model: week.modelData

                      Rectangle {
                        required property var modelData
                        y: modelData.wd * heat.step
                        width: heat.cell
                        height: heat.cell
                        radius: Math.min(2, Style.cornerRadius)
                        color: root.levelColor(modelData.l)
                        border.width: root.hoverDay && root.hoverDay.d === modelData.d ? 1 : 0
                        border.color: root.fg
                      }
                    }
                  }
                }
              }

              MouseArea {
                anchors.fill: heatRow
                hoverEnabled: true
                onExited: root.hoverDay = null
                onPositionChanged: function(mouse) {
                  var week = heat.shown[Math.floor(mouse.x / heat.step)]
                  var wd = Math.floor(mouse.y / heat.step)
                  root.hoverDay = week ? (week.filter(function(d) { return d.wd === wd })[0] || null) : null
                }
              }
            }

            PlainLabel {
              width: parent.width
              elide: Text.ElideRight
              color: root.dim
              font.pixelSize: Style.font.caption
              text: {
                var h = root.hoverDay
                if (h) return h.t > 0
                  ? root.longDate(h.d) + " · " + root.money(h.c) + " · " + root.tokens(h.t) + " tokens · " + h.m + " msgs"
                  : "No usage on " + root.longDate(h.d)
                var tm = root.timeMetrics
                return Object.keys(root.dayMap).length + " active days · " + root.streak + "-day streak · longest run "
                  + root.duration(tm.longestContinuousMs) + " · up to " + (tm.maxConcurrentSessions || 0) + " parallel"
              }
            }
          }

          // ---------- running sessions ----------
          PanelSeparator {
            foreground: root.fg
            visible: root.sessions.length > 0
          }

          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: root.sessions.length > 0

            PanelSectionHeader {
              text: "SESSIONS"
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.sessions.length   // count, not array: rows persist across polls

              SessionRow {
                required property int index
                width: parent.width
                session: root.sessions[index] || root.blankSession
              }
            }
          }

          // ---------- footer ----------
          PanelSeparator { foreground: root.fg }

          Row {
            id: footer
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing) / 2

            Button {
              width: footer.cellWidth
              iconText: root.glyph.chart
              text: "tokscale"
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.openTokscale()
            }
            Button {
              width: footer.cellWidth
              iconText: statsProc.running || quotaProc.running ? root.glyph.loading : root.glyph.refresh
              text: "Refresh"
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.refreshAll()
            }
          }

          PlainLabel {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: "1–4 / ←→ period · m cost/tokens · r refresh · t tokscale"
            color: root.faint
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // ---------- components ----------
  component PlainLabel: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component StatTile: Column {
    id: tile
    property string label: ""
    property string value: ""
    spacing: Style.space(2)

    PlainLabel {
      text: tile.label
      color: root.dim
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.1
    }
    PlainLabel {
      text: tile.value
      width: tile.width
      elide: Text.ElideRight
      font.pixelSize: Style.font.title
      font.bold: true
    }
  }

  component LimitRow: Column {
    id: limitRow
    property var limit: ({})
    readonly property real used: Number(limit.used) || 0
    readonly property real pace: isFinite(limit.resetsMs)
      ? root.clamp(1 - (limit.resetsMs - root.nowMs) / limit.windowMs, 0, 1) : -1
    readonly property color tint: root.meterColor(used)
    readonly property string windowName: limit.windowMs <= 5 * 3600000 ? "5-hour" : "weekly"
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: limitHead.implicitHeight

      Row {
        id: limitHead
        spacing: Style.space(8)

        PlainLabel {
          id: limitLabel
          text: limitRow.limit.label
          font.bold: true
        }
        PlainLabel {
          anchors.baseline: limitLabel.baseline
          text: Math.round(limitRow.used * 100) + "%"
          color: limitRow.tint
          font.bold: true
        }
      }

      PlainLabel {
        anchors.right: parent.right
        anchors.verticalCenter: limitHead.verticalCenter
        text: root.resetLabel(limitRow.limit.resetsMs)
        color: root.dim
        font.pixelSize: Style.font.caption
      }
    }

    // Rounded track; the faint inner bar is how much of the window has
    // elapsed, the colored bar how much of the limit is used. Used running
    // past elapsed means burning faster than the limit allows.
    Item {
      id: meter
      width: parent.width
      implicitHeight: Style.space(7)

      Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.alpha(root.fg, 0.07)
      }
      Rectangle {
        visible: limitRow.pace > 0
        height: parent.height
        radius: height / 2
        width: Math.max(height, meter.width * limitRow.pace)
        color: root.alpha(root.fg, 0.09)
      }
      Rectangle {
        visible: limitRow.used > 0
        height: parent.height
        radius: height / 2
        width: Math.max(height, meter.width * limitRow.used)
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0; color: root.alpha(limitRow.tint, 0.6) }
          GradientStop { position: 1; color: limitRow.tint }
        }
        Behavior on width { NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutCubic } }
      }
    }

    HoverHandler { id: limitHover }
    PanelToolTip {
      visible: limitHover.hovered && limitRow.pace >= 0
      text: Math.round(limitRow.used * 100) + "% used · " + Math.round(limitRow.pace * 100) + "% of the "
        + limitRow.windowName + " window elapsed — "
        + (limitRow.used > limitRow.pace + 0.02 ? "ahead of pace" : "within pace")
    }
  }

  component ModelRow: Item {
    id: modelRow
    property var row: ({})
    implicitHeight: modelLine.implicitHeight + Style.space(6) + Style.space(4)

    Rectangle {
      id: modelDot
      width: Style.space(8)
      height: width
      radius: width / 2
      anchors.verticalCenter: modelLine.verticalCenter
      color: modelRow.row.color
    }
    PlainLabel {
      id: modelLine
      anchors.left: modelDot.right
      anchors.leftMargin: Style.space(8)
      text: modelRow.row.name
      font.bold: true
    }
    PlainLabel {
      anchors.right: parent.right
      anchors.verticalCenter: modelLine.verticalCenter
      text: root.num(modelRow.row.share * 100, modelRow.row.share < 0.1 || (modelRow.row.share > 0.995 && modelRow.row.share < 1) ? 1 : 0) + "% · "
        + root.tokens(modelRow.row.t) + " · " + root.grouped(modelRow.row.m) + " msgs · " + root.money(modelRow.row.c)
      color: root.dim
    }
    Rectangle {
      anchors.left: modelLine.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Style.space(4)
      radius: height / 2
      color: root.track

      Rectangle {
        height: parent.height
        radius: parent.radius
        width: parent.width * root.clamp(modelRow.row.share, 0, 1)
        color: modelRow.row.color
      }
    }
  }

  // A session: status, name and state; under it the tokens it used (main
  // conversation plus all its subagents) by type, cost and share of the
  // 5-hour limit; then its running subagents, numbered, with their own.
  component SessionRow: CursorSurface {
    id: sessionRow
    property var session: ({})
    readonly property var usage: root.sessionUsageOf(session.sessionId)
    readonly property var agents: session.agents || []
    readonly property real share: root.limitShare(usage ? usage.all : null)
    implicitHeight: sessionBody.implicitHeight + Style.spacing.rowPaddingX
    hasCursor: sessionMouse.containsMouse
    foreground: root.fg

    Column {
      id: sessionBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(3)

      Item {
        width: parent.width
        implicitHeight: sessionLine.implicitHeight

        PlainLabel {
          id: sessionGlyph
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: root.sessionGutter
          text: root.statusGlyph(sessionRow.session)
          color: root.statusColor(sessionRow.session)
        }
        PlainLabel {
          id: sessionLine
          anchors.left: sessionGlyph.right
          anchors.right: sessionState.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
          text: root.project(sessionRow.session, 48)
          font.bold: true
        }
        PlainLabel {
          id: sessionState
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: root.stateLabel(sessionRow.session).replace("background shells/monitors running", "shells running")
          color: root.dim
          font.pixelSize: Style.font.caption
        }
      }

      Item {
        visible: !!sessionRow.usage
        width: parent.width
        implicitHeight: sessionTotals.implicitHeight

        PlainLabel {
          id: sessionTotals
          anchors.left: parent.left
          anchors.leftMargin: root.sessionGutter
          anchors.verticalCenter: parent.verticalCenter
          text: sessionRow.usage ? root.tokens(root.tokenTotal(sessionRow.usage.all)) + " tokens · "
                + root.money(sessionRow.usage.all.c) + " · " + root.grouped(sessionRow.usage.all.n) + " msgs" : ""
          font.pixelSize: Style.font.caption
        }
        PlainLabel {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: sessionRow.share >= 0
          text: root.percent(sessionRow.share) + " of limit"
          color: root.limitColor(sessionRow.share)
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      PlainLabel {
        visible: !!sessionRow.usage
        x: root.sessionGutter
        width: parent.width - x
        elide: Text.ElideRight
        text: sessionRow.usage ? root.tokenTypesText(sessionRow.usage.all) : ""
        color: root.dim
        font.pixelSize: Style.font.caption
      }

      // Context window: label, and a meter to the right of it.
      Item {
        readonly property var ctx: sessionRow.session.context || null
        visible: !!ctx
        width: parent.width
        implicitHeight: contextText.implicitHeight

        PlainLabel {
          id: contextText
          anchors.left: parent.left
          anchors.leftMargin: root.sessionGutter
          anchors.verticalCenter: parent.verticalCenter
          text: root.contextLabel(parent.ctx)
          color: parent.ctx && parent.ctx.pct >= 70 ? root.contextColor(parent.ctx.pct) : root.dim
          font.pixelSize: Style.font.caption
        }
        Rectangle {
          id: contextTrack
          anchors.left: contextText.right
          anchors.leftMargin: Style.space(8)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          height: 3
          radius: 1.5
          color: root.track
          Rectangle {
            width: parent.width * (parent.parent.ctx ? parent.parent.ctx.pct / 100 : 0)
            height: parent.height
            radius: parent.radius
            color: root.contextColor(parent.parent.ctx ? parent.parent.ctx.pct : 0)
          }
        }
      }

      Repeater {
        model: sessionRow.agents

        Item {
          id: agentRow
          required property var modelData
          required property int index
          readonly property var usage: root.agentUsageOf(sessionRow.usage, modelData.id)
          readonly property real share: root.limitShare(usage)
          width: parent.width
          implicitHeight: agentName.implicitHeight + (agentAction.visible ? agentAction.implicitHeight : 0)

          // Numbers right-aligned in the glyph column, so 9. and 10. line up.
          PlainLabel {
            anchors.left: parent.left
            anchors.verticalCenter: agentName.verticalCenter
            width: root.sessionGutter - Style.space(4)
            horizontalAlignment: Text.AlignRight
            text: (agentRow.index + 1) + "."
            color: root.magenta
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          PlainLabel {
            id: agentName
            anchors.left: parent.left
            anchors.leftMargin: root.sessionGutter + Style.space(8) * (agentRow.modelData.depth - 1)
            anchors.right: agentStats.left
            anchors.rightMargin: Style.space(8)
            anchors.top: parent.top
            elide: Text.ElideRight
            text: agentRow.modelData.description || agentRow.modelData.type
            font.pixelSize: Style.font.caption
          }
          // Its last tool call, under the name.
          PlainLabel {
            id: agentAction
            visible: !!agentRow.modelData.action
            anchors.left: agentName.left
            anchors.right: parent.right
            anchors.top: agentName.bottom
            elide: Text.ElideRight
            text: root.actionText(agentRow.modelData.action)
            color: root.faint
            font.pixelSize: Style.font.caption
          }
          PlainLabel {
            id: agentStats
            anchors.right: parent.right
            anchors.verticalCenter: agentName.verticalCenter
            text: [agentRow.modelData.type === "general-purpose" ? "" : agentRow.modelData.type,
                   root.elapsed(root.nowMs - agentRow.modelData.startedAt),
                   agentRow.usage ? root.tokens(root.tokenTotal(agentRow.usage)) : "",
                   agentRow.usage ? root.money(agentRow.usage.c) : "",
                   agentRow.share >= 0 ? root.percent(agentRow.share) : ""]
                  .filter(function(part) { return part !== "" }).join(" · ")
            color: root.dim
            font.pixelSize: Style.font.caption
          }
        }
      }

      // Background shells and monitors, a terminal or eye in the glyph column.
      Repeater {
        model: sessionRow.session.shells || []

        Item {
          id: shellRow
          required property var modelData
          width: parent.width
          implicitHeight: shellName.implicitHeight

          PlainLabel {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: root.sessionGutter - Style.space(4)
            horizontalAlignment: Text.AlignRight
            text: shellRow.modelData.kind === "monitor" ? root.glyph.eye : root.glyph.terminal
            color: root.blue
            font.pixelSize: Style.font.caption
          }
          PlainLabel {
            id: shellName
            anchors.left: parent.left
            anchors.leftMargin: root.sessionGutter
            anchors.right: shellAge.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            text: shellRow.modelData.description || shellRow.modelData.kind
            font.pixelSize: Style.font.caption
          }
          PlainLabel {
            id: shellAge
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: (shellRow.modelData.kind === "monitor" ? "monitor · " : "") + root.elapsed(root.nowMs - shellRow.modelData.startedAt)
            color: root.dim
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    MouseArea {
      id: sessionMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        root.focusSession(sessionRow.session.pid)
        root.close()
      }
    }
  }
}
