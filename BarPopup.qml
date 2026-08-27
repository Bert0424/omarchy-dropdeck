import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Compact dropdown content, opened by clicking the bar pill. Mirrors the
// standard bar-widget popup shape (see e.g. the first-party audio/weather
// panels): a Panel base for open/close lifecycle, a KeyboardPanel for the
// layer-shell popup, PanelKeyCatcher for Esc/Tab.
Panel {
  id: root
  moduleName: "bert.dropdeck"
  ipcTarget: "bert.dropdeck"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    root.controller.show()
  }
  function openFromHotkey() {
    root.open()
  }
  function close() {
    root.controller.hide()
  }
  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(board.implicitWidth + Style.space(36))
    contentHeight: panel.fittedContentHeight(board.implicitHeight + Style.space(36))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Board {
        id: board
        anchors.fill: parent
        anchors.margins: Style.space(18)
        service: root.service
        compact: true
        foreground: root.bar ? root.bar.foreground : Color.foreground
        accent: Color.accent
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        onPopOutRequested: root.close()
      }
    }
  }
}
