import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "FocusModel.js" as FocusModel

// Shared Cadence session state. One instance serves every bar surface, so the
// countdown, mode, and session count stay identical on all monitors and across
// bar reloads. The bar widget only renders this and forwards clicks.
//
// The session rules live in FocusModel.js. This file owns the QML properties,
// timers, disk I/O, notifications, and the side effects those rules return.
Item {
  id: service

  // Injected by omarchy-shell's service loader.
  property var shell: null
  property var manifest: null

  readonly property string stateDir: (Quickshell.env("HOME") || "") + "/.local/state/omarchy/cadence"
  readonly property string statePath: stateDir + "/state.json"

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  // ---- Settings ---------------------------------------------------------
  // Defaults come from FocusModel so the manifest contract test can compare
  // both against the schema instead of keeping a third copy in QML.
  property int deepMinutes: FocusModel.defaultConfig().deepMinutes
  property int shortMinutes: FocusModel.defaultConfig().shortMinutes
  property int deepBreakMinutes: FocusModel.defaultConfig().deepBreakMinutes
  property int shortBreakMinutes: FocusModel.defaultConfig().shortBreakMinutes
  property bool autoStartBreak: FocusModel.defaultConfig().autoStartBreak
  property bool autoStartWork: FocusModel.defaultConfig().autoStartWork
  property bool notifications: FocusModel.defaultConfig().notifications

  // ---- Session ----------------------------------------------------------
  // mode is the session type chosen for the next session; sessionMode is the
  // type the current work block or break belongs to. They differ while a
  // session is running if the user has already picked what comes next.
  property string mode: "deep"          // "deep" | "short"
  property string sessionMode: "deep"   // "deep" | "short"
  property string phase: "work"         // "work" | "break"
  property bool running: false
  property bool paused: false
  property bool dndOwned: false
  property double endsAt: 0             // epoch ms; only meaningful while running
  property double remainingMs: FocusModel.defaultConfig().deepMinutes * 60000
  property double totalMs: FocusModel.defaultConfig().deepMinutes * 60000
  property double nowMs: Date.now()
  property int sessionsToday: 0
  property string sessionsDate: ""
  property bool stateLoaded: false
  property bool storeReady: false
  property bool dirty: false

  // ---- Short break (johann-study) ----------------------------------------
  // A short break inside a work block: the focus timer pauses, a 5 minute
  // countdown runs, and when it is up a notification says so. Focus only
  // continues when the user clicks to resume. Persisted next to the state.
  readonly property int shortBreakLimitMs: 5 * 60000
  property double shortBreakAt: 0          // epoch ms; 0 = no short break
  property bool shortBreakNotified: false
  readonly property bool onShortBreak: shortBreakAt > 0
  readonly property double shortBreakElapsedMs: onShortBreak ? Math.max(0, nowMs - shortBreakAt) : 0
  readonly property bool shortBreakOver: onShortBreak && shortBreakElapsedMs >= shortBreakLimitMs

  // ---- Laptop off / asleep (johann-study) --------------------------------
  // A work block only runs while the laptop does. While it runs, the shell
  // notes it is alive (saved every 30 s). After a shutdown, crash, empty
  // battery or suspend, the block is paused at the last moment the shell was
  // alive, so the time the laptop was off is not used up. Shell reloads are
  // quick and keep the block running.
  readonly property int offlineGapMs: 2 * 60000
  readonly property int aliveSaveMs: 30000
  property double lastTickAt: 0
  property double aliveSavedAt: 0

  // ---- Study log (johann-study) ------------------------------------------
  // Every start, pause, resume, finish, reset and short break is appended as
  // one JSON line, so real study habits can be analysed later. Nothing reads
  // it in the shell; it is only a record.
  readonly property string eventLogPath: (Quickshell.env("HOME") || "") + "/.local/state/study-hours/events.jsonl"

  readonly property double effectiveRemainingMs: running
    ? Math.max(0, endsAt - nowMs)
    : Math.max(0, remainingMs)
  readonly property real progress: totalMs > 0
    ? Util.clamp(1 - effectiveRemainingMs / totalMs, 0, 1)
    : 0
  readonly property int workMinutes: sessionMode === "deep" ? deepMinutes : shortMinutes
  readonly property int breakMinutes: sessionMode === "deep" ? deepBreakMinutes : shortBreakMinutes

  readonly property string phaseLabel: phase === "break"
    ? strings.t("panel.break", "Break")
    : (sessionMode === "deep" ? strings.t("panel.deep", "Deep Focus") : strings.t("panel.short", "Short Focus"))
  readonly property string statusLabel: running
    ? strings.t("panel.running", "Running")
    : (paused ? strings.t("panel.paused", "Paused") : strings.t("panel.ready", "Ready"))

  // ---- State projection -------------------------------------------------
  function configSnapshot() {
    return {
      deepMinutes: deepMinutes,
      shortMinutes: shortMinutes,
      deepBreakMinutes: deepBreakMinutes,
      shortBreakMinutes: shortBreakMinutes,
      autoStartBreak: autoStartBreak,
      autoStartWork: autoStartWork,
      notifications: notifications
    }
  }

  function stateSnapshot() {
    return {
      mode: mode,
      sessionMode: sessionMode,
      phase: phase,
      running: running,
      paused: paused,
      dndOwned: dndOwned,
      endsAt: endsAt,
      remainingMs: remainingMs,
      totalMs: totalMs,
      sessionsToday: sessionsToday,
      sessionsDate: sessionsDate
    }
  }

  // ---- Study log --------------------------------------------------------
  function localIso(ms) {
    var d = new Date(ms)
    var off = -d.getTimezoneOffset()
    var sign = off >= 0 ? "+" : "-"
    off = Math.abs(off)
    function p(n) { return n < 10 ? "0" + n : String(n) }
    return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate())
      + "T" + p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds())
      + sign + p(Math.floor(off / 60)) + ":" + p(off % 60)
  }

  function minutesOf(ms) {
    return Math.round((Number(ms) || 0) / 6000) / 10
  }

  // Build one log record. `s` is the state the event describes.
  function logRecord(event, s, now, extra) {
    var remaining = s.running ? Math.max(0, s.endsAt - now) : Math.max(0, s.remainingMs)
    var record = {
      ts: localIso(now),
      event: event,
      mode: s.sessionMode,
      phase: s.phase,
      plannedMin: minutesOf(s.totalMs),
      elapsedMin: minutesOf(Math.max(0, s.totalMs - remaining)),
      remainingMin: minutesOf(remaining)
    }
    if (extra) for (var k in extra) record[k] = extra[k]
    return JSON.stringify(record)
  }

  // Derive what happened from the state before and after a transition.
  function transitionRecords(prev, next, effects, now, cause) {
    var lines = []
    if (cause === "reset" && (prev.running || prev.paused)) {
      lines.push(logRecord(prev.phase === "work" ? "focus_reset" : "break_reset", prev, now))
    }
    if (cause === "skipBreak" && prev.phase === "break") {
      lines.push(logRecord("break_skip", prev, now))
    }
    if (prev.running && !next.running && next.paused && prev.phase === next.phase && cause !== "offline") {
      lines.push(logRecord(next.phase === "work" ? "focus_pause" : "break_pause", next, now,
        cause === "shortBreak" ? { reason: "short_break" } : null))
    }
    if ((prev.running || prev.paused) && prev.phase === "break" && next.phase === "work"
        && !effects.notify && cause !== "skipBreak") {
      lines.push(logRecord("break_end_early", prev, now))
    }
    if (effects.notify === "workDone") {
      lines.push(logRecord("focus_complete", prev, now))
    } else if (effects.notify === "breakDone") {
      lines.push(logRecord("break_complete", prev, now))
    }
    var wasRunningSame = prev.running && prev.phase === next.phase && !effects.notify
    if (next.running && !wasRunningSame) {
      var resumed = prev.paused && prev.phase === next.phase && !prev.running
      var kind = next.phase === "work" ? "focus" : "break"
      lines.push(logRecord(kind + (resumed ? "_resume" : "_start"), next, now))
    }
    return lines
  }

  // Lines are queued and written by one writer process at a time, so events
  // that happen together (short_break_end + focus_resume) always land in the
  // file in order, as one append.
  property var pendingLog: []
  readonly property var logWriteCommand: ["sh", "-c",
    'mkdir -p -- "$(dirname -- "$1")" && printf "%s\\n" "$2" >> "$1"', "cadence-log"]

  function appendLog(lines) {
    if (!lines || lines.length === 0) return
    pendingLog = pendingLog.concat(lines)
    Qt.callLater(flushLog)
  }

  function flushLog() {
    if (logWriter.running || pendingLog.length === 0) return
    var lines = pendingLog
    pendingLog = []
    logWriter.command = logWriteCommand.concat([eventLogPath, lines.join("\n")])
    logWriter.running = true
  }

  // Apply a pure transition and run the effects it asked for.
  function applyResult(result, now, cause) {
    if (!result || !result.state) return

    var next = result.state
    var effects = result.effects || {}
    if (stateLoaded && cause !== "load" && cause !== "dayReset") {
      var logNow = now !== undefined ? now : Date.now()
      appendLog(transitionRecords(stateSnapshot(), next, effects, logNow, cause || ""))
    }

    mode = next.mode
    sessionMode = next.sessionMode
    phase = next.phase
    running = next.running
    paused = next.paused
    dndOwned = next.dndOwned
    endsAt = next.endsAt
    remainingMs = next.remainingMs
    totalMs = next.totalMs
    sessionsToday = next.sessionsToday
    sessionsDate = next.sessionsDate
    if (now !== undefined) nowMs = now

    if (effects.stopHistoryReplay) historyReplayTimer.stop()

    if (effects.dnd === "query") {
      refreshSessionDnd()
    } else if (effects.dnd === "on") {
      Util.execArgv(["omarchy-shell", "notifications", "setDnd", "true"])
    } else if (effects.dnd === "off") {
      Util.execArgv(["omarchy-shell", "notifications", "setDnd", "false"])
      if (effects.replayHistory) historyReplayTimer.restart()
    }

    if (effects.notify === "workDone") notifyWorkDone()
    else if (effects.notify === "breakDone") notifyBreakDone()

    if (effects.save) {
      dirty = true
      saveSoon()
    }
  }

  // ---- Configuration ----------------------------------------------------
  function configure(values) {
    var resolved = FocusModel.resolveConfig(configSnapshot(), values)
    if (!resolved.changed) return

    var next = resolved.config
    deepMinutes = next.deepMinutes
    shortMinutes = next.shortMinutes
    deepBreakMinutes = next.deepBreakMinutes
    shortBreakMinutes = next.shortBreakMinutes
    autoStartBreak = next.autoStartBreak
    autoStartWork = next.autoStartWork
    notifications = next.notifications

    // A session that has not started yet follows its new length. A running or
    // paused session keeps the length it began with.
    if (stateLoaded && !running && !paused) {
      applyResult(FocusModel.applyConfigToState(stateSnapshot(), next), Date.now())
    }
  }

  // ---- Timer control ----------------------------------------------------
  function start() {
    var now = Date.now()
    lastTickAt = now
    endShortBreak(now)
    applyResult(FocusModel.start(stateSnapshot(), configSnapshot(), now), now, "start")
  }

  function pause() {
    var now = Date.now()
    applyResult(FocusModel.pause(stateSnapshot(), configSnapshot(), now), now, "pause")
  }

  function toggle() {
    if (running) pause()
    else start()
  }

  function reset() {
    var now = Date.now()
    endShortBreak(now)
    applyResult(FocusModel.reset(stateSnapshot(), configSnapshot()), now, "reset")
  }

  function skipBreak() {
    var now = Date.now()
    applyResult(FocusModel.skipBreak(stateSnapshot(), configSnapshot()), now, "skipBreak")
  }

  // ---- Short break ------------------------------------------------------
  // Pause the running work block for a short break. Resuming (start/toggle)
  // ends it; there is no automatic resume.
  function shortBreak() {
    if (!running || phase !== "work" || onShortBreak) return
    var now = Date.now()
    applyResult(FocusModel.pause(stateSnapshot(), configSnapshot(), now), now, "shortBreak")
    if (!paused) return   // the block had just ended instead
    shortBreakAt = now
    shortBreakNotified = false
    nowMs = now
    appendLog([logRecord("short_break_start", stateSnapshot(), now)])
    dirty = true
    saveSoon()
  }

  function endShortBreak(now) {
    if (!onShortBreak) return
    appendLog([logRecord("short_break_end", stateSnapshot(), now,
      { breakMin: minutesOf(now - shortBreakAt), overMin: minutesOf(Math.max(0, now - shortBreakAt - shortBreakLimitMs)) })])
    shortBreakAt = 0
    shortBreakNotified = false
    dirty = true
    saveSoon()
  }

  function checkShortBreak(now) {
    if (!onShortBreak || shortBreakNotified) return
    if (now - shortBreakAt < shortBreakLimitMs) return
    shortBreakNotified = true
    appendLog([logRecord("short_break_over", stateSnapshot(), now)])
    dirty = true
    saveSoon()
    // Default app name (omarchy-action) so it shows through the focus block's
    // Do Not Disturb; critical so it stays until dismissed.
    Util.execArgv([
      "omarchy-notification-send",
      "5 minute break is up · " + completionTime(),
      "Focus is still paused. Continue when you are back.",
      "-g", "\u{f0176}", "-u", "critical",
      "--action", "Continue focus", "omarchy-shell", "jimmerioles.cadence", "start"
    ])
  }

  function selectMode(next) {
    var now = Date.now()
    applyResult(FocusModel.selectMode(stateSnapshot(), configSnapshot(), next), now)
  }

  // Start a fresh work block in the given mode. If a work session is already
  // running or paused, queue the mode instead so a shortcut cannot destroy
  // progress. A break gives way to the requested work block.
  function startMode(value) {
    var now = Date.now()
    applyResult(FocusModel.startMode(stateSnapshot(), configSnapshot(), value, now), now)
  }

  // The machine was asleep while a work block ran: pause it where it stopped.
  // Runs before anything else looks at the clock after a wake-up (the tick and
  // the midnight check), so a block asleep over midnight is reset, not kept.
  function pauseIfWasAsleep(now) {
    if (!running || phase !== "work" || lastTickAt <= 0 || now - lastTickAt <= offlineGapMs) return false
    var at = lastTickAt
    lastTickAt = 0
    applyResult(FocusModel.pause(stateSnapshot(), configSnapshot(), at), at, "offline")
    appendLog([offlineRecord(at, now)])
    nowMs = now
    return true
  }

  function offlineRecord(at, now) {
    return logRecord("offline_pause", stateSnapshot(), now, { pausedAt: localIso(at), offMin: minutesOf(now - at) })
  }

  function tick() {
    var now = Date.now()
    if (pauseIfWasAsleep(now)) {
      rollDay()
      return
    }
    lastTickAt = now
    if (running && phase === "work" && now - aliveSavedAt >= aliveSaveMs) saveSoon()
    nowMs = now
    checkShortBreak(now)
    var result = FocusModel.tick(stateSnapshot(), configSnapshot(), now)
    if (result.effects.save) applyResult(result, now, "tick")
  }

  // Kept for the panel tests and for a caller that wants to end a session
  // explicitly; the ticker normally reaches this through tick().
  function finishPhase() {
    var now = Date.now()
    applyResult(FocusModel.finishPhase(stateSnapshot(), configSnapshot(), now), now)
  }

  // ---- Do Not Disturb ---------------------------------------------------
  // Cadence only turns DND off again when it was the one that turned it on.
  // A DND the user set themselves is left alone.
  function refreshSessionDnd() {
    if (phase !== "work" || !running) return
    if (dndOwned) {
      Util.execArgv(["omarchy-shell", "notifications", "setDnd", "true"])
      return
    }
    if (!dndQuery.running) dndQuery.running = true
  }

  function applyDndQuery(raw) {
    var now = Date.now()
    applyResult(FocusModel.applyDndQuery(stateSnapshot(), raw), now)
  }

  // ---- Notifications ----------------------------------------------------
  function completionTime() {
    var locale = Qt.locale(Commons.I18n.formatLocale)
    return new Date().toLocaleString(locale, locale.timeFormat(Locale.ShortFormat))
  }

  function notifyWorkDone() {
    if (!notifications) return
    var minutes = Commons.I18n.formatNumber(breakMinutes, 0)
    var title = (sessionMode === "deep"
      ? strings.t("notify.deepDone", "Deep Focus complete · %1")
      : strings.t("notify.shortDone", "Short Focus complete · %1")).arg(completionTime())
    var body = autoStartBreak
      ? strings.t("notify.breakStarted", "A %1 minute break has started. Step away.").arg(minutes)
      : strings.t("notify.breakReady", "A %1 minute break is ready. Start it when you are.").arg(minutes)
    var extraAction = []
    if (!autoStartBreak) {
      extraAction = ["--action", strings.t("notify.startBreak", "Start break"),
                     "omarchy-shell", "jimmerioles.cadence", "start"]
    }
    sendNotification(title, body, "\u{f0430}", extraAction)
  }

  function notifyBreakDone() {
    if (!notifications) return
    var body = autoStartWork
      ? strings.t("notify.nextStarted", "The next session has started.")
      : strings.t("notify.ready", "Ready for the next session.")
    var extraAction = []
    if (!autoStartWork) {
      extraAction = ["--action", strings.t("notify.startWork", "Start focus"),
                     "omarchy-shell", "jimmerioles.cadence", "start"]
    }
    sendNotification(strings.t("notify.breakDone", "Break complete · %1").arg(completionTime()),
                     body, "\u{f117c}", extraAction)
  }

  function sendNotification(title, body, glyph, extraAction) {
    var argv = [
      "omarchy-notification-send",
      String(title), String(body),
      "-g", glyph,
      "-u", "normal",
      "--app-name", "Cadence",
      "--action", strings.t("notify.open", "Open Cadence"),
      "omarchy-shell", "jimmerioles.cadence", "open"
    ]
    if (extraAction && extraAction.length > 0) argv = argv.concat(extraAction)
    Util.execArgv(argv)
  }

  // ---- Persistence ------------------------------------------------------
  function loadState(raw) {
    if (stateLoaded) return
    stateLoaded = true

    // A user action that landed before the file was read wins.
    if (dirty) {
      saveSoon()
      return
    }

    var now = Date.now()
    var parsed = FocusModel.parseState(raw)
    var savedDate = parsed ? parsed.sessionsDate : ""

    // The laptop was off (shutdown, crash, empty battery) while a work block
    // ran: pause it where the shell was last alive.
    var offlineAt = 0
    try {
      var alive = Number((JSON.parse(String(raw || "")).johannStudy || {}).aliveAt) || 0
      if (parsed && parsed.running && parsed.phase === "work" && alive > 0
          && now - alive > offlineGapMs && parsed.endsAt > alive) {
        parsed.remainingMs = parsed.endsAt - alive
        parsed.running = false
        parsed.paused = true
        parsed.endsAt = 0
        offlineAt = alive
      }
    } catch (e) {}
    applyResult(FocusModel.resolveLoadedState(parsed, configSnapshot(), now), now, "load")

    // Restore a short break that was in progress when the shell reloaded.
    try {
      var extra = JSON.parse(String(raw || "")).johannStudy || {}
      var at = Number(extra.shortBreakAt) || 0
      if (at > 0 && at <= now && phase === "work" && paused) {
        shortBreakAt = at
        shortBreakNotified = extra.shortBreakNotified === true
      }
    } catch (e) {}

    if (offlineAt > 0) appendLog([offlineRecord(offlineAt, now)])
    lastTickAt = running ? now : 0

    // Booted (or the shell restarted) on a later day than the state was saved.
    resetStaleDay(savedDate, now)
  }

  function saveSoon() {
    if (!stateLoaded || !storeReady) return
    dirty = true
    if (!saveTimer.running) saveTimer.start()
  }

  function saveNow() {
    saveTimer.stop()
    if (!stateLoaded || !storeReady) return
    var serialized = FocusModel.serializeState(stateSnapshot(), Date.now())
    var savedAt = Date.now()
    aliveSavedAt = savedAt
    serialized.johannStudy = { shortBreakAt: shortBreakAt, shortBreakNotified: shortBreakNotified, aliveAt: savedAt }
    stateFile.setText(JSON.stringify(serialized))
    dirty = false
  }

  function status() {
    var snapshot = FocusModel.statusSnapshot(stateSnapshot(), Date.now(), phaseLabel)
    snapshot.shortBreak = onShortBreak
    return JSON.stringify(snapshot)
  }

  Timer {
    id: ticker
    interval: 250
    repeat: true
    running: service.running || service.onShortBreak
    onTriggered: service.tick()
  }

  // Reset "sessions today" at midnight even while nothing is running; the
  // model only rolls the day over when a block starts or ends.
  // A new day starts with a fresh timer (johann-study): a paused block or a
  // break left over from yesterday is over. Only a block that is actually
  // running at midnight (or a short break taken in the last 30 minutes) keeps
  // going, so studying past midnight is not interrupted.
  readonly property int shortBreakKeepMs: 30 * 60000

  function resetStaleDay(fromDate, now) {
    if (!fromDate || fromDate === FocusModel.dateKey(new Date(now))) return
    if (running) return
    if (onShortBreak && now - shortBreakAt < shortBreakKeepMs) return
    var fresh = phase === "work" && !paused && !onShortBreak
    if (fresh) return
    endShortBreak(now)
    appendLog([logRecord("day_reset", stateSnapshot(), now, { from: fromDate })])
    var s = stateSnapshot()
    s.phase = "work"
    s.paused = false
    applyResult(FocusModel.reset(s, configSnapshot()), now, "dayReset")
    dirty = true
    saveSoon()
  }

  function rollDay() {
    if (!stateLoaded) return
    var now = Date.now()
    pauseIfWasAsleep(now)
    var snapshot = stateSnapshot()
    var before = snapshot.sessionsDate
    FocusModel.ensureToday(snapshot, now)
    if (snapshot.sessionsDate === before) return
    resetStaleDay(before, now)
    sessionsDate = snapshot.sessionsDate
    sessionsToday = snapshot.sessionsToday
    dirty = true
    saveSoon()
  }

  Timer {
    interval: 60000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: service.rollDay()
  }

  Timer {
    id: saveTimer
    interval: 200
    onTriggered: service.saveNow()
  }

  Process {
    id: logWriter
    running: false
    onExited: function(code) {
      if (code !== 0) console.warn("Cadence: could not append to " + service.eventLogPath + " (exit " + code + ")")
      Qt.callLater(service.flushLog)
    }
  }

  Process {
    id: dndQuery
    running: false
    command: ["omarchy-shell", "notifications", "isDnd"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.applyDndQuery(text)
    }
  }

  Timer {
    id: historyReplayTimer
    interval: 800
    onTriggered: Util.execArgv(["omarchy-shell", "notifications", "showHistory"])
  }

  Process {
    id: prepareStore
    command: FocusModel.prepareStoreCommand(service.stateDir, service.statePath)
    running: true
    onExited: function(code) { service.storeReady = code === 0 }
  }

  FileView {
    id: stateFile
    path: service.storeReady ? service.statePath : ""
    atomicWrites: true
    printErrors: false
    blockLoading: true
    onLoaded: { if (path !== "") service.loadState(text()) }
    onLoadFailed: { if (path !== "") service.loadState("") }
  }

  onStoreReadyChanged: {
    if (storeReady && stateLoaded && dirty) saveSoon()
  }

  Component.onDestruction: {
    // Whatever is still queued is handed to a detached writer so it outlives the shell.
    if (pendingLog.length > 0)
      Quickshell.execDetached(logWriteCommand.concat([eventLogPath, pendingLog.join("\n")]))
    if (dndOwned) Util.execArgv(["omarchy-shell", "notifications", "setDnd", "false"])
    saveNow()
  }
}
