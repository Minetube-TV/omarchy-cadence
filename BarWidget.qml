import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import Quickshell
import Quickshell.Io
import "FocusModel.js" as FocusModel

// Bar entry for the shared Cadence timer. The countdown itself lives in
// Service.qml so every monitor and every bar reload sees the same session.
BarWidget {
  id: root
  moduleName: "jimmerioles.cadence"

  property var service: null

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  // ---- Study state, at a glance ---------------------------------------
  // studying: work block running   → book, accent (blue): you should be studying
  // break:    break running        → coffee, green: step away
  // paused:   work or break paused → pause, yellow
  // idle:     nothing running      → book, plain foreground (cycle done, start again)
  readonly property bool breakPhase: service ? service.phase === "break" : false
  readonly property string studyState: !service ? "idle"
    : service.running ? (breakPhase ? "break" : "studying")
    : service.paused ? "paused"
    : "idle"
  readonly property string glyph: studyState === "break" ? "\u{f0176}"
    : studyState === "paused" ? "\u{f03e4}"
    : "\u{f05da}"
  readonly property real progress: service && studyState !== "idle" ? service.progress : 0

  // Theme colours: green and yellow are not in Commons.Color, so read them
  // from the current theme's colors.toml (re-read when the theme changes).
  property color themeGreen: Commons.Color.accent
  property color themeYellow: Commons.Color.urgent
  readonly property color baseForeground: root.bar ? root.bar.barForeground : Commons.Color.foreground
  readonly property color stateColor: studyState === "studying" ? Commons.Color.accent
    : studyState === "break" ? root.themeGreen
    : studyState === "paused" ? root.themeYellow
    : root.baseForeground

  function readThemeColors(text) {
    function pick(key, fallback) {
      var m = String(text || "").match(new RegExp("^\\s*" + key + "\\s*=\\s*\"(#[0-9a-fA-F]{6,8})\"", "m"))
      return m ? m[1] : fallback
    }
    root.themeGreen = pick("green", Commons.Color.accent)
    root.themeYellow = pick("yellow", Commons.Color.urgent)
  }

  FileView {
    id: themeColors
    path: (Quickshell.env("HOME") || "") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.readThemeColors(text())
    onFileChanged: reload()
  }

  Connections {
    target: Commons.Color
    function onAccentChanged() { themeColors.reload() }
    function onForegroundChanged() { themeColors.reload() }
  }

  readonly property string tooltipText: {
    if (!service) return strings.t("widget.tooltip", "Cadence timer")
    if (studyState === "studying") return "Study time · " + service.phaseLabel
    if (studyState === "break") return "Break · step away from the desk"
    if (studyState === "paused") return (breakPhase ? "Break" : service.phaseLabel) + " · paused"
    return "Not studying · click to start a block"
  }
  readonly property bool active: service ? service.running : false

  function resolveService() {
    if (root.service) return
    var api = root.bar
    var candidate = api && api.shell && typeof api.shell.serviceFor === "function"
      ? api.shell.serviceFor(root.moduleName)
      : null
    if (candidate) {
      root.service = candidate
      serviceRetry.stop()
      root.configureService()
      root.injectPanel()
    } else {
      serviceRetry.restart()
    }
  }

  function configureService() {
    if (!root.service) return
    root.service.configure(root.settings || {})
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("service" in target) target.service = root.service
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // Shape contract for shell.summon/hide/toggle routing.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: {
    resolveService()
    injectPanel()
  }
  onModuleNameChanged: resolveService()
  onSettingsChanged: configureService()
  onServiceChanged: injectPanel()

  Timer {
    id: serviceRetry
    interval: 200
    repeat: true
    running: root.service === null && root.bar !== null
    onTriggered: root.resolveService()
  }

  Component.onCompleted: resolveService()

  Commons.ShellIpc {
    target: "jimmerioles.cadence"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function start(): void { if (root.service) root.service.start() }
    function pause(): void { if (root.service) root.service.pause() }
    function reset(): void { if (root.service) root.service.reset() }
    function skipBreak(): void { if (root.service) root.service.skipBreak() }
    function toggleTimer(): void { if (root.service) root.service.toggle() }
    function setMode(value: string): string { if (root.service) root.service.selectMode(String(value)); return root.service ? root.service.mode : "" }
    function startMode(value: string): void { if (root.service) root.service.startMode(String(value)) }
    function status(): string { return root.service ? root.service.status() : "{}" }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.tooltipText
    labelVisible: false
    hasVisualContent: true
    fixedWidth: vertical ? -1 : content.implicitWidth + Style.space(12)
    fixedHeight: vertical ? content.implicitHeight + Style.space(12) : -1

    onPressed: function(button) {
      if (button === Qt.RightButton) {
        if (root.service) root.service.toggle()
      } else if (button === Qt.MiddleButton) {
        if (root.service) root.service.reset()
      } else {
        root.togglePanel()
      }
    }

    Grid {
      id: content
      anchors.centerIn: parent
      scale: button.pressScale
      flow: button.vertical ? Grid.TopToBottom : Grid.LeftToRight
      columns: button.vertical ? 1 : 2
      rows: button.vertical ? 2 : 1
      spacing: Style.space(5)
      horizontalItemAlignment: Grid.AlignHCenter
      verticalItemAlignment: Grid.AlignVCenter

      Item {
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas

        OpticalGlyph {
          anchors.fill: parent
          text: root.glyph
          fontFamily: button.fontFamily
          fontSize: Style.bar.iconFont
          paintedSize: Style.bar.iconSize
          color: root.stateColor
          Behavior on color { ColorAnimation { duration: Style.duration(160) } }
        }
      }

      // Progress through the current block. Deliberately no numbers.
      Item {
        id: track
        width: button.vertical ? Style.bar.iconCanvas : Style.space(26)
        height: Math.max(2, Style.space(3))

        Rectangle {
          anchors.fill: parent
          radius: height / 2
          color: Util.alpha(root.baseForeground, 0.18)
        }

        Rectangle {
          height: parent.height
          radius: height / 2
          width: root.progress > 0 ? Math.max(height, parent.width * root.progress) : 0
          color: root.stateColor
          Behavior on width { NumberAnimation { duration: Style.duration(280); easing.type: Easing.OutCubic } }
          Behavior on color { ColorAnimation { duration: Style.duration(160) } }
        }
      }
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }
}
