import QtQuick
import qs.Commons
import qs.Ui

// Bar pill. Left click toggles the compact dropdown grid; middle click
// stops everything currently playing.
BarWidget {
  id: root
  moduleName: "bert.dropdeck"

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.service
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }
  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }
  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("BarPopup.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  readonly property bool streamLive: service ? service.streamModeOn === true : false

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "🔊"
    horizontalMargin: 8.5
    // Recolours the icon while the Restream virtual mic is wired up, so the
    // bar always says whether pads are going out over the stream.
    active: root.streamLive
    tooltipText: root.streamLive ? "Dropdeck — stream mode LIVE" : "Dropdeck"

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.MiddleButton) { if (root.service) root.service.stopAll() }
      else root.togglePanel()
    }

    Rectangle {
      visible: root.streamLive
      width: Style.space(6)
      height: Style.space(6)
      radius: width / 2
      color: Color.accent
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: Style.space(4)
      anchors.rightMargin: Style.space(3)

      SequentialAnimation on opacity {
        running: root.streamLive
        loops: Animation.Infinite
        alwaysRunToEnd: true
        NumberAnimation { to: 0.3; duration: 700; easing.type: Easing.InOutSine }
        NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutSine }
      }
    }
  }
}
