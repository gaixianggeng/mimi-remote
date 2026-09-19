#!/usr/bin/env bash
set -euo pipefail

# 字号必须走 ThemeStore 的档位表，否则用户的全局字号设置对它无效，
# 且档位会持续发散。豁免项必须写进 allowlist 并注明原因。

python3 - <<'PY'
from pathlib import Path
import re
import sys

ROOT = Path("ios/MimiRemote/Sources")
# 与 ThemeStore.baseSize(for:) 保持一致。改这里之前先改那里。
SCALE = {11, 12, 13, 15, 16, 17, 20, 22, 28, 34}

# 整文件豁免：该文件内所有 .system(size:) 都有同一个正当理由。
# 只有"全文件同因"才配用这一级；否则用下面的按行豁免。
SYSTEM_FONT_FILE_ALLOWLIST = {
    "Features/Conversation/MarkdownStyle.swift":
        "内部 scaled() 已乘 fontScale，全文件同因",
    "Features/Settings/ShareJourneyView.swift":
        "分享海报按 proxy.size.width/360 等比渲染，与用户字号无关，全文件同因",
}

# 按行豁免：同一文件里只有个别位置该豁免，其余仍须走 ThemeStore。
# 行号会漂移，每次改动这些文件后必须核对本表——下面的 validate_allowlist()
# 会在条目失效（行号不再指向 .system(size:)）时直接报错，避免豁免悄悄落空。
SYSTEM_FONT_LINE_ALLOWLIST = {
    "Features/Projects/WorkspaceAppearancePickers.swift:126":
        "emoji 字形填满固定 44x44 选择格，再乘缩放会溢出",
    "Features/Projects/WorkspaceAppearancePickers.swift:159":
        "同上（P1 已人工确认）",
    "Features/Shell/HostSwitcherMenu.swift:428":
        "头像首字母按容器直径推导 size*8/9",
    "Features/Shell/HostSwitcherMenu.swift:455":
        "头像首字母按容器直径推导 size*8/9",
    "Features/Settings/SettingsDetailViews.swift:914":
        "头像首字母按 avatarDiameter 推导",
    "Features/Projects/WorkspaceRootView.swift:83":
        "工作区头像首字母按容器直径推导 size*0.58",
    "Features/Projects/WorkspaceDetailView.swift:492":
        "浮动按钮图标按浮起状态切换固定尺寸",
    "Features/Conversation/Timeline/ConversationTimelineView.swift:902":
        "回到底部按钮是只接收 tokens 的叶子控件，P1 不为一行字号给它加注入（已知遗留）",
}

# 允许留在表外的字号，每条都要写原因。
SIZE_ALLOWLIST = {
    "Features/Settings/QRCodeScannerSheet.swift:148":
        "扫码页主视觉图标：44 → largeTitle(34) 会缩掉 23%，是肉眼可见的缩水，保留原值",
    "Features/Settings/QRCodeScannerSheet.swift:175":
        "同上（与 148 统一成 44）",
}

errors = []
system_font = re.compile(r"\.system\(size:")
ui_font_literal = re.compile(r"uiFont\(size:\s*([0-9]+(?:\.[0-9]+)?)")

# 豁免表本身就是文档，条目指向的行必须先确实是 .system(size:)，
# 否则说明行号已经漂移，真正的违规点会绕过豁免却不被发现。
lines_by_path = {}
seen_allowlist_keys = set()
for key in SYSTEM_FONT_LINE_ALLOWLIST:
    rel, _, lineno = key.rpartition(":")
    path = ROOT / rel
    if not path.is_file():
        errors.append(f"{key} 豁免表指向的文件不存在。")
        continue
    lines = lines_by_path.setdefault(path, path.read_text().splitlines())
    index = int(lineno)
    if index < 1 or index > len(lines) or not system_font.search(lines[index - 1]):
        errors.append(
            f"{key} 的豁免行已经不是 .system(size:) 了。"
            f" 行号漂移后必须重新核对 SYSTEM_FONT_LINE_ALLOWLIST，"
            f"否则真正的违规点会绕过豁免。"
        )
        continue
    seen_allowlist_keys.add(key)

for path in sorted(ROOT.rglob("*.swift")):
    rel = str(path.relative_to(ROOT))
    if rel == "State/ThemeStore.swift":
        continue
    for lineno, line in enumerate(path.read_text().splitlines(), 1):
        key = f"{rel}:{lineno}"
        if (
            system_font.search(line)
            and rel not in SYSTEM_FONT_FILE_ALLOWLIST
            and key not in seen_allowlist_keys
        ):
            errors.append(
                f"{key} 直接用了 .system(size:)，绕过 ThemeStore 的字号缩放。"
                f" 改用 themeStore.uiFont(...)，或加进 SYSTEM_FONT_LINE_ALLOWLIST 并注明原因。"
            )
        for match in ui_font_literal.finditer(line):
            value = float(match.group(1))
            if value not in SCALE and key not in SIZE_ALLOWLIST:
                errors.append(
                    f"{key} 字号 {match.group(1)}pt 不在档位表 {sorted(SCALE)} 内。"
                    f" 归到最接近的档位（相等时取大），或加进 SIZE_ALLOWLIST 并注明原因。"
                )

if errors:
    print("iOS 字号门禁失败：", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    sys.exit(1)

print("iOS 字号门禁通过")
PY
