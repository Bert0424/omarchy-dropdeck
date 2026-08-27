import QtQuick
import Quickshell
import qs.Commons

// Standalone "tile": a real, ordinary window (not a layer-shell popup), so
// Hyprland can tile or float it like any other app while you record. Summon
// with: omarchy-shell shell summon bert.dropdeck '{}' (or toggle/hide the
// same way — see plugins/README.md's IPC contract).
Item {
  id: root

  // Host injections (see shell/README.md's manifest/IPC contract).
  property var shell: null
  property var manifest: null
  property var service: null

  property bool closingFromHost: false

  function open(payloadJson) {
    closingFromHost = false
    window.visible = true
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide("bert.dropdeck")
    else window.visible = false
  }

  FloatingWindow {
    id: window
    // Explicit default: this plugin isn't keepLoaded, but a stray future
    // manifest change (or a host that mounts panel components eagerly)
    // should never make FloatingWindow's own visible-by-default show a
    // window nobody asked for.
    visible: false
    title: "Dropdeck"
    color: Color.background
    implicitWidth: Style.space(620)
    implicitHeight: Style.space(600)
    minimumSize: Qt.size(460, 460)

    onVisibleChanged: {
      if (!visible && !root.closingFromHost) root.requestClose()
    }

    FocusScope {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onEscapePressed: root.requestClose()

      Board {
        anchors.fill: parent
        anchors.margins: Style.space(26)
        service: root.service
        compact: false
        foreground: Color.foreground
        accent: Color.accent
        fontFamily: Style.font.family
      }
    }
  }
}
