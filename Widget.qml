import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Weather alerts for the Omarchy bar. Runs bin/weather-alerts from this plugin's folder every few
// minutes (NWS alerts, NOAA storm alerts, Kp, national outlooks; US places for NWS) and reads its
// cache for the pill: an idle glyph when nothing is active, the alerts' type glyphs when something is.
// Click for the panel: an Alerts tab (a line per alert, worst first; click one for its full text and
// instructions; outlooks; Kp at a glance; feed freshness) and a Kp tab (a day back, three ahead).
// The place is Omarchy's weather location; the panel's search sets it.
BarWidget {
  id: root
  moduleName: "buschbrian.weather-alerts"

  property var alerts: null
  property bool alertsOpen: false
  property string selectedAlertId: ""
  readonly property var selectedAlert: alertPanel && selectedAlertId ? alertPanel.alerts.find(function(a) { return a.id === selectedAlertId }) || null : null
  onAlertsOpenChanged: if (!alertsOpen) { selectedAlertId = ""; tab = 0 }
  property real nowMs: Date.now()
  readonly property var alertPanel: alerts ? alerts.panel : null
  readonly property string script: decodeURIComponent(Qt.resolvedUrl("bin/weather-alerts").toString().replace(/^file:\/\//, ""))
  readonly property bool notifications: setting("notifications", true) !== false
  readonly property int refreshMinutes: Math.max(5, Math.min(60, Number(setting("refreshMinutes", 5)) || 5))
  readonly property var fetchArgs: notifications ? ["python3", script] : ["python3", script, "--no-notify"]
  readonly property string idleGlyph: "\udb80\udc26"
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // Design tokens, shared with the night-sky panel: one glyph size and column, two text tones, theme spacing.
  readonly property real iconSize: Style.font.iconSmall
  readonly property real iconBox: Style.space(14)
  readonly property color muted: Qt.darker(fg, 1.5)
  readonly property real sectionGap: Style.spacing.xxl
  readonly property real itemGap: Style.spacing.sm
  property int tab: 0
  readonly property var tabs: ["Alerts", "Kp"]

  function rgba(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  function feedsLine() {
    if (!alertPanel) return ""
    return "Updated · " + alertPanel.sources.map(function(s) {
      return s.name + " " + (s.error ? "couldn't check" : s.updated ? ago(s.updated) : "never") + (s.stale ? " (stale)" : "")
    }).join(" · ")
  }
  readonly property bool feedTrouble: alertPanel !== null && alertPanel.sources.some(function(s) { return s.error || s.stale })

  function severityColor(severity) {
    if (severity === "Extreme") return "#d64545"
    if (severity === "Severe") return "#e07a3a"
    if (severity === "Moderate") return "#e3b341"
    if (severity === "Minor") return "#6fa8dc"
    return Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.5)
  }

  function kpColor(kp) {
    if (kp >= 7) return "#c24bd6"
    if (kp >= 6) return "#e0457b"
    if (kp >= 5) return "#e08a3a"
    if (kp >= 4) return "#d9c34a"
    return "#4caf7a"
  }

  function ago(iso) {
    if (!iso) return ""
    var m = Math.round((root.nowMs - new Date(iso).getTime()) / 60000)
    return m < 1 ? "just now" : m < 60 ? m + "m ago" : Math.round(m / 60) + "h ago"
  }

  function details() {
    alertsOpen = false
    if (root.bar) root.bar.run("omarchy-launch-tui --app-id=TUI.float python3 \"" + script + "\" --show --pager")
  }

  IpcHandler {
    target: "buschbrian.weather-alerts"
    function toggle(): void { root.alertsOpen = !root.alertsOpen }
    function showAlert(id: string): void { root.selectedAlertId = id; root.alertsOpen = true; alertScroll.contentY = 0 }
    function showTab(index: int): void { root.selectedAlertId = ""; root.tab = Math.max(0, Math.min(root.tabs.length - 1, index)); root.alertsOpen = true; alertScroll.contentY = 0 }
  }

  Item {
    id: alertsOwner
    function close() { root.alertsOpen = false }
  }

  // ---- Location: search with Omarchy's geocoder, save through omarchy-weather-location (weather-alerts
  //      --set-location). That is Omarchy's own weather location, so changing it here changes it for Omarchy's
  //      weather pill and any other plugin that reads it. Nothing is written until a place is chosen.
  property bool editingPlace: false
  property var placeResults: []
  property string placeMessage: ""
  property var geocodeArgs: []
  property var setPlaceArgs: []
  onEditingPlaceChanged: { placeResults = []; placeMessage = ""; if (editingPlace) Qt.callLater(function() { placeSearch.text = ""; placeSearch.forceActiveFocus() }) }
  function searchPlaces(query) {
    if (query.trim().length < 2) { placeResults = []; return }
    geocodeArgs = ["python3", script, "--geocode", query.trim()]
    if (!geocodeProc.running) geocodeProc.running = true
  }
  function choosePlace(place) {
    placeMessage = "Saving " + place.label + "…"
    setPlaceArgs = ["python3", script, "--set-location", place.name, "--lat", String(place.lat), "--lon", String(place.lon)]
    setPlaceProc.running = true
  }

  Timer { id: geocodeDebounce; interval: 350; onTriggered: root.searchPlaces(placeSearch.text) }
  Process {
    id: geocodeProc
    command: root.geocodeArgs
    onExited: if (JSON.stringify(root.geocodeArgs) !== JSON.stringify(["python3", root.script, "--geocode", placeSearch.text.trim()])) root.searchPlaces(placeSearch.text)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.placeResults = JSON.parse(text) } catch (e) { root.placeResults = [] }
        root.placeMessage = root.placeResults.length ? "" : "No places found."
      }
    }
  }
  Process {
    id: setPlaceProc
    command: root.setPlaceArgs
    onExited: function(code) {
      if (code === 0) { root.editingPlace = false; alertProc.running = true }
      else root.placeMessage = "Could not save that location."
    }
  }

  Process {
    id: alertFetch
    command: root.fetchArgs
    onExited: if (!alertProc.running) alertProc.running = true
  }

  Timer {
    interval: 60 * 1000
    running: root.alertsOpen
    repeat: true
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  function open() { alertsOpen = true }
  function close() { alertsOpen = false }

  visible: true
  implicitWidth: row.implicitWidth
  implicitHeight: row.implicitHeight

  Process {
    id: alertProc
    command: ["python3", root.script, "--bar"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { try { root.alerts = JSON.parse(text) } catch (e) { root.alerts = null } }
    }
  }

  Timer {
    interval: 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!alertProc.running) alertProc.running = true
  }

  // The fetch that notifies and fills the cache. It only runs while the shell does.
  Timer {
    interval: root.refreshMinutes * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!alertFetch.running) alertFetch.running = true
  }

  Row {
    id: row
    anchors.fill: parent
    spacing: 0

    WidgetButton {
      bar: root.bar
      text: root.alerts && root.alerts.text !== "" ? root.alerts.text : root.idleGlyph
      active: root.alerts !== null && root.alerts.class === "critical"
      horizontalMargin: 6
      tooltipText: root.alertsOpen ? "" : (root.alerts ? root.alerts.tooltip : "Weather alerts")
      onPressed: function(b) {
        if (b === Qt.RightButton) root.details()
        else root.alertsOpen = !root.alertsOpen
      }
    }
  }

  // KeyboardPanel, not PopupCard: an xdg-popup never receives keys, and the location search needs them.
  KeyboardPanel {
    id: alertPopup
    anchorItem: root
    bar: root.bar
    owner: alertsOwner
    open: root.alertsOpen && root.alertPanel !== null
    focusTarget: alertFocus
    contentWidth: alertPopup.fittedContentWidth(Style.space(360))
    contentHeight: alertPopup.fittedContentHeight(alertColumn.implicitHeight, Style.space(560))

    FocusScope {
      id: alertFocus
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: if (root.editingPlace) root.editingPlace = false; else alertsOwner.close()

    Flickable {
      id: alertScroll
      anchors.fill: parent
      contentWidth: width
      contentHeight: alertColumn.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height
      QQC.ScrollBar.vertical: QQC.ScrollBar {
        policy: QQC.ScrollBar.AsNeeded
        visible: alertScroll.contentHeight > alertScroll.height + 2
        contentItem: Rectangle { implicitWidth: Style.space(4); radius: width / 2; color: root.fg; opacity: 0.5 }
      }

    Column {
      id: alertColumn
      width: alertScroll.width - Style.space(8)
      spacing: root.sectionGap

      // ---- Title on the left; place, fetch and full text on the right
      Item {
        width: parent.width
        height: Math.max(titleText.implicitHeight, headerControls.implicitHeight)

        Text {
          id: titleText
          anchors.verticalCenter: parent.verticalCenter
          text: "Alerts"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Row {
          id: headerControls
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.xxs
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "󰍎"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: root.iconSize
          }
          TextChoice {
            anchors.verticalCenter: parent.verticalCenter
            rightPadding: Style.spacing.xs
            bottomPadding: 0
            text: root.alertPanel && root.alertPanel.place ? root.alertPanel.place : "Set a place"
            ruled: false
            selected: root.editingPlace
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onActivated: root.editingPlace = !root.editingPlace
          }
          Button {
            iconText: "󰑐"
            iconSize: root.iconSize
            horizontalPadding: Style.spacing.xs
            verticalPadding: Style.spacing.xxs
            foreground: root.fg
            tooltipText: "Fetch now"
            focusable: true
            iconSpinning: alertFetch.running
            onClicked: if (!alertFetch.running) alertFetch.running = true
          }
          Button { iconText: "󰈙"; iconSize: root.iconSize; horizontalPadding: Style.spacing.xs; verticalPadding: Style.spacing.xxs; foreground: root.fg; tooltipText: "Full text"; focusable: true; onClicked: root.details() }
        }
      }

      // ---- Location search: type a place and pick one
      Column {
        width: parent.width
        spacing: root.itemGap
        visible: root.editingPlace

        PanelSectionHeader { text: "Place for alerts (Omarchy's weather location)"; foreground: root.fg; fontFamily: root.fontFamily }
        TextField {
          id: placeSearch
          width: parent.width
          placeholderText: "Search a city, park or landmark"
          foreground: root.fg
          onTextChanged: geocodeDebounce.restart()
          Keys.onEscapePressed: root.editingPlace = false
          Keys.onReturnPressed: if (root.placeResults.length) root.choosePlace(root.placeResults[0])
        }
        Repeater {
          model: root.placeResults
          TextChoice {
            required property var modelData
            text: modelData.label + "  " + modelData.lat.toFixed(2) + ", " + modelData.lon.toFixed(2)
            ruled: false
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            enabled: !setPlaceProc.running
            onActivated: root.choosePlace(modelData)
          }
        }
        Text {
          width: parent.width
          text: root.placeMessage !== "" ? root.placeMessage : "Enter picks the first match. This sets Omarchy's weather location."
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      // ---- One alert opened in full
      Column {
        width: parent.width
        spacing: root.itemGap
        visible: root.selectedAlert !== null

        TextChoice {
          text: "‹ all alerts"
          ruled: false
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onActivated: { root.selectedAlertId = ""; alertScroll.contentY = 0 }
        }
        Row {
          width: parent.width
          spacing: Style.spacing.sm
          Text {
            width: root.iconBox
            text: root.selectedAlert ? root.selectedAlert.icon : ""
            color: root.selectedAlert ? root.severityColor(root.selectedAlert.severity) : root.fg
            font.family: root.fontFamily
            font.pixelSize: root.iconSize
            anchors.verticalCenter: detailTitle.verticalCenter
          }
          Text {
            id: detailTitle
            width: parent.width - root.iconBox - parent.spacing
            text: root.selectedAlert ? root.selectedAlert.event : ""
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            wrapMode: Text.WordWrap
          }
        }
        Text {
          width: parent.width
          text: root.selectedAlert ? root.selectedAlert.headline : ""
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
        Text {
          width: parent.width
          text: root.selectedAlert ? [root.selectedAlert.severity, root.selectedAlert.urgency, root.selectedAlert.source,
                  root.selectedAlert.until ? "until " + root.selectedAlert.until : "", root.selectedAlert.full_area]
                  .filter(function(x) { return x && x !== "Unknown" }).join(" · ") : ""
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
        PanelSectionHeader {
          visible: root.selectedAlert !== null && root.selectedAlert.instruction !== ""
          text: "What to do"
          foreground: root.fg
          fontFamily: root.fontFamily
        }
        Text {
          width: parent.width
          visible: root.selectedAlert !== null && root.selectedAlert.instruction !== ""
          text: root.selectedAlert ? root.selectedAlert.instruction.replace(/([^\n])\n(?![\n*])/g, "$1 ") : ""
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
        }
        PanelSectionHeader { text: "Details"; foreground: root.fg; fontFamily: root.fontFamily }
        Text {
          width: parent.width
          // NWS hard-wraps its text; rejoin lines inside a paragraph, keeping blank lines and "* WHAT..." bullets.
          text: root.selectedAlert ? root.selectedAlert.text.replace(/([^\n])\n(?![\n*])/g, "$1 ") : ""
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
        }
      }

      // ---- Tabs over a hairline
      Item {
        width: parent.width
        height: tabRow.implicitHeight
        visible: !root.selectedAlert
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.rgba(root.fg, 0.12) }
        Row {
          id: tabRow
          spacing: Style.spacing.xxxl
          Repeater {
            model: root.tabs
            TextChoice {
              required property var modelData
              required property int index
              text: index === 0 && root.alertPanel && root.alertPanel.alerts.length ? modelData + " " + root.alertPanel.alerts.length : modelData
              selected: root.tab === index
              foreground: root.fg
              fontFamily: root.fontFamily
              onActivated: { root.tab = index; alertScroll.contentY = 0 }
            }
          }
        }
      }

      // ================= Alerts: one line each, worst first; Kp at a glance; feed health
      Column {
        width: parent.width
        spacing: root.itemGap
        visible: !root.selectedAlert && root.tab === 0

        Text {
          width: parent.width
          visible: root.alertPanel !== null && root.alertPanel.alerts.length === 0
          text: root.alertPanel && root.alertPanel.degraded ? "Could not confirm whether all feeds are clear."
                : root.alertPanel && root.alertPanel.coverage === "none" ? "No place set. Click \"Set a place\" above to see NWS alerts and outlooks."
                : "No active alerts."
          color: root.alertPanel && root.alertPanel.degraded ? Color.urgent : root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: root.alertPanel !== null && root.alertPanel.coverage === "outside"
          text: "NWS alerts and outlooks cover the United States only. Storm alerts and Kp still work for this place."
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Repeater {
          model: root.alertPanel && !root.selectedAlert ? root.alertPanel.alerts : []

          Item {
            id: card
            required property var modelData
            readonly property color tone: root.severityColor(modelData.severity)
            width: alertColumn.width
            height: cardBody.implicitHeight + Style.spacing.sm * 2
            activeFocusOnTab: true
            Keys.onReturnPressed: { root.selectedAlertId = modelData.id; alertScroll.contentY = 0 }

            // Hover and focus wash, from the severity colour on the left.
            Rectangle {
              anchors.fill: parent
              radius: Style.space(5)
              visible: cardArea.containsMouse || card.activeFocus
              gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: root.rgba(card.tone, 0.16) }
                GradientStop { position: 1; color: root.rgba(card.tone, 0) }
              }
            }

            Row {
              id: cardBody
              x: Style.spacing.xs
              width: parent.width - Style.spacing.xs * 2
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.sm

              Text {
                width: root.iconBox
                text: card.modelData.icon
                color: card.tone
                font.family: root.fontFamily
                font.pixelSize: root.iconSize
              }

              Column {
                width: cardBody.width - root.iconBox - cardBody.spacing
                spacing: Style.spacing.xxs

                Item {
                  width: parent.width
                  height: eventLine.implicitHeight
                  Text {
                    id: eventLine
                    width: parent.width - leftText.implicitWidth - Style.spacing.md
                    elide: Text.ElideRight
                    textFormat: Text.StyledText
                    text: "<b>" + card.modelData.event + "</b>&nbsp;&nbsp;<font color=\"" + card.tone + "\">"
                          + [card.modelData.severity, card.modelData.urgency].filter(function(x) { return x && x !== "Unknown" }).join(" · ")
                          + "</font>"
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    id: leftText
                    anchors.right: parent.right
                    text: card.modelData.left || (card.modelData.until ? "until " + card.modelData.until : "")
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                // Time: onset → until, filled as it runs out.
                Rectangle {
                  width: parent.width
                  height: Style.space(2)
                  radius: height / 2
                  visible: card.modelData.progress !== null
                  color: root.rgba(root.fg, 0.1)
                  Rectangle {
                    width: parent.width * (card.modelData.progress || 0)
                    height: parent.height
                    radius: height / 2
                    gradient: Gradient {
                      orientation: Gradient.Horizontal
                      GradientStop { position: 0; color: root.rgba(card.tone, 0.3) }
                      GradientStop { position: 1; color: card.tone }
                    }
                  }
                }
              }
            }

            MouseArea {
              id: cardArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: if (root.bar) root.bar.showTooltip(card, card.modelData.headline)
              onExited: if (root.bar) root.bar.hideTooltip(card)
              onClicked: { if (root.bar) root.bar.hideTooltip(card); root.selectedAlertId = card.modelData.id; alertScroll.contentY = 0 }
            }
          }
        }

        // National-centre outlooks covering the place: context, not warnings.
        Column {
          width: parent.width
          spacing: Style.spacing.xs
          topPadding: Style.spacing.sm
          visible: root.alertPanel !== null && root.alertPanel.outlooks !== undefined && root.alertPanel.outlooks.length > 0
          PanelSectionHeader { text: "Outlooks"; foreground: root.fg; fontFamily: root.fontFamily }
          Repeater {
            model: root.alertPanel && root.alertPanel.outlooks ? root.alertPanel.outlooks : []
            Item {
              id: outlookRow
              required property var modelData
              readonly property color tone: root.severityColor(modelData.severity)
              width: alertColumn.width
              height: outlookText.implicitHeight
              Row {
                x: Style.spacing.xs
                width: parent.width - Style.spacing.xs * 2
                spacing: Style.spacing.sm
                Text { width: root.iconBox; text: outlookRow.modelData.icon; color: outlookRow.tone; font.family: root.fontFamily; font.pixelSize: root.iconSize }
                Text {
                  id: outlookText
                  width: parent.width - root.iconBox - centreText.implicitWidth - parent.spacing * 2
                  elide: Text.ElideRight
                  textFormat: Text.StyledText
                  text: outlookRow.modelData.product + "&nbsp;&nbsp;<font color=\"" + outlookRow.tone + "\">" + outlookRow.modelData.level + "</font>"
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Text { id: centreText; text: outlookRow.modelData.centre; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              }
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onEntered: if (root.bar) root.bar.showTooltip(outlookRow, outlookRow.modelData.centre + " · " + outlookRow.modelData.product
                                                            + "\n" + outlookRow.modelData.level + (outlookRow.modelData.when ? "\n" + outlookRow.modelData.when : ""))
                onExited: if (root.bar) root.bar.hideTooltip(outlookRow)
              }
            }
          }
        }

        // Kp at a glance; the chart is on the Kp tab.
        TextChoice {
          visible: root.alertPanel !== null && root.alertPanel.kp.length > 0
          textFormat: Text.StyledText
          text: root.alertPanel ? "Kp now " + (root.alertPanel.kp_now !== null
                  ? "<font color=\"" + root.kpColor(root.alertPanel.kp_now) + "\">" + root.alertPanel.kp_now.toFixed(1) + "</font>" : "–")
                + (root.alertPanel.kp_forecast_peak ? " · forecast peak <font color=\"" + root.kpColor(root.alertPanel.kp_forecast_peak.kp) + "\">"
                  + root.alertPanel.kp_forecast_peak.kp.toFixed(1) + "</font> "
                  + Qt.formatDateTime(new Date(root.alertPanel.kp_forecast_peak.time + "Z"), "ddd HH:mm") : "") + " ›" : ""
          ruled: false
          selected: true
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onActivated: { root.tab = 1; alertScroll.contentY = 0 }
        }

        Text {
          width: parent.width
          text: root.feedsLine()
          color: root.feedTrouble ? Color.urgent : root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      // ================= Kp: a day of observations and the three-day forecast
      Column {
        width: parent.width
        spacing: root.itemGap
        visible: !root.selectedAlert && root.tab === 1

        Text {
          width: parent.width
          visible: !root.alertPanel || root.alertPanel.kp.length === 0
          text: "No Kp data yet."
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Grid {
          id: kpGrid
          width: parent.width
          columns: 3
          columnSpacing: Style.spacing.lg
          visible: root.alertPanel !== null && root.alertPanel.kp.length > 0
          Repeater {
            model: root.alertPanel ? [
              { label: "Now", kp: root.alertPanel.kp_now, time: null },
              { label: "Observed peak", kp: root.alertPanel.kp_observed_peak ? root.alertPanel.kp_observed_peak.kp : null,
                time: root.alertPanel.kp_observed_peak ? root.alertPanel.kp_observed_peak.time : null },
              { label: "Forecast peak", kp: root.alertPanel.kp_forecast_peak ? root.alertPanel.kp_forecast_peak.kp : null,
                time: root.alertPanel.kp_forecast_peak ? root.alertPanel.kp_forecast_peak.time : null }
            ] : []
            Column {
              id: kpCell
              required property var modelData
              width: (kpGrid.width - kpGrid.columnSpacing * 2) / 3
              Text { text: kpCell.modelData.label; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              Text {
                textFormat: Text.StyledText
                text: kpCell.modelData.kp === null || kpCell.modelData.kp === undefined ? "–"
                      : "<font color=\"" + root.kpColor(kpCell.modelData.kp) + "\"><b>" + kpCell.modelData.kp.toFixed(1) + "</b></font>"
                        + (kpCell.modelData.time ? "&nbsp;" + Qt.formatDateTime(new Date(kpCell.modelData.time + "Z"), "ddd HH:mm") : "")
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        Canvas {
          id: kpCanvas
          width: parent.width
          height: Style.space(84)
          visible: root.alertPanel !== null && root.alertPanel.kp.length > 0
          property var rows: root.alertPanel ? root.alertPanel.kp : []
          property real now: root.nowMs
          property bool shown: visible
          onRowsChanged: requestPaint()
          onNowChanged: requestPaint()
          onWidthChanged: requestPaint()
          onShownChanged: requestPaint()
          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            if (!rows.length) return
            var w = width, h = height - Style.space(12), n = rows.length
            var bw = w / n
            var y = function(kp) { return h - kp / 9 * h }
            ctx.font = Style.font.caption + "px '" + root.fontFamily + "'"

            ctx.fillStyle = root.rgba(root.fg, 0.04)
            ctx.fillRect(0, 0, w, h)
            ctx.strokeStyle = root.rgba(root.fg, 0.12)
            ctx.lineWidth = 1
            for (var g = 3; g <= 9; g += 3) { ctx.beginPath(); ctx.moveTo(0, y(g)); ctx.lineTo(w, y(g)); ctx.stroke() }

            // Bars rise from the floor in their Kp colour and fade toward it; forecast bins are lighter.
            var day = ""
            for (var i = 0; i < n; i++) {
              var r = rows[i]
              var t = new Date(r.time + "Z")
              var top = y(Math.max(r.kp, 0.3))
              var tone = Qt.lighter(root.kpColor(r.kp), 1)
              var bar = ctx.createLinearGradient(0, top, 0, h)
              bar.addColorStop(0, root.rgba(tone, 1)); bar.addColorStop(1, root.rgba(tone, 0.25))
              ctx.globalAlpha = r.observed === "predicted" ? 0.55 : 1
              ctx.fillStyle = bar
              ctx.fillRect(i * bw + 1, top, bw - 2, h - top)
              ctx.globalAlpha = 1
              var d = Qt.formatDate(t, "ddd")
              if (d !== day && t.getHours() < 3) {
                day = d
                ctx.strokeStyle = root.rgba(root.fg, 0.2)
                ctx.beginPath(); ctx.moveTo(i * bw, 0); ctx.lineTo(i * bw, h); ctx.stroke()
                ctx.fillStyle = root.rgba(root.fg, 0.6)
                ctx.textAlign = "left"
                ctx.fillText(d, i * bw + 3, height - 1)
              }
            }

            // Kp 5 is a G1 storm; Kp 6 (G2) is the level this widget alerts on.
            ctx.setLineDash([4, 3])
            ctx.strokeStyle = root.kpColor(6)
            ctx.beginPath(); ctx.moveTo(0, y(6)); ctx.lineTo(w, y(6)); ctx.stroke()
            ctx.setLineDash([])
            ctx.fillStyle = root.kpColor(6)
            ctx.textAlign = "right"
            ctx.fillText("Kp 6", w - 2, y(6) - 3)

            var t0 = new Date(rows[0].time + "Z").getTime()
            var at = (now - t0) / (3 * 3600 * 1000) * bw
            if (at >= 0 && at <= w) {
              ctx.strokeStyle = Color.urgent
              ctx.lineWidth = 2
              ctx.beginPath(); ctx.moveTo(at, 0); ctx.lineTo(at, h); ctx.stroke()
            }
          }
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          text: "Solid: observed / estimated · faded: forecast · 3-hour bins · red line: now. Dashed line: Kp 6 (G2), the level this widget alerts on. Seeing aurora also depends on your latitude, darkness, clouds and a clear horizon toward the pole."
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
    }
    }
  }
}
