#!/usr/bin/env python3
"""Opt-in, reversible hooks for a user-owned Omarchy tray clone."""

import argparse
import os
from pathlib import Path
import tempfile


ROOT_PROPERTIES = '''  // Mimi Remote inline pairing (optional desktop adapter).
  readonly property bool mimiPairingMenu: activeTrayItem && activeTrayItem.id === "mimi-remote"
  readonly property bool mimiPairingExpanded: {
    if (!mimiPairingMenu) return false
    var entries = currentChildren.values
    for (var i = 0; i < entries.length; i++)
      if (String(entries[i].text).indexOf("收起 ") === 0) return true
    return false
  }
'''

ROW_PROPERTIES = '''              readonly property bool mimiPairImage: root.mimiPairingMenu && rowText === "用 Mimi Remote 扫码"
              readonly property bool mimiPairAction: root.mimiPairingMenu &&
                (/^(展开 |收起 ).+ 二维码$/.test(rowText) || rowText === "重新生成二维码")
'''

IMAGE = '''              MimiPairingQR {
                visible: menuRow.mimiPairImage && root.trayMenuOpen
                width: parent.width
                imageSource: String(menuRow.modelData.icon || "")
              }

'''


def replacements():
    # All anchors must match once before writing anything. A changed host fails
    # with a useful error instead of silently modifying an unrelated delegate.
    return [
        ('  property bool trayMenuOpen: false\n', '  property bool trayMenuOpen: false\n' + ROOT_PROPERTIES),
        ('contentWidth: trayMenuPopup.fittedContentWidth(Style.space(232))',
         'contentWidth: trayMenuPopup.fittedContentWidth(Style.space(root.mimiPairingExpanded ? 300 : 232))'),
        ('trayMenuColumn.implicitHeight, Style.space(420))',
         'trayMenuColumn.implicitHeight, root.mimiPairingExpanded ? trayMenuPopup.availableCardHeight : Style.space(420))'),
        ('              readonly property string rowText: String(modelData.text || "")\n',
         '              readonly property string rowText: String(modelData.text || "")\n' + ROW_PROPERTIES),
        ('implicitHeight: hiddenRow ? 0 : (modelData.isSeparator ? Style.space(11) : Style.space(30))',
         'implicitHeight: hiddenRow ? 0 : (mimiPairImage ? width : (modelData.isSeparator ? Style.space(11) : Style.space(30)))'),
        ('              opacity: modelData.enabled ? 1.0 : 0.45',
         '              opacity: mimiPairImage || modelData.enabled ? 1.0 : 0.45'),
        ('              Image {\n                id: menuIcon',
         IMAGE + '              Image {\n                id: menuIcon'),
        ('visible: !menuRow.modelData.isSeparator && String(menuRow.modelData.icon || "") !== ""',
         'visible: !menuRow.mimiPairImage && !menuRow.modelData.isSeparator && String(menuRow.modelData.icon || "") !== ""'),
        ('textFormat: Text.PlainText\n                visible: !menuRow.modelData.isSeparator\n',
         'textFormat: Text.PlainText\n                visible: !menuRow.mimiPairImage && !menuRow.modelData.isSeparator\n'),
        ('                    menuRow.modelData.triggered()\n                    root.close()',
         '                    var keepOpen = menuRow.mimiPairAction\n                    menuRow.modelData.triggered()\n                    if (!keepOpen) root.close()'),
    ]


def transform(source, uninstall=False):
    pairs = replacements()
    if uninstall:
        pairs = [(after, before) for before, after in reversed(pairs)]
    for before, after in pairs:
        if source.count(before) != 1:
            raise ValueError("托盘结构或适配代码已变化，未写入；请先人工检查 Tray.qml。")
        source = source.replace(before, after, 1)
    return source


def atomic_write(path, data):
    fd, temporary = tempfile.mkstemp(prefix=".mimi-qr-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(data)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def install(plugin, uninstall=False):
    plugin = plugin.resolve()
    user_plugins = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "omarchy/plugins"
    if not plugin.is_relative_to(user_plugins.resolve()):
        raise ValueError("只允许修改用户目录中的 Omarchy 托盘副本；请先运行 omarchy plugin clone omarchy.tray。")
    tray, image = plugin / "Tray.qml", plugin / "MimiPairingQR.qml"
    source = tray.read_text()
    asset = Path(__file__).resolve().parent.parent / "packaging/linux/omarchy/MimiPairingQR.qml"
    expected_image = asset.read_text()
    installed = ROOT_PROPERTIES in source
    if image.exists() and image.read_text() != expected_image:
        raise ValueError("MimiPairingQR.qml 已有本地改动，未覆盖。")
    if installed == (not uninstall):
        if installed:
            transform(source, uninstall=True)  # Check every hook, not just the marker.
            atomic_write(image, expected_image)
        return
    changed = transform(source, uninstall)
    backup = plugin / "Tray.qml.before-mimi-qr"
    if not backup.exists():
        atomic_write(backup, source)
    if not uninstall:
        atomic_write(image, expected_image)
    atomic_write(tray, changed)
    # Keep the unused component on uninstall: an in-flight shell reload can
    # still be evaluating the old delegate. It contains no user/ticket data.


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plugin", type=Path, help="用户 Omarchy 托盘插件目录")
    parser.add_argument("--uninstall", action="store_true")
    args = parser.parse_args()
    try:
        install(args.plugin, args.uninstall)
    except (OSError, ValueError) as error:
        parser.exit(1, str(error) + "\n")
    print("Omarchy 二维码适配已" + ("移除" if args.uninstall else "安装") + "；托盘保留原有定制。")
