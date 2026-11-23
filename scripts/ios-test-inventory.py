#!/usr/bin/env python3
"""MimiRemoteTests 用例清单与 selector 完整性检查。

xcodebuild 对不存在的 `-only-testing` 类名或方法名不会报错，而是静默执行 0 个
用例并报告通过；多个 `*Tests.swift` 文件又只是 `ConversationDataFlowTests` 的
extension，按文件名写 selector 同样会落空。本脚本直接解析测试源码，按真实类名
（含 extension 与继承）统计 `func test…()`，并据此校验：

- PR 集合（scripts/test-conversation-regressions.sh 的 -only-testing）里每个
  selector 都指向真实的测试类与现存方法；
- 每个含用例的 XCTestCase 类都归属 PR 集合（整类）或每晚集合
  （config/ios-tests/nightly-classes.txt）之一；
- 隔离清单（config/ios-tests/quarantine.tsv）每条都指向现存方法，并写明原因、
  负责人和 Issue；
- 测试目录下的每个 Swift 文件都已登记进 Xcode 工程，不会写了却从未编译。

`verify-results` 子命令读取 `xcrun xcresulttool get test-results tests` 的 JSON，
按类比较实际执行数与静态清单，任何一个应执行的类执行 0 个、或执行数与清单不一致
都判失败，用于每晚全量任务。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
TEST_DIR = Path("ios/MimiRemote/Tests/MimiRemoteTests")
PROJECT_FILE = Path("ios/MimiRemote/MimiRemote.xcodeproj/project.pbxproj")
PR_RUNNER = Path("scripts/test-conversation-regressions.sh")
NIGHTLY_MANIFEST = Path("config/ios-tests/nightly-classes.txt")
QUARANTINE_FILE = Path("config/ios-tests/quarantine.tsv")
TEST_BUNDLE = "MimiRemoteTests"
SNAPSHOT_DIR_NAME = "__Snapshots__"
TEST_METHOD_NAME = re.compile(r"^test[A-Za-z0-9_]*$")

TYPE_KEYWORDS = ("class", "struct", "enum", "actor", "extension", "protocol")
NON_TYPE_NAMES = {"var", "let", "func", "subscript", "init", "deinit", "case", "static", "class"}
TYPE_HEADER = re.compile(
    r"(?:^|\n)[ \t]*"
    r"(?:(?:@[A-Za-z_][\w.]*(?:\([^()\n]*\))?|public|private|fileprivate|internal|open|final|indirect|nonisolated)\s+)*"
    r"(class|struct|enum|actor|extension|protocol)\s+([A-Za-z_][\w.]*)"
    r"(?:\s*<[^{]*?>)?"
    r"(?:\s*:\s*([^{]*?))?\s*(?:\bwhere\b[^{]*)?$",
    re.S,
)
RAW_STRING_START = re.compile(r"#+\"")
FUNC_DECL = re.compile(r"\bfunc\s+(test\w*)\s*\(\s*\)")
SELECTOR = re.compile(r"-only-testing:" + TEST_BUNDLE + r"/([A-Za-z_]\w*)(?:/([A-Za-z_]\w*))?")
ISSUE_REF = re.compile(r"^#\d+$")
OWNER_REF = re.compile(r"^@[A-Za-z0-9-]+$")


def strip_comments_and_strings(source: str) -> str:
    """把注释与字符串字面量替换成空格（保留换行），只留下代码结构里的括号。"""
    out: list[str] = []
    i = 0
    n = len(source)

    def blank(text: str) -> None:
        out.append("".join("\n" if ch == "\n" else " " for ch in text))

    while i < n:
        ch = source[i]
        if source.startswith("//", i):
            end = source.find("\n", i)
            end = n if end == -1 else end
            blank(source[i:end])
            i = end
        elif source.startswith("/*", i):
            depth = 0
            j = i
            while j < n:
                if source.startswith("/*", j):
                    depth += 1
                    j += 2
                elif source.startswith("*/", j):
                    depth -= 1
                    j += 2
                    if depth == 0:
                        break
                else:
                    j += 1
            blank(source[i:j])
            i = j
        elif ch == '"' or (ch == "#" and RAW_STRING_START.match(source, i)):
            j = skip_string_literal(source, i)
            blank(source[i:j])
            i = j
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def skip_string_literal(source: str, start: int) -> int:
    """返回字符串字面量结束后的位置；支持原始字符串、多行字符串和插值嵌套。"""
    n = len(source)
    i = start
    hashes = 0
    while i < n and source[i] == "#":
        hashes += 1
        i += 1
    multiline = source.startswith('"""', i)
    quote = '"""' if multiline else '"'
    i += len(quote)
    terminator = quote + "#" * hashes
    escape = "\\" + "#" * hashes
    while i < n:
        if source.startswith(terminator, i):
            return i + len(terminator)
        if source.startswith(escape, i):
            k = i + len(escape)
            if k < n and source[k] == "(":
                i = skip_interpolation(source, k)
                continue
            i = k + 1
            continue
        if not multiline and source[i] == "\n":
            return i
        i += 1
    return n


def skip_interpolation(source: str, open_paren: int) -> int:
    depth = 0
    i = open_paren
    n = len(source)
    while i < n:
        ch = source[i]
        if ch == '"' or (ch == "#" and RAW_STRING_START.match(source, i)):
            i = skip_string_literal(source, i)
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


@dataclass
class TypeInfo:
    name: str
    bases: list[str] = field(default_factory=list)
    methods: dict[str, str] = field(default_factory=dict)
    files: set[str] = field(default_factory=set)
    declared_as_class: bool = False


def scan_file(path: Path, root: Path, types: dict[str, TypeInfo]) -> None:
    rel = path.relative_to(root).as_posix()
    code = strip_comments_and_strings(path.read_text(encoding="utf-8"))
    # 每个作用域记录 (类型名或 None)。func 只有直接位于类型体内才算成员方法。
    stack: list[str | None] = []
    header_start = 0
    i = 0
    n = len(code)
    while i < n:
        ch = code[i]
        if ch == "{":
            header = code[header_start:i].strip()
            match = TYPE_HEADER.search(header)
            type_name: str | None = None
            if match and match.group(2) not in NON_TYPE_NAMES:
                keyword, raw_name, inheritance = match.group(1), match.group(2), match.group(3)
                type_name = raw_name.split(".")[-1] if keyword == "extension" else raw_name
                if stack and keyword != "extension":
                    # 嵌套类型不参与 XCTest 发现，按 Outer.Inner 记录以免与顶层同名类型混淆。
                    outer = next((s for s in reversed(stack) if s), None)
                    type_name = f"{outer}.{raw_name}" if outer else raw_name
                info = types.setdefault(type_name, TypeInfo(type_name))
                info.files.add(rel)
                if keyword == "class":
                    info.declared_as_class = True
                    if inheritance:
                        info.bases = [
                            part.strip().split("<")[0].split(".")[-1]
                            for part in inheritance.split(",")
                            if part.strip()
                        ]
            stack.append(type_name)
            header_start = i + 1
        elif ch == "}":
            if stack:
                stack.pop()
            header_start = i + 1
        elif ch == ";":
            header_start = i + 1
        elif ch == "f" and code.startswith("func", i) and (i == 0 or not (code[i - 1].isalnum() or code[i - 1] == "_")):
            match = FUNC_DECL.match(code, i)
            owner = stack[-1] if stack else None
            line_prefix = code[code.rfind("\n", 0, i) + 1 : i]
            if match and owner and not re.search(r"\b(static|class)\b", line_prefix):
                types[owner].methods.setdefault(match.group(1), rel)
        i += 1


class Inventory:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.types: dict[str, TypeInfo] = {}
        self.swift_files = sorted((root / TEST_DIR).rglob("*.swift"))
        for path in self.swift_files:
            scan_file(path, root, self.types)
        self.test_classes, self.test_method_files = self._resolve_test_classes()

    def _resolve_test_classes(self) -> tuple[dict[str, list[str]], dict[str, dict[str, str]]]:
        cache: dict[str, bool] = {}

        def is_test_case(name: str, seen: frozenset[str] = frozenset()) -> bool:
            if name == "XCTestCase":
                return True
            if name in cache:
                return cache[name]
            info = self.types.get(name)
            if not info or not info.declared_as_class or not info.bases or name in seen:
                cache[name] = False
                return False
            result = is_test_case(info.bases[0], seen | {name})
            cache[name] = result
            return result

        def all_methods(name: str) -> dict[str, str]:
            info = self.types[name]
            inherited: dict[str, str] = {}
            if info.bases and info.bases[0] in self.types and is_test_case(info.bases[0]):
                inherited = all_methods(info.bases[0])
            return {**inherited, **info.methods}

        classes: dict[str, list[str]] = {}
        method_files: dict[str, dict[str, str]] = {}
        for name, info in self.types.items():
            if "." in name or not info.declared_as_class:
                continue
            if is_test_case(name):
                resolved = all_methods(name)
                classes[name] = sorted(resolved)
                method_files[name] = resolved
        return classes, method_files

    def runnable_classes(self) -> dict[str, list[str]]:
        """含至少一个用例的测试类；无用例的基类不参与归属与执行数校验。"""
        return {name: methods for name, methods in self.test_classes.items() if methods}

    def file_class_hint(self, name: str) -> str:
        for path in self.swift_files:
            if path.stem == name:
                owners = sorted(
                    owner
                    for owner, info in self.types.items()
                    if path.relative_to(self.root).as_posix() in info.files and owner in self.test_classes
                )
                if owners:
                    return f"（{path.name} 里的用例属于 {', '.join(owners)}）"
        return ""


def read_manifest(path: Path) -> list[tuple[int, str]]:
    entries = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        text = line.split("#", 1)[0].strip()
        if text:
            entries.append((line_number, text))
    return entries


@dataclass
class QuarantineEntry:
    line: int
    class_name: str
    method: str
    reason: str
    owner: str
    issue: str

    @property
    def selector(self) -> str:
        return f"{self.class_name}/{self.method}"


def read_quarantine(path: Path, errors: list[str]) -> list[QuarantineEntry]:
    entries: list[QuarantineEntry] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        columns = [column.strip() for column in line.split("\t")]
        if len(columns) != 4:
            errors.append(
                f"{path}:{line_number} 需要 4 列（selector、原因、负责人、Issue，用 Tab 分隔），实际 {len(columns)} 列。"
            )
            continue
        selector, reason, owner, issue = columns
        if "/" not in selector:
            errors.append(f"{path}:{line_number} 只允许隔离单个方法（Class/testMethod），不能整类跳过：{selector}")
            continue
        class_name, method = selector.split("/", 1)
        if not reason:
            errors.append(f"{path}:{line_number} {selector} 缺少原因。")
        if not OWNER_REF.match(owner):
            errors.append(f"{path}:{line_number} {selector} 的负责人必须是 @GitHub 用户名，实际：{owner or '空'}")
        if not ISSUE_REF.match(issue):
            errors.append(f"{path}:{line_number} {selector} 的 Issue 必须写成 #编号，实际：{issue or '空'}")
        entries.append(QuarantineEntry(line_number, class_name, method, reason, owner, issue))
    return entries


SHELL_COMMENT = re.compile(r"(?:^|(?<=\s))#.*$")


def read_pr_selectors(path: Path) -> list[tuple[int, str, str | None]]:
    selectors = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        # 注释掉的 -only-testing 不会传给 xcodebuild，不能算作 PR 覆盖。
        active = SHELL_COMMENT.sub("", line)
        for match in SELECTOR.finditer(active):
            selectors.append((line_number, match.group(1), match.group(2)))
    return selectors


def project_registered_files(root: Path) -> set[str]:
    text = (root / PROJECT_FILE).read_text(encoding="utf-8")
    return set(re.findall(r"/\* ([^*/]+\.swift) in Sources \*/", text))


@dataclass
class Plan:
    inventory: Inventory
    pr_whole: set[str]
    pr_methods: dict[str, set[str]]
    nightly: set[str]
    quarantine: list[QuarantineEntry]
    errors: list[str]


def build_plan(root: Path) -> Plan:
    errors: list[str] = []
    inventory = Inventory(root)
    classes = inventory.test_classes
    runnable = inventory.runnable_classes()

    registered = project_registered_files(root)
    for path in inventory.swift_files:
        if path.name not in registered:
            errors.append(f"{path.relative_to(root)} 没有登记进 Xcode 工程的 Sources，里面的用例从不编译。")

    pr_whole: set[str] = set()
    pr_methods: dict[str, set[str]] = {}
    seen_selectors: set[tuple[str, str | None]] = set()
    for line_number, class_name, method in read_pr_selectors(root / PR_RUNNER):
        location = f"{PR_RUNNER}:{line_number}"
        if (class_name, method) in seen_selectors:
            errors.append(f"{location} 重复的 selector：{class_name}{'/' + method if method else ''}")
        seen_selectors.add((class_name, method))
        if class_name not in classes:
            errors.append(
                f"{location} selector 的类 {class_name} 不是 XCTestCase 类，xcodebuild 会静默执行 0 个用例"
                f"{inventory.file_class_hint(class_name)}。"
            )
            continue
        if method is None:
            if not classes[class_name]:
                errors.append(f"{location} {class_name} 没有任何用例，选中它等于空跑。")
            pr_whole.add(class_name)
        elif method not in classes[class_name]:
            errors.append(
                f"{location} {class_name}/{method} 指向不存在的方法，xcodebuild 会静默执行 0 个用例。"
            )
        else:
            pr_methods.setdefault(class_name, set()).add(method)
    for class_name in sorted(pr_whole & set(pr_methods)):
        errors.append(f"{PR_RUNNER} 已整类选择 {class_name}，又单独选择了它的方法，属于重复。")

    nightly: set[str] = set()
    nightly_path = root / NIGHTLY_MANIFEST
    if not nightly_path.is_file():
        errors.append(f"缺少每晚集合清单 {NIGHTLY_MANIFEST}。")
    else:
        for line_number, class_name in read_manifest(nightly_path):
            location = f"{NIGHTLY_MANIFEST}:{line_number}"
            if "/" in class_name:
                errors.append(f"{location} 每晚集合按整类登记，不写方法：{class_name}")
                continue
            if class_name in nightly:
                errors.append(f"{location} 重复登记 {class_name}。")
            if class_name not in runnable:
                errors.append(
                    f"{location} {class_name} 不是含用例的 XCTestCase 类{inventory.file_class_hint(class_name)}。"
                )
            elif class_name in pr_whole:
                errors.append(f"{location} {class_name} 已整类进入 PR 集合，不应再登记到每晚集合。")
            nightly.add(class_name)

    for class_name in sorted(runnable):
        if class_name in pr_whole or class_name in nightly:
            continue
        if class_name in pr_methods:
            errors.append(
                f"{class_name} 只有部分方法进入 PR 集合，其余用例必须登记到 {NIGHTLY_MANIFEST}。"
            )
        else:
            errors.append(
                f"{class_name} 既不在 PR 集合也不在每晚集合；把它加进 {PR_RUNNER} 或 {NIGHTLY_MANIFEST}。"
            )

    quarantine: list[QuarantineEntry] = []
    quarantine_path = root / QUARANTINE_FILE
    if not quarantine_path.is_file():
        errors.append(f"缺少隔离清单 {QUARANTINE_FILE}。")
    else:
        quarantine = read_quarantine(quarantine_path, errors)
        seen: set[str] = set()
        for entry in quarantine:
            location = f"{QUARANTINE_FILE}:{entry.line}"
            if entry.selector in seen:
                errors.append(f"{location} 重复隔离 {entry.selector}。")
            seen.add(entry.selector)
            if entry.class_name not in classes:
                errors.append(f"{location} {entry.class_name} 不是 XCTestCase 类{inventory.file_class_hint(entry.class_name)}。")
            elif entry.method not in classes[entry.class_name]:
                errors.append(f"{location} {entry.selector} 指向不存在的方法；用例已删除时同步移除隔离条目。")

    return Plan(inventory, pr_whole, pr_methods, nightly, quarantine, errors)


def command_check(args: argparse.Namespace) -> int:
    plan = build_plan(Path(args.root).resolve())
    runnable = plan.inventory.runnable_classes()
    total = sum(len(methods) for methods in runnable.values())
    pr_cases = sum(len(runnable[name]) for name in plan.pr_whole if name in runnable) + sum(
        len(methods) for methods in plan.pr_methods.values()
    )
    if plan.errors:
        for error in plan.errors:
            print(f"iOS 测试 selector 检查失败：{error}", file=sys.stderr)
        return 1
    print(
        f"iOS 测试 selector 检查通过：{len(runnable)} 个测试类、{total} 个用例；"
        f"PR 集合 {len(plan.pr_whole)} 个整类 + {sum(len(m) for m in plan.pr_methods.values())} 个方法"
        f"（{pr_cases} 个用例），每晚集合 {len(plan.nightly)} 个类，隔离 {len(plan.quarantine)} 条。"
    )
    return 0


def command_list(args: argparse.Namespace) -> int:
    plan = build_plan(Path(args.root).resolve())
    runnable = plan.inventory.runnable_classes()
    rows = []
    for name in sorted(runnable):
        if name in plan.pr_whole:
            scope = "pr"
        elif name in plan.pr_methods:
            scope = "pr-partial+nightly" if name in plan.nightly else "pr-partial"
        elif name in plan.nightly:
            scope = "nightly"
        else:
            scope = "unassigned"
        rows.append(
            {
                "class": name,
                "tests": len(runnable[name]),
                "prMethods": len(plan.pr_methods.get(name, ())),
                "scope": scope,
            }
        )
    if args.json:
        json.dump(rows, sys.stdout, ensure_ascii=False, indent=2)
        print()
    else:
        for row in rows:
            print(f"{row['class']}\t{row['tests']}\t{row['prMethods']}\t{row['scope']}")
    return 0


def command_skip_args(args: argparse.Namespace) -> int:
    errors: list[str] = []
    for entry in read_quarantine(Path(args.root).resolve() / QUARANTINE_FILE, errors):
        print(f"-skip-testing:{TEST_BUNDLE}/{entry.selector}")
    if errors:
        for error in errors:
            print(f"隔离清单格式错误：{error}", file=sys.stderr)
        return 1
    return 0


def collect_results(
    node: dict,
    results: dict[str, dict[str, str]],
    retried_passed: set[str],
    suite: str | None = None,
) -> None:
    node_type = node.get("nodeType")
    name = node.get("name", "")
    if node_type == "Test Suite":
        suite = name
    if node_type == "Test Case":
        identifier = node.get("nodeIdentifier", "")
        parts = identifier.split("/")
        class_name = parts[-2] if len(parts) >= 2 else (suite or "?")
        method = parts[-1] if parts else name
        method = re.sub(r"\(\)$", "", method)
        result = node.get("result", "unknown")
        results.setdefault(class_name, {})[method] = result
        # -retry-tests-on-failure 下，重试后通过的用例结果是 Passed，失败的那次以 Repetition 子节点保留。
        if result == "Passed" and any(
            child.get("nodeType") == "Repetition" and child.get("result") == "Failed"
            for child in node.get("children", []) or []
        ):
            retried_passed.add(f"{class_name}/{method}")
        return
    for child in node.get("children", []) or []:
        collect_results(child, results, retried_passed, suite)


def sanitize_display_text(text: str) -> str:
    return "".join(f"\\x{ord(ch):02x}" if ord(ch) < 32 or ord(ch) == 127 else ch for ch in text)


def escape_github_annotation(text: str) -> str:
    sanitized = sanitize_display_text(text)
    return sanitized.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


@dataclass(frozen=True)
class ParsedSnapshotPath:
    parent_subdirs: tuple[str, ...]
    folder: str
    method: str


def parse_snapshot_path(raw_path: str) -> tuple[ParsedSnapshotPath | None, str | None]:
    """路径安全地解析 SnapshotTesting 重录快照路径（<TEST_DIR>/[subdirs/]__Snapshots__/<folder>/<method>.<variant>.png）。"""
    if not raw_path:
        return None, "路径为空"
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in raw_path):
        return None, "路径包含控制字符"
    if "\\" in raw_path:
        return None, "路径包含反斜杠，不是规范 POSIX 相对路径"
    if raw_path.startswith("/") or raw_path.endswith("/"):
        return None, "路径必须是仓库相对文件路径"

    parts = raw_path.split("/")
    if any(seg in ("", ".", "..") for seg in parts):
        return None, "路径包含非法路径段（空段、. 或 ..）"

    test_dir_parts = TEST_DIR.parts
    if tuple(parts[: len(test_dir_parts)]) != test_dir_parts:
        return None, f"路径不在 {TEST_DIR.as_posix()} 下"

    rel_parts = parts[len(test_dir_parts) :]
    if len(rel_parts) < 3 or rel_parts[-3] != SNAPSHOT_DIR_NAME or SNAPSHOT_DIR_NAME in rel_parts[:-3]:
        return None, "路径不符合 __Snapshots__/<测试目录>/<方法名>.<变体>.png 约定"

    parent_subdirs = tuple(rel_parts[:-3])
    folder = rel_parts[-2]
    filename = rel_parts[-1]
    if folder.startswith(".") or any(seg.startswith(".") for seg in parent_subdirs):
        return None, "路径包含隐藏目录段"
    if not filename.endswith(".png"):
        return None, "不是 .png 快照文件"

    stem = filename[:-4]
    if "." not in stem:
        return None, "文件名缺少 <方法名>.<变体>.png 分隔"
    method_name, variant = stem.split(".", 1)
    if not TEST_METHOD_NAME.match(method_name):
        return None, f"文件名方法段不是合法的 test 方法名：{method_name}"
    if not variant or variant.startswith(".") or variant.endswith(".") or ".." in variant:
        return None, "文件名快照变体段不合法"

    return ParsedSnapshotPath(parent_subdirs, folder, method_name), None


def resolve_rerecorded_snapshots(
    rerecorded_paths: list[str],
    inventory: Inventory,
    runnable: dict[str, list[str]],
    results: dict[str, dict[str, str]],
) -> tuple[dict[str, list[str]], list[tuple[str, str]]]:
    """把重录快照路径映射为经静态清单与本次测试结果双重验证的 Class/method。"""
    snapshot_drifted: dict[str, list[str]] = {}
    unmapped: list[tuple[str, str]] = []

    for raw_path in rerecorded_paths:
        parsed, error = parse_snapshot_path(raw_path)
        if error or parsed is None:
            unmapped.append((raw_path, error or "路径无法解析"))
            continue

        expected_dir = TEST_DIR.joinpath(*parsed.parent_subdirs)
        expected_file = (expected_dir / f"{parsed.folder}.swift").as_posix()

        # 1. 优先按 SnapshotTesting 的 #file 约定（源文件 stem）精确匹配定义在该文件的用例，
        #    覆盖单文件多测试类与 extension 拆分文件。
        file_matches = sorted(
            cls
            for cls, methods in runnable.items()
            if parsed.method in methods
            and inventory.test_method_files.get(cls, {}).get(parsed.method) == expected_file
        )
        matched_class: str | None = None
        if len(file_matches) == 1:
            matched_class = file_matches[0]
        elif len(file_matches) > 1:
            candidates = ", ".join(f"{cls}/{parsed.method}" for cls in file_matches)
            unmapped.append((raw_path, f"同文件存在多个同名测试方法，无法唯一映射：{candidates}"))
            continue
        else:
            # 2. 兼容基类方法在子类文件上下文、或按测试类名命名的快照目录（需确认该类在同级目录存在源码）。
            if parsed.folder in runnable and parsed.method in runnable[parsed.folder]:
                class_info = inventory.types.get(parsed.folder)
                if class_info and any(Path(src).parent == expected_dir for src in class_info.files):
                    matched_class = parsed.folder

        if matched_class is None:
            unmapped.append(
                (raw_path, f"未在静态清单中找到匹配的测试类/方法（目录 {parsed.folder}，方法 {parsed.method}）")
            )
            continue

        case = f"{matched_class}/{parsed.method}"
        if parsed.method not in results.get(matched_class, {}):
            unmapped.append((raw_path, f"映射到 {case}，但本次测试结果中未执行该用例"))
            continue

        snapshot_drifted.setdefault(case, []).append(raw_path)

    return snapshot_drifted, unmapped


def read_rerecorded_list(path: Path) -> tuple[list[str] | None, str | None]:
    if not path.is_file():
        return None, f"重录快照清单不存在：{path}"
    try:
        raw_text = path.read_text(encoding="utf-8")
    except OSError as exc:
        return None, f"无法读取重录快照清单（{path}）：{exc}"
    entries: list[str] = []
    seen: set[str] = set()
    for raw_line in raw_text.splitlines():
        if not raw_line.strip():
            continue
        if raw_line not in seen:
            seen.add(raw_line)
            entries.append(raw_line)
    return entries, None


def command_verify_results(args: argparse.Namespace) -> int:
    plan = build_plan(Path(args.root).resolve())
    if plan.errors:
        for error in plan.errors:
            print(f"iOS 测试 selector 检查失败：{error}", file=sys.stderr)
        return 1

    tests_json_path = Path(args.tests_json)
    if not tests_json_path.is_file():
        print(f"测试结果文件不存在：{tests_json_path}", file=sys.stderr)
        return 1
    try:
        payload = json.loads(tests_json_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"无法解析测试结果 JSON（{tests_json_path}）：{exc}", file=sys.stderr)
        return 1
    if not isinstance(payload, dict) or not isinstance(payload.get("testNodes"), list):
        print(f"测试结果 JSON 缺少有效的 testNodes：{tests_json_path}", file=sys.stderr)
        return 1

    rerecorded_paths: list[str] = []
    if args.rerecorded_list:
        loaded_paths, list_error = read_rerecorded_list(Path(args.rerecorded_list))
        if list_error or loaded_paths is None:
            print(list_error or "无法读取重录快照清单。", file=sys.stderr)
            return 1
        rerecorded_paths = loaded_paths

    results: dict[str, dict[str, str]] = {}
    retried_passed: set[str] = set()
    for node in payload.get("testNodes", []):
        collect_results(node, results, retried_passed)

    quarantined: dict[str, set[str]] = {}
    for entry in plan.quarantine:
        quarantined.setdefault(entry.class_name, set()).add(entry.method)

    runnable = plan.inventory.runnable_classes()
    snapshot_drifted, unmapped_rerecorded = resolve_rerecorded_snapshots(
        rerecorded_paths, plan.inventory, runnable, results
    )
    remaining_retried = retried_passed - set(snapshot_drifted)
    if unmapped_rerecorded:
        # 存在无法映射的重录快照时，不能把剩余重试通过用例误标为抖动，统一标为归属未知。
        flaky: set[str] = set()
        unknown_retried = remaining_retried
    else:
        flaky = remaining_retried
        unknown_retried = set()

    problems: list[str] = []
    lines = [
        "| 类 | 清单 | 隔离 | 应执行 | 实际执行 | 通过 | 其中重试后通过 | 失败 | 跳过 |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    totals = [0, 0, 0, 0, 0, 0, 0, 0]
    for name in sorted(runnable):
        expected_methods = set(runnable[name]) - quarantined.get(name, set())
        executed = results.get(name, {})
        passed = sum(1 for value in executed.values() if value == "Passed")
        retried = sum(1 for method in executed if f"{name}/{method}" in flaky)
        failed = sum(1 for value in executed.values() if value == "Failed")
        skipped = sum(1 for value in executed.values() if value == "Skipped")
        row = [
            len(runnable[name]), len(quarantined.get(name, ())), len(expected_methods), len(executed),
            passed, retried, failed, skipped,
        ]
        totals = [a + b for a, b in zip(totals, row)]
        lines.append(f"| {name} | " + " | ".join(str(value) for value in row) + " |")
        if expected_methods and not executed:
            problems.append(f"{name} 应执行 {len(expected_methods)} 个用例，实际执行 0 个。")
            continue
        missing = sorted(expected_methods - set(executed))
        if missing:
            problems.append(f"{name} 有 {len(missing)} 个用例未执行：{', '.join(missing[:5])}{' …' if len(missing) > 5 else ''}")
        ran_quarantined = sorted(set(executed) & quarantined.get(name, set()))
        if ran_quarantined:
            problems.append(f"{name} 的隔离用例仍被执行，-skip-testing 未生效：{', '.join(ran_quarantined)}")
    unknown = sorted(set(results) - set(runnable))
    for name in unknown:
        problems.append(f"结果里出现静态清单之外的类 {name}，解析器与编译结果不一致。")
    lines.append("| **合计** | " + " | ".join(f"**{value}**" for value in totals) + " |")

    if snapshot_drifted:
        drifted_image_count = sum(len(paths) for paths in snapshot_drifted.values())
        lines += [
            "",
            f"快照漂移（已重录，判失败，不计为抖动）：{len(snapshot_drifted)} 个用例（{drifted_image_count} 张快照）",
            "",
        ]
        for case in sorted(snapshot_drifted):
            paths = snapshot_drifted[case]
            rendered_paths = ", ".join(sanitize_display_text(p) for p in paths)
            lines.append(f"- {case}（{len(paths)} 张：{rendered_paths}）")
    if unmapped_rerecorded:
        lines += [
            "",
            f"快照漂移（已重录，无法映射/未知，判失败）：{len(unmapped_rerecorded)} 条",
            "",
        ]
        for raw_path, reason in unmapped_rerecorded:
            lines.append(f"- {sanitize_display_text(raw_path)}（未知：{reason}）")
    if unknown_retried:
        lines += [
            "",
            f"重试后通过（归属未知：存在无法映射的重录快照，不计为抖动）：{len(unknown_retried)} 个",
            "",
        ]
        lines += [f"- {case}" for case in sorted(unknown_retried)]
    if flaky:
        lines += [
            "",
            f"重试后通过（抖动，不计失败，需分诊：修测试，或登记隔离与 Issue）：{len(flaky)} 个",
            "",
        ]
        lines += [f"- {case}" for case in sorted(flaky)]
    report = "\n".join(lines)
    if args.markdown:
        Path(args.markdown).write_text(report + "\n", encoding="utf-8")
    print(report)
    failed_cases = [
        f"{name}/{method}"
        for name, methods in sorted(results.items())
        for method, value in sorted(methods.items())
        if value == "Failed"
    ]
    if failed_cases:
        print(f"\n失败用例（{len(failed_cases)}）：")
        for case in failed_cases:
            print(f"- {case}")
    if os.environ.get("GITHUB_ACTIONS") == "true":
        for case in sorted(snapshot_drifted):
            paths = snapshot_drifted[case]
            suffix = f"（{len(paths)} 张）" if len(paths) > 1 else ""
            print(f"::error title=快照漂移（已重录）::{escape_github_annotation(case + suffix)}")
        for raw_path, reason in unmapped_rerecorded:
            detail = f"未知归属：{raw_path}（{reason}）"
            print(f"::error title=快照漂移（已重录，未知）::{escape_github_annotation(detail)}")
        for case in sorted(unknown_retried):
            print(f"::warning title=重试后通过（归属未知）::{escape_github_annotation(case)}")
        for case in sorted(flaky):
            print(f"::warning title=抖动用例（重试后通过）::{escape_github_annotation(case)}")
    if problems:
        print(f"\n执行数校验失败（{len(problems)}）：", file=sys.stderr)
        for problem in problems:
            print(f"- {problem}", file=sys.stderr)
    has_rerecorded_failure = bool(snapshot_drifted or unmapped_rerecorded)
    return 1 if problems or failed_cases or has_rerecorded_failure else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=str(ROOT_DIR), help="仓库根目录（自测用）")
    subcommands = parser.add_subparsers(dest="command", required=True)
    subcommands.add_parser("check", help="静态校验 selector、归属与隔离清单")
    list_parser = subcommands.add_parser("list", help="输出每个测试类的用例数与归属")
    list_parser.add_argument("--json", action="store_true")
    subcommands.add_parser("skip-args", help="把隔离清单转换成 xcodebuild -skip-testing 参数")
    verify_parser = subcommands.add_parser("verify-results", help="按类核对 xcresult 实际执行数")
    verify_parser.add_argument("tests_json", help="xcresulttool get test-results tests 的 JSON 输出")
    verify_parser.add_argument("--markdown", help="把按类统计表写入该文件")
    verify_parser.add_argument("--rerecorded-list", help="本次运行重录的快照路径清单文件（每行一个仓库相对路径）")
    args = parser.parse_args()
    handlers = {
        "check": command_check,
        "list": command_list,
        "skip-args": command_skip_args,
        "verify-results": command_verify_results,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
