import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs
import Quickshell
import qs.Commons
import qs.Ui

// Shared 4x4 grid, used both by the bar's compact dropdown (BarPopup.qml)
// and the standalone floating tile (Tile.qml). All state lives on `service`
// (the plugin's Service.qml singleton), so pad assignments and stream-mode
// status stay in sync between the two surfaces.
Item {
  id: root

  required property var service
  property bool compact: false
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  property bool editMode: false

  // Emitted when the pop-out button is clicked (dropdown only) — the host
  // (BarPopup.qml) closes itself in response, since summoning the tile is a
  // one-way handoff, not something Board itself owns.
  signal popOutRequested()

  readonly property int cellSize: compact ? Style.space(64) : Style.space(108)
  readonly property int cellSpacing: compact ? Style.space(10) : Style.space(14)
  // The grid's natural width — the whole card is pinned to exactly this
  // width and then centered as a block, so the header/toggle row (which
  // spans the same width) and the pad grid always line up, with any extra
  // room in a bigger tile window going evenly around the outside instead of
  // pinning everything to the top-left corner.
  readonly property real cardWidth: 4 * cellSize + 3 * cellSpacing

  implicitWidth: cardWidth
  implicitHeight: column.implicitHeight

  function urlToPath(url) {
    var s = url.toString()
    if (s.indexOf("file://") === 0) s = s.substring(7)
    return decodeURIComponent(s)
  }

  function popOutToTile() {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "bert.dropdeck", "{}"])
    root.popOutRequested()
  }

  ColumnLayout {
    id: column
    anchors.centerIn: parent
    width: root.cardWidth
    spacing: root.compact ? Style.space(14) : Style.space(18)

    RowLayout {
      Layout.fillWidth: true
      Layout.bottomMargin: Style.space(2)
      spacing: Style.space(12)

      Text {
        text: "Dropdeck"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        Layout.fillWidth: true
      }

      PanelActionButton {
        visible: root.compact
        iconText: "↗"
        tooltipText: "Open as window"
        foreground: root.foreground
        onClicked: root.popOutToTile()
      }

      PanelActionButton {
        iconText: root.editMode ? "✓" : "✎"
        tooltipText: root.editMode ? "Done editing" : "Assign sounds"
        foreground: root.foreground
        bordered: root.editMode
        onClicked: root.editMode = !root.editMode
      }

      PanelActionButton {
        iconText: "⏹"
        tooltipText: "Stop all"
        foreground: root.foreground
        onClicked: root.service.stopAll()
      }
    }

    // Stream-mode status card. Deliberately loud about its state: the whole
    // card fills with the accent tint and grows an accent border when live,
    // with a solid dot + LIVE / OFF word, so a glance mid-stream is enough.
    // The switch binds to the service's optimistic `streamModeDesired`, so the
    // knob throws immediately on click and the poller keeps it truthful.
    Rectangle {
      id: streamCard
      Layout.fillWidth: true
      Layout.bottomMargin: Style.space(4)

      readonly property bool on: root.service ? root.service.streamModeOn : false
      readonly property bool busy: root.service ? root.service.streamModeBusy : false

      radius: Style.cornerRadius
      implicitHeight: streamRow.implicitHeight + Style.space(root.compact ? 16 : 20)
      color: on ? Style.selectedFillFor(root.foreground, root.accent) : "transparent"
      border.width: 1
      border.color: on ? root.accent : Qt.darker(root.foreground, 1.9)

      Behavior on color { ColorAnimation { duration: 140 } }
      Behavior on border.color { ColorAnimation { duration: 140 } }

      RowLayout {
        id: streamRow
        anchors.fill: parent
        anchors.margins: Style.space(root.compact ? 8 : 10)
        spacing: Style.space(root.compact ? 9 : 11)

        Rectangle {
          id: streamDot
          Layout.alignment: Qt.AlignVCenter
          width: Style.space(10)
          height: Style.space(10)
          radius: width / 2
          opacity: 1
          color: streamCard.on ? root.accent : Qt.darker(root.foreground, 1.7)
          Behavior on color { ColorAnimation { duration: 140 } }

          SequentialAnimation {
            id: streamDotPulse
            running: streamCard.on
            loops: Animation.Infinite
            alwaysRunToEnd: true
            onStopped: streamDot.opacity = 1
            NumberAnimation { target: streamDot; property: "opacity"; to: 0.3; duration: 700; easing.type: Easing.InOutSine }
            NumberAnimation { target: streamDot; property: "opacity"; to: 1.0; duration: 700; easing.type: Easing.InOutSine }
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(2)

          RowLayout {
            spacing: Style.space(8)

            Text {
              text: "Stream mode"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Text {
              text: streamCard.busy ? "…" : (streamCard.on ? "LIVE" : "OFF")
              color: streamCard.on ? root.accent : Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
          }

          Text {
            // In the compact dropdown the dot + LIVE/OFF word + switch already
            // carry the state; only keep the longer line when there's room
            // (the tile) or when live, where the "pick Dropdeck-Mic"
            // reminder is worth the height.
            visible: !root.compact || streamCard.on
            Layout.fillWidth: true
            text: streamCard.on
              ? "Pick “Dropdeck-Mic” as your mic in Restream"
              : "Mixes pads + mic into a virtual mic for Restream"
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
            wrapMode: Text.WordWrap
          }
        }

        ToggleSwitch {
          Layout.alignment: Qt.AlignVCenter
          checked: root.service ? root.service.streamModeDesired : false
          busy: streamCard.busy
          foreground: root.foreground
          accent: root.accent
          onToggled: if (root.service) root.service.toggleStreamMode()
        }
      }
    }

    // Which mic feeds the stream mix. Tile only — the popup wants a real
    // window, and it's a set-it-once choice, not a mid-stream control. Empty
    // value = follow whatever's the system default when stream mode flips on;
    // a pinned device stays put (USB mic for streaming, laptop mic still the
    // default for calls). Changing it while live rebuilds the mix in place.
    RowLayout {
      visible: !root.compact
      Layout.fillWidth: true
      Layout.bottomMargin: Style.space(4)
      spacing: Style.space(10)

      Text {
        text: "Mic"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.alignment: Qt.AlignVCenter
      }

      Dropdown {
        Layout.fillWidth: true
        showLabel: false
        fontFamily: root.fontFamily
        accent: root.accent
        value: root.service ? root.service.micSource : ""
        options: {
          var opts = [{ value: "", label: "System default mic" }]
          var list = root.service ? root.service.inputSources : []
          var pinned = root.service ? root.service.micSource : ""
          var seen = false
          for (var i = 0; i < list.length; i++) {
            opts.push({ value: list[i].value, label: list[i].label })
            if (list[i].value === pinned) seen = true
          }
          // Pinned mic that isn't currently plugged in: keep it selectable
          // with a readable label instead of dumping the raw node name.
          if (pinned !== "" && !seen)
            opts.push({ value: pinned, label: "Pinned mic (not connected)" })
          return opts
        }
        onChanged: if (root.service) root.service.setMicSource(value)
      }
    }

    GridLayout {
      id: grid
      columns: 4
      rowSpacing: root.cellSpacing
      columnSpacing: root.cellSpacing

      Repeater {
        model: root.service ? root.service.padCount : 16

        Rectangle {
          id: pad
          required property int index
          readonly property var padData: root.service ? root.service.padAt(index) : { path: "", label: "Pad " + (index + 1) }
          readonly property bool assigned: padData.path !== ""
          readonly property bool playing: root.service ? root.service.playing[index] === true : false

          Layout.preferredWidth: root.cellSize
          Layout.preferredHeight: root.cellSize
          radius: Style.cornerRadius
          color: playing
            ? Style.selectedFillFor(root.foreground, root.accent)
            : (assigned ? Style.normalFillFor(root.foreground, root.accent) : "transparent")
          border.width: assigned ? 0 : 1
          border.color: Qt.darker(root.foreground, 1.8)

          Behavior on color { ColorAnimation { duration: 100 } }

          Text {
            anchors.centerIn: parent
            width: parent.width - Style.space(14)
            text: pad.assigned ? pad.padData.label : "+"
            color: pad.assigned ? root.foreground : Qt.darker(root.foreground, 1.6)
            font.family: root.fontFamily
            font.pixelSize: pad.assigned ? Style.font.bodySmall : Style.font.title
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            elide: Text.ElideRight
            maximumLineCount: 2
          }

          PanelActionButton {
            visible: root.editMode && pad.assigned
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: Style.space(3)
            size: Style.space(16)
            fontSize: Style.space(11)
            iconText: "×"
            foreground: root.foreground
            hoverColor: root.accent
            onClicked: root.service.clearPad(pad.index)
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (root.editMode) {
                fileDialog.targetIndex = pad.index
                fileDialog.open()
              } else if (root.service) {
                root.service.play(pad.index)
              }
            }

            PanelToolTip {
              visible: root.editMode && parent.containsMouse
              text: "Choose a sound file"
              fontFamily: root.fontFamily
            }
          }
        }
      }
    }
  }

  FileDialog {
    id: fileDialog
    property int targetIndex: -1
    title: "Choose a sound"
    // Force the pure-QML file dialog rather than the native (GTK3) one.
    // The native chooser's dconf/GVFS background threads have crashed the
    // whole shell process twice in testing (SIGSEGV / SIGABRT deep in
    // libglib/libgio, both triggered right as the native dialog opened) —
    // an upstream GTK3-platformtheme-in-a-foreign-event-loop issue, not
    // something fixable from here. The QML dialog never touches GTK/dconf.
    options: FileDialog.DontUseNativeDialog
    nameFilters: ["Audio files (*.mp3 *.wav *.ogg *.opus *.flac *.aiff)", "All files (*)"]
    onAccepted: {
      if (root.service && targetIndex >= 0) root.service.assign(targetIndex, root.urlToPath(selectedFile))
      targetIndex = -1
    }
  }
}
