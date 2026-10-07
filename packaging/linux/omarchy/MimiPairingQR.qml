import QtQuick
import Quickshell

// The PNG arrives over DBusMenu's icon-data property. No ticket file or URL.
Item {
  id: root
  required property string imageSource
  readonly property real pixelRatio: QsWindow.window ? QsWindow.window.devicePixelRatio : 1
  readonly property int modules: qr.sourceSize.width > 0 ? qr.sourceSize.width / 6 : 1
  readonly property int modulePixels: Math.max(1, Math.floor(width * pixelRatio / modules))
  readonly property real side: modules * modulePixels / pixelRatio
  implicitHeight: width

  Image {
    id: qr
    anchors.centerIn: parent
    width: root.side
    height: width
    source: root.visible ? root.imageSource : ""
    cache: false
    smooth: false
    mipmap: false
    asynchronous: false
    Accessible.name: "用 Mimi Remote 扫描配对二维码"
    Accessible.role: Accessible.Graphic
  }
}
