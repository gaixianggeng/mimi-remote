#!/usr/bin/env python3
"""Remove the former inline QR hooks from a user-owned Omarchy tray clone."""

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


def legacy_hooks():
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


def atomic_write(path, data):
    fd, temporary = tempfile.mkstemp(prefix=".mimi-qr-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(data)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def uninstall(plugin):
    plugin = plugin.resolve()
    user_plugins = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "omarchy/plugins"
    if not plugin.is_relative_to(user_plugins.resolve()):
        raise ValueError("只允许修改用户目录中的 Omarchy 托盘副本。")
    tray = plugin / "Tray.qml"
    source = tray.read_text()
    if ROOT_PROPERTIES not in source:
        return
    for before, after in reversed(legacy_hooks()):
        if source.count(after) != 1:
            raise ValueError("旧适配代码已变化，未写入；请先人工检查 Tray.qml。")
        source = source.replace(after, before, 1)
    atomic_write(tray, source)
    # The former component may still be loaded by a running shell. Leave it
    # and the user's pre-install backup in place.


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plugin", type=Path, help="用户 Omarchy 托盘插件目录")
    parser.add_argument("--uninstall", action="store_true")
    args = parser.parse_args()
    if args.uninstall:
        try:
            uninstall(args.plugin)
        except (OSError, ValueError) as error:
            parser.exit(1, str(error) + "\n")
        print("已移除旧版 Omarchy 二维码适配。")
    else:
        print("请在托盘中选择“生成并复制配对链接”。卸载旧版适配请使用 --uninstall。")
