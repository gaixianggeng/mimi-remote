#!/usr/bin/env bash
set -euo pipefail

# iOS 字号门禁。
#
# 这个脚本守的是**一件事**：字号必须能跟随用户的全局字号设置（`ThemeStore.fontScale`），
# 否则相邻的图标与文字在用户拖动字号滑块后会散掉光学配比。这是功能性缺陷，不是审美偏好。
#
# 它**不**守「所有字号都必须落在档位表内」。档位表是正文语义档的词汇表，不是所有
# 图形的合法取值集合：12×12 状态槽里的感叹号、固定 44×44 格子里的 emoji、按容器直径
# 推导的头像首字母，它们的尺寸由容器决定，用档位表表达反而会溢出。
# 这里只要求这类偏离**有名字、写下用途、并且不增长**。
#
# 用法：
#   bash ./scripts/check-ios-typography.sh              # 门禁检查（CI 用）
#   bash ./scripts/check-ios-typography.sh --self-test  # 只跑检测器自检
#   bash ./scripts/check-ios-typography.sh --report     # 打印当前分布，不做判定

python3 - "$@" <<'PY'
from pathlib import Path
import collections
import re
import sys

ROOT = Path("ios/MimiRemote/Sources")
THEME_STORE = "State/ThemeStore.swift"

# 与 ThemeStore.baseSize(for:) 保持一致。改这里之前先改那里。
TIER = {
    "largeTitle": 34, "title": 28, "title2": 22, "title3": 20, "headline": 17,
    "subheadline": 15, "callout": 16, "footnote": 13, "caption": 12,
    "caption2": 11, "body": 17,
}
# 档位表里的点数。裸字面量若等于其中之一，说明它本就是档位值，只是没写成档位名。
SCALE = sorted(set(TIER.values()))

# ─────────────────────────────────────────────────────────────────────────────
# 豁免表
#
# 两级，都按**值**登记而不是按行号：行号会随任何一次编辑漂移，值不会。
# 每条的计数是当前实测处数，作用是「冻结现状」——
# 需要新增一处时，必须在同一个提交里改这个数字，于是它在 review 里必然可见。
# ─────────────────────────────────────────────────────────────────────────────

# `.system(size: <裸数字>)`：完全绕过 ThemeStore，不跟随 fontScale。
# 只该用在「本来就与用户字号无关」的图形上。
BARE_SYSTEM_SIZE = {
    17: ("ConversationReturnToTailButton 是只接收 tokens 的叶子控件，未为一行字号加依赖注入", 1),
    24: ("emoji 字形填满固定选择格，再乘缩放会溢出容器", 1),
    26: ("同上：emoji 填满 44x44 选择格", 1),
    42: ("扫码页整页装饰性图标：与相邻原生 Text 同屏，单独接入 fontScale 会造成图标放大而文字不动", 1),
    44: ("同上", 1),
}

# `uiFont(size: <裸数字>)` 中 N 不在档位表内。
# 注意 14pt 是历史上使用最广的「非档位」值（21 处），分布在侧栏与列表的次级文本上；
# 它既不是仪器字形、也没写成档位名，是**待收敛**的对象，登记在这里只是冻结现状，
# 不代表它已被认可。真正该做的是逐处判定归 13 还是 15（见施工图 6.2 节）。
OFF_SCALE_SIZE = {
    7: ("侧栏状态槽 12x12 内的感叹号字形", 1),
    8: ("模型选择器紧凑态上下箭头", 1),
    9: ("徽标 / 角标数字与小型状态字形", 12),
    10: ("小组件角标", 5),
    10.5: ("侧栏次级说明文字", 1),
    14: ("待收敛：次级文本，需逐处判定归 13 或 15", 21),
    18: ("图标与装饰字形（非正文）", 5),
    19: ("图标与装饰字形（非正文）", 4),
    24: ("空态与装饰性大图标", 4),
    26: ("装饰性字形", 2),
}

# 整文件豁免：该文件内所有 .system(size:) 同因，且原因与用户字号无关。
FILE_EXEMPT = {
    "Features/Conversation/MarkdownStyle.swift":
        "内部 scaled() 已乘 fontScale，全文件同因",
    "Features/Settings/ShareJourneyView.swift":
        "分享海报按 proxy.size.width / 360 等比渲染，与用户字号无关，全文件同因",
}

# ─────────────────────────────────────────────────────────────────────────────
# 检测器
# ─────────────────────────────────────────────────────────────────────────────

CALL = re.compile(r"\.system\(|\buiFont\(|\bcodeFont\(")
LABEL = re.compile(r"size:\s*")


def _first_argument(text, start):
    """返回 `size:` 之后第一个顶层逗号/右括号之前的内容（跨行安全）。"""
    depth = 0
    buf = []
    i = start
    while i < len(text):
        ch = text[i]
        if ch in "([":
            depth += 1
        elif ch in ")]":
            if depth == 0:
                break
            depth -= 1
        elif ch == "," and depth == 0:
            break
        buf.append(ch)
        i += 1
    return "".join(buf).strip()


def _in_line_comment(text, offset):
    head = text[text.rfind("\n", 0, offset) + 1:offset]
    return "//" in head


def scan(text):
    """产出 (行号, 类别, 值, 原始实参)。"""
    for match in CALL.finditer(text):
        if _in_line_comment(text, match.start()):
            continue
        call = text[match.start():match.start() + 400]
        label = LABEL.search(call)
        if not label:
            continue
        chunk = " ".join(_first_argument(call, label.end()).split())
        line = text.count("\n", 0, match.start()) + 1

        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", chunk):
            # 非字面量：容器推导、海报比例、scaled() 包装、具名常量。
            # 具名常量有名字可审查；表达式由容器尺寸决定，再乘缩放会溢出。
            # 规则不判定它们——这是有意的，不是漏检。但具名常量的**值**会被
            # --report 列出来，否则「改用常量」就成了绕过档位表的后门。
            if re.fullmatch(r"[A-Za-z_][\w.]*", chunk):
                yield line, "named_const", chunk, chunk
            else:
                yield line, "named_expr", chunk, chunk
        elif call.startswith(".system("):
            yield line, "bare_system", float(chunk), chunk
        else:
            yield line, "bare_theme", float(chunk), chunk


def violations(text):
    """单文件判定：值是否已登记。计数在 check_table_usage() 里全局比对。"""
    out = []
    for line, kind, value, raw in scan(text):
        if kind == "bare_system" and value not in BARE_SYSTEM_SIZE:
            out.append(
                f"用了 .system(size: {raw})，绕过 ThemeStore 的字号缩放。"
                f" 改用 themeStore.uiFont(...)；若它本就与用户字号无关（按容器尺寸推导、"
                f"填固定格子等），在 BARE_SYSTEM_SIZE 登记该值并写明用途。"
            )
        elif kind == "bare_theme" and value not in SCALE and value not in OFF_SCALE_SIZE:
            out.append(
                f"uiFont(size: {raw}) 不在档位表 {SCALE} 内。"
                f" 正文语义字号请改用 themeStore.uiFont(.footnote) 这类档位名；"
                f"若这是仪器/角标字形（尺寸由容器决定），在 OFF_SCALE_SIZE 登记该值"
                f"并写明用途。"
            )
    return out


def check_offline_themecount(counts):
    """裸 uiFont(size: N) 未写成档位名 —— 允许，但公布数量，防止它重新发散。"""
    return sum(n for (k, v), n in counts.items() if k == "bare_theme")


def check_stale_entries(counts):
    """登记了却对不上实测 = 失效的豁免，必须删掉或改数。"""
    errors = []
    for table, limits, key in (
        ("BARE_SYSTEM_SIZE", BARE_SYSTEM_SIZE, "bare_system"),
        ("OFF_SCALE_SIZE", OFF_SCALE_SIZE, "bare_theme"),
    ):
        for value, (_, allowed) in sorted(limits.items()):
            actual = counts.get((key, value), 0)
            if actual == 0:
                errors.append(f"{table} 登记了 {value:g}pt，但全项目已无此用法。请删除该条目。")
            elif actual != allowed:
                errors.append(
                    f"{table} 登记 {value:g}pt 为 {allowed} 处，实测 {actual} 处。"
                    f" 请把计数改为实测值。"
                )
    return errors


# ─────────────────────────────────────────────────────────────────────────────
# 自检：门禁自己也要被测。每条 fixture 都必须被检出（或必须被放行）。
# ─────────────────────────────────────────────────────────────────────────────

FIXTURES = [
    ("单行裸 .system(size:)",   '.font(.system(size: 14))',                            True),
    ("跨行裸 .system(size:)",   '.font(.system(\n    size: 14\n))',                    True),
    ("跨行表外 uiFont(size:)",  'let f = themeStore.uiFont(\n    size: 13.7,\n)',      True),
    ("单行表外 uiFont(size:)",  '.font(themeStore.uiFont(size: 13.7))',                True),
    ("裸 .system 但值是档位值", '.font(.system(size: 13))',                            True),
    ("档位内 uiFont(size:)",    '.font(themeStore.uiFont(size: 15, weight: .bold))',   False),
    ("语义档 uiFont(.)",        '.font(themeStore.uiFont(.footnote, weight: .bold))',  False),
    ("已登记的 9pt 角标",       '.font(themeStore.uiFont(size: 9, weight: .bold))',    False),
    ("具名常量",                '.font(themeStore.uiFont(size: SettingsLayoutMetrics.symbolPointSize))', False),
    ("容器推导",                '.font(.system(size: avatarDiameter * 0.58))',          False),
    ("海报比例",                '.font(.system(size: 22 * scale, weight: .bold))',      False),
    ("scaled() 包装",           '.system(size: scaled(17))',                            False),
    ("注释里的调用",            '// .font(.system(size: 14))\nlet x = 1',               False),
    ("三目表达式",              '.font(.system(size: isFloating ? 24 : 18, weight: .medium))', False),
]


def self_test():
    failures = []
    for name, code, should_flag in FIXTURES:
        flagged = bool(violations(code))
        if flagged != should_flag:
            failures.append(
                f"  自检失败：{name}（期望违规={should_flag}，实际={flagged}）"
            )
    return failures


def collect_counts():
    counts = collections.Counter()
    for path in sorted(ROOT.rglob("*.swift")):
        rel = str(path.relative_to(ROOT))
        if rel == THEME_STORE or rel in FILE_EXEMPT:
            continue
        for _, kind, value, _ in scan(path.read_text()):
            if kind in ("bare_system", "bare_theme"):
                counts[(kind, value)] += 1
    return counts


def named_constants():
    """具名常量形式的字号。它们绕过档位表检查，所以要把名字和定义值都摆出来审查。"""
    found = {}
    for path in sorted(ROOT.rglob("*.swift")):
        rel = str(path.relative_to(ROOT))
        if rel == THEME_STORE or rel in FILE_EXEMPT:
            continue
        text = path.read_text()
        names = {value for _, kind, value, _ in scan(text) if kind == "named_const"}
        for name in names:
            member = name.split(".")[-1]
            pattern = (
                rf"\b(?:let|var)\s+{re.escape(member)}\b"
                rf"(?:\s*:\s*CGFloat)?"
                rf"(?:\s*\{{[^}}]*?)?"
                rf"\s*=?\s*([0-9]+(?:\.[0-9]+)?)"
            )
            for m in re.finditer(pattern, text):
                found.setdefault(f"{rel}:{member}", set()).add(float(m.group(1)))
    return found


if __name__ == "__main__":
    args = set(sys.argv[1:])
    counts = collect_counts()

    if "--report" in args:
        for kind in ("bare_system", "bare_theme"):
            for (k, value), count in sorted(counts.items()):
                if k != kind:
                    continue
                if k == "bare_system":
                    state = "已登记" if value in BARE_SYSTEM_SIZE else "★未登记"
                elif value in SCALE:
                    state = "档位值"
                elif value in OFF_SCALE_SIZE:
                    state = "已登记"
                else:
                    state = "★未登记"
                print(f"{k:>12}  {value:>6g}pt  {count:>3} 处  {state}")
        print("\n具名常量形式的字号（有名字可审查，规则不判定；列出定义值供人判读）：")
        for key, values in sorted(named_constants().items()):
            shown = ", ".join(
                f"{v:g}{'' if v in SCALE else '★'}" for v in sorted(values)
            )
            print(f"    {key}  = {shown}")
        print("    （★ = 不在档位表内，是待收敛项，不是已认可的例外）")
        sys.exit(0)

    problems = self_test()
    if "--self-test" in args:
        if problems:
            print("iOS 字号门禁：检测器自检失败", file=sys.stderr)
            for problem in problems:
                print(problem, file=sys.stderr)
            sys.exit(1)
        print("iOS 字号门禁：检测器自检通过")
        sys.exit(0)

    errors = list(problems)
    for path in sorted(ROOT.rglob("*.swift")):
        rel = str(path.relative_to(ROOT))
        if rel == THEME_STORE or rel in FILE_EXEMPT:
            continue
        for message in violations(path.read_text()):
            errors.append(f"{rel}: {message}")
    errors.extend(check_stale_entries(counts))

    if errors:
        print("iOS 字号门禁失败：", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        sys.exit(1)

    bare_system = sum(n for (k, _), n in counts.items() if k == "bare_system")
    print(
        f"iOS 字号门禁通过"
        f"（.system 裸字面量 {bare_system} 处已登记；"
        f"裸 uiFont(size: N) {check_offline_themecount(counts)} 处待更名为档位名）"
    )
PY
