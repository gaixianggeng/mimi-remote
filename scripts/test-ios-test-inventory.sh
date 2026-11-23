#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# 用最小夹具仓库验证 ios-test-inventory.py 能拦住 #741 记录的几类静默漏跑：
# 失效方法 selector、按文件名写的 selector、未归属的测试类、只选部分方法却没进每晚集合、
# 隔离条目缺信息、测试文件未进工程，以及按类执行数为 0。

fail() {
  echo "iOS 测试清单自测失败：$1" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 || fail "缺少命令 python3。"

work_root="$(mktemp -d "${TMPDIR:-/tmp}/mimi-ios-test-inventory.XXXXXX")"
trap 'rm -rf "$work_root"' EXIT
inventory="$ROOT_DIR/scripts/ios-test-inventory.py"

make_fixture() {
  local root="$1"
  local tests="$root/ios/MimiRemote/Tests/MimiRemoteTests"
  mkdir -p "$tests" "$root/ios/MimiRemote/MimiRemote.xcodeproj" "$root/scripts" "$root/config/ios-tests"

  cat > "$tests/AlphaTests.swift" <<'EOF'
import XCTest

final class AlphaTests: XCTestCase {
    private let payload = """
    {"brace": "}", "nested": {"value": "{"}}
    """

    func testOne() {
        let text = "} not a scope end"
        XCTAssertFalse(text.isEmpty)
    }

    @MainActor
    func testTwo() async throws {}

    func testHelper(value: Int) {}

    static func testStaticHelper() {}

    struct Fixture {
        func testNestedHelper() {}
    }
}

struct NotATestCase {
    func testLooksLikeATest() {}
}
EOF

  cat > "$tests/AlphaExtensionTests.swift" <<'EOF'
import XCTest

// 文件名带 Tests，但用例属于 AlphaTests。
extension AlphaTests {
    func testThree() {
        let raw = #"{ "quote": "\" }"#
        XCTAssertFalse(raw.isEmpty)
    }
}
EOF

  cat > "$tests/GammaSnapshotTests.swift" <<'EOF'
import XCTest

class BaseSnapshotTestCase: XCTestCase {
    override func setUp() {
        super.setUp()
    }
}

final class GammaSnapshotTests: BaseSnapshotTestCase {
    func testShot() {}
}
EOF

  cat > "$root/ios/MimiRemote/MimiRemote.xcodeproj/project.pbxproj" <<'EOF'
		A1 /* AlphaTests.swift in Sources */ = {isa = PBXBuildFile; };
		A2 /* AlphaExtensionTests.swift in Sources */ = {isa = PBXBuildFile; };
		A3 /* GammaSnapshotTests.swift in Sources */ = {isa = PBXBuildFile; };
EOF

  cat > "$root/scripts/test-conversation-regressions.sh" <<'EOF'
bash ./scripts/ios-dev.sh test \
  -only-testing:MimiRemoteTests/AlphaTests
EOF

  printf '# 每晚集合\nGammaSnapshotTests\n' > "$root/config/ios-tests/nightly-classes.txt"
  printf '# 隔离清单\n' > "$root/config/ios-tests/quarantine.tsv"
}

fixture_index=0
root=""
# 不能用 $(new_fixture)：命令替换在子 shell 里执行，计数不会前进，夹具会被复用。
new_fixture() {
  fixture_index=$((fixture_index + 1))
  root="$work_root/case-$fixture_index"
  make_fixture "$root"
}

expect_check_pass() {
  local name="$1"
  local root="$2"
  python3 "$inventory" --root "$root" check > "$work_root/out.txt" 2>&1 \
    || { cat "$work_root/out.txt" >&2; fail "${name} 应通过。"; }
}

expect_check_fail() {
  local name="$1"
  local root="$2"
  local expected="$3"
  if python3 "$inventory" --root "$root" check > "$work_root/out.txt" 2>&1; then
    fail "${name} 应失败。"
  fi
  grep -Fq -- "$expected" "$work_root/out.txt" \
    || { cat "$work_root/out.txt" >&2; fail "${name} 缺少提示：${expected}"; }
}

new_fixture
expect_check_pass "基础夹具" "$root"
python3 "$inventory" --root "$root" list > "$work_root/list.txt"
grep -Fqx $'AlphaTests\t3\t0\tpr' "$work_root/list.txt" \
  || { cat "$work_root/list.txt" >&2; fail "AlphaTests 应按类与 extension 合计 3 个用例。"; }
grep -Fqx $'GammaSnapshotTests\t1\t0\tnightly' "$work_root/list.txt" \
  || fail "继承自测试基类的 GammaSnapshotTests 应被识别。"
if grep -Eq '^(BaseSnapshotTestCase|NotATestCase|AlphaTests\.Fixture)\b' "$work_root/list.txt"; then
  fail "无用例基类、普通类型和嵌套类型不应出现在清单里。"
fi

new_fixture
printf '  -only-testing:MimiRemoteTests/GammaSnapshotTests/testDeleted\n' >> "$root/scripts/test-conversation-regressions.sh"
expect_check_fail "失效方法 selector" "$root" "GammaSnapshotTests/testDeleted 指向不存在的方法"

new_fixture
printf '  -only-testing:MimiRemoteTests/AlphaExtensionTests\n' >> "$root/scripts/test-conversation-regressions.sh"
expect_check_fail "按文件名写的 selector" "$root" "AlphaExtensionTests.swift 里的用例属于 AlphaTests"

new_fixture
printf '# 每晚集合\n' > "$root/config/ios-tests/nightly-classes.txt"
expect_check_fail "未归属的测试类" "$root" "GammaSnapshotTests 既不在 PR 集合也不在每晚集合"

new_fixture
printf 'bash x \\\n  # -only-testing:MimiRemoteTests/AlphaTests \\\n#-only-testing:MimiRemoteTests/AlphaTests\n' > "$root/scripts/test-conversation-regressions.sh"
expect_check_fail "注释掉的 selector" "$root" "AlphaTests 既不在 PR 集合也不在每晚集合"

new_fixture
printf 'bash x \\\n  -only-testing:MimiRemoteTests/AlphaTests/testOne\n' > "$root/scripts/test-conversation-regressions.sh"
expect_check_fail "只选部分方法" "$root" "AlphaTests 只有部分方法进入 PR 集合"
printf 'GammaSnapshotTests\nAlphaTests\n' > "$root/config/ios-tests/nightly-classes.txt"
expect_check_pass "部分方法 + 每晚集合" "$root"

new_fixture
printf 'AlphaTests\n' >> "$root/config/ios-tests/nightly-classes.txt"
expect_check_fail "整类重复登记每晚集合" "$root" "AlphaTests 已整类进入 PR 集合"

new_fixture
printf 'AlphaTests/testOne\t原因\t@owner\t\n' >> "$root/config/ios-tests/quarantine.tsv"
expect_check_fail "隔离条目缺 Issue" "$root" "Issue 必须写成 #编号"

new_fixture
printf 'AlphaTests\t原因\t@owner\t#1\n' >> "$root/config/ios-tests/quarantine.tsv"
expect_check_fail "整类隔离" "$root" "不能整类跳过"

new_fixture
printf 'AlphaTests/testGone\t原因\t@owner\t#1\n' >> "$root/config/ios-tests/quarantine.tsv"
expect_check_fail "隔离已删除的用例" "$root" "AlphaTests/testGone 指向不存在的方法"

new_fixture
printf 'AlphaTests/testTwo\t原因\t@owner\t#1\n' >> "$root/config/ios-tests/quarantine.tsv"
expect_check_pass "合法隔离条目" "$root"
python3 "$inventory" --root "$root" skip-args > "$work_root/skip.txt"
grep -Fqx -- '-skip-testing:MimiRemoteTests/AlphaTests/testTwo' "$work_root/skip.txt" \
  || fail "隔离条目没有转换成 -skip-testing。"

new_fixture
printf 'import XCTest\nfinal class OrphanTests: XCTestCase { func testOrphan() {} }\n' \
  > "$root/ios/MimiRemote/Tests/MimiRemoteTests/OrphanTests.swift"
printf 'OrphanTests\n' >> "$root/config/ios-tests/nightly-classes.txt"
expect_check_fail "未进工程的测试文件" "$root" "OrphanTests.swift 没有登记进 Xcode 工程"

write_results() {
  local path="$1"
  local gamma_cases="$2"
  local alpha_three_result="$3"
  # 第 4 个参数是 testThree 的附加 JSON 字段，用来模拟 -retry-tests-on-failure 的 Repetition 子节点。
  local alpha_three_extra="${4:-}"
  cat > "$path" <<EOF
{"testNodes":[{"nodeType":"Test Plan","name":"MimiRemote","children":[
  {"nodeType":"Unit test bundle","name":"MimiRemoteTests","children":[
    {"nodeType":"Test Suite","name":"AlphaTests","children":[
      {"nodeType":"Test Case","name":"testOne()","nodeIdentifier":"AlphaTests/testOne()","result":"Passed"},
      {"nodeType":"Test Case","name":"testTwo()","nodeIdentifier":"AlphaTests/testTwo()","result":"Skipped"},
      {"nodeType":"Test Case","name":"testThree()","nodeIdentifier":"AlphaTests/testThree()","result":"${alpha_three_result}"${alpha_three_extra}}
    ]}${gamma_cases}
  ]}
]}]}
EOF
}

new_fixture
gamma=',{"nodeType":"Test Suite","name":"GammaSnapshotTests","children":[{"nodeType":"Test Case","name":"testShot()","nodeIdentifier":"GammaSnapshotTests/testShot()","result":"Passed"}]}'
write_results "$work_root/pass.json" "$gamma" "Passed"
python3 "$inventory" --root "$root" verify-results "$work_root/pass.json" --markdown "$work_root/summary.md" \
  > "$work_root/out.txt" 2>&1 || { cat "$work_root/out.txt" >&2; fail "全部执行且通过时应成功。"; }
grep -Fq '| 类 | 清单 | 隔离 | 应执行 | 实际执行 | 通过 | 其中已确认抖动 | 失败 | 跳过 |' "$work_root/summary.md" \
  || { cat "$work_root/summary.md" >&2; fail "按类统计表表头应明确标注「其中已确认抖动」。"; }
if grep -Fq '| 其中重试后通过 |' "$work_root/summary.md"; then
  cat "$work_root/summary.md" >&2
  fail "按类统计表不得保留易与重录/未知混淆的「其中重试后通过」列名。"
fi
grep -Fq '| AlphaTests | 3 | 0 | 3 | 3 | 2 | 0 | 0 | 1 |' "$work_root/summary.md" \
  || { cat "$work_root/summary.md" >&2; fail "按类统计表不正确。"; }

retry=',"children":[{"nodeType":"Repetition","name":"First Run","result":"Failed"},{"nodeType":"Repetition","name":"Retry 1","result":"Passed"}]'
write_results "$work_root/flaky.json" "$gamma" "Passed" "$retry"
python3 "$inventory" --root "$root" verify-results "$work_root/flaky.json" --markdown "$work_root/flaky.md" \
  > "$work_root/out.txt" 2>&1 || { cat "$work_root/out.txt" >&2; fail "重试后通过的用例不应让任务失败。"; }
grep -Fq '| AlphaTests | 3 | 0 | 3 | 3 | 2 | 1 | 0 | 1 |' "$work_root/flaky.md" \
  || { cat "$work_root/flaky.md" >&2; fail "重试后通过的用例没有计入抖动列。"; }
grep -Fq -- "- AlphaTests/testThree" "$work_root/flaky.md" || fail "抖动用例没有列在摘要里。"

write_results "$work_root/zero.json" "" "Passed"
if python3 "$inventory" --root "$root" verify-results "$work_root/zero.json" > "$work_root/out.txt" 2>&1; then
  fail "某个类执行 0 个时应失败。"
fi
grep -Fq "GammaSnapshotTests 应执行 1 个用例，实际执行 0 个" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "执行 0 个缺少明确提示。"; }

retry_failed=',"children":[{"nodeType":"Repetition","name":"First Run","result":"Failed"},{"nodeType":"Repetition","name":"Retry 1","result":"Failed"}]'
write_results "$work_root/failed.json" "$gamma" "Failed" "$retry_failed"
if python3 "$inventory" --root "$root" verify-results "$work_root/failed.json" > "$work_root/out.txt" 2>&1; then
  fail "存在失败用例时应失败。"
fi
grep -Fq -- "- AlphaTests/testThree" "$work_root/out.txt" || fail "失败用例没有列出。"

# 夹具：同一次运行中同时出现「重录快照重试通过」与「非快照真抖动重试通过」。
new_fixture
gamma_retry=',{"nodeType":"Test Suite","name":"GammaSnapshotTests","children":[{"nodeType":"Test Case","name":"testShot()","nodeIdentifier":"GammaSnapshotTests/testShot()","result":"Passed","children":[{"nodeType":"Repetition","name":"First Run","result":"Failed"},{"nodeType":"Repetition","name":"Retry 1","result":"Passed"}]}]}'
write_results "$work_root/mixed.json" "$gamma_retry" "Passed" "$retry"
cat > "$work_root/mixed-rerecorded.txt" <<'EOF'
ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.1.png
EOF
if GITHUB_ACTIONS=true python3 "$inventory" --root "$root" verify-results \
  "$work_root/mixed.json" \
  --markdown "$work_root/mixed.md" \
  --rerecorded-list "$work_root/mixed-rerecorded.txt" > "$work_root/out.txt" 2>&1; then
  cat "$work_root/out.txt" >&2
  fail "存在重录快照漂移时 verify-results 应判失败。"
fi
grep -Fq '| AlphaTests | 3 | 0 | 3 | 3 | 2 | 1 | 0 | 1 |' "$work_root/mixed.md" \
  || { cat "$work_root/mixed.md" >&2; fail "非快照真抖动用例应保留在抖动列。"; }
grep -Fq '| GammaSnapshotTests | 1 | 0 | 1 | 1 | 1 | 0 | 0 | 0 |' "$work_root/mixed.md" \
  || { cat "$work_root/mixed.md" >&2; fail "重录快照漂移用例不应计入抖动列。"; }
grep -Fq "快照漂移（已重录，判失败，不计为抖动）：1 个用例（1 张快照）" "$work_root/mixed.md" \
  || { cat "$work_root/mixed.md" >&2; fail "摘要缺少快照漂移独立分类。"; }
grep -Fq -- "- GammaSnapshotTests/testShot（1 张：ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.1.png）" "$work_root/mixed.md" \
  || { cat "$work_root/mixed.md" >&2; fail "快照漂移清单未列出 GammaSnapshotTests/testShot。"; }
grep -Fq "::error title=快照漂移（已重录）::GammaSnapshotTests/testShot" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "缺少重录快照漂移的 error 注解。"; }
grep -Fq "::warning title=抖动用例（重试后通过）::AlphaTests/testThree" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "非快照真抖动用例应继续输出抖动 warning 注解。"; }
if grep -Fq "::warning title=抖动用例（重试后通过）::GammaSnapshotTests/testShot" "$work_root/out.txt"; then
  cat "$work_root/out.txt" >&2
  fail "重录快照用例不得再输出抖动 warning 注解。"
fi

# 夹具：命名变体、多图同用例、单文件多测试类、extension 拆分文件与继承方法。
new_fixture
cat > "$root/ios/MimiRemote/Tests/MimiRemoteTests/BaseSnapshotTestCase.swift" <<'EOF'
import XCTest

class BaseSnapshotTestCase: XCTestCase {
    func testInherited() {}
}
EOF
cat > "$root/ios/MimiRemote/Tests/MimiRemoteTests/GammaSnapshotTests.swift" <<'EOF'
import XCTest

final class GammaSnapshotTests: BaseSnapshotTestCase {
    func testShot() {}
    func testMulti() {}
}

final class DeltaSnapshotTests: XCTestCase {
    func testCard() {}
}
EOF
cat >> "$root/ios/MimiRemote/MimiRemote.xcodeproj/project.pbxproj" <<'EOF'
		A4 /* BaseSnapshotTestCase.swift in Sources */ = {isa = PBXBuildFile; };
EOF
printf 'BaseSnapshotTestCase\nDeltaSnapshotTests\n' >> "$root/config/ios-tests/nightly-classes.txt"
cat > "$work_root/variants.json" <<'EOF'
{"testNodes":[{"nodeType":"Test Plan","name":"MimiRemote","children":[
  {"nodeType":"Unit test bundle","name":"MimiRemoteTests","children":[
    {"nodeType":"Test Suite","name":"AlphaTests","children":[
      {"nodeType":"Test Case","name":"testOne()","nodeIdentifier":"AlphaTests/testOne()","result":"Passed","children":[{"nodeType":"Repetition","name":"First Run","result":"Failed"},{"nodeType":"Repetition","name":"Retry 1","result":"Passed"}]},
      {"nodeType":"Test Case","name":"testTwo()","nodeIdentifier":"AlphaTests/testTwo()","result":"Passed"},
      {"nodeType":"Test Case","name":"testThree()","nodeIdentifier":"AlphaTests/testThree()","result":"Passed","children":[{"nodeType":"Repetition","name":"First Run","result":"Failed"},{"nodeType":"Repetition","name":"Retry 1","result":"Passed"}]}
    ]},
    {"nodeType":"Test Suite","name":"BaseSnapshotTestCase","children":[
      {"nodeType":"Test Case","name":"testInherited()","nodeIdentifier":"BaseSnapshotTestCase/testInherited()","result":"Passed"}
    ]},
    {"nodeType":"Test Suite","name":"GammaSnapshotTests","children":[
      {"nodeType":"Test Case","name":"testInherited()","nodeIdentifier":"GammaSnapshotTests/testInherited()","result":"Passed","children":[{"nodeType":"Repetition","name":"First Run","result":"Failed"},{"nodeType":"Repetition","name":"Retry 1","result":"Passed"}]},
      {"nodeType":"Test Case","name":"testShot()","nodeIdentifier":"GammaSnapshotTests/testShot()","result":"Passed","children":[{"nodeType":"Repetition","name":"First Run","result":"Failed"},{"nodeType":"Repetition","name":"Retry 1","result":"Passed"}]},
      {"nodeType":"Test Case","name":"testMulti()","nodeIdentifier":"GammaSnapshotTests/testMulti()","result":"Passed","children":[{"nodeType":"Repetition","name":"First Run","result":"Failed"},{"nodeType":"Repetition","name":"Retry 1","result":"Passed"}]}
    ]},
    {"nodeType":"Test Suite","name":"DeltaSnapshotTests","children":[
      {"nodeType":"Test Case","name":"testCard()","nodeIdentifier":"DeltaSnapshotTests/testCard()","result":"Passed","children":[{"nodeType":"Repetition","name":"First Run","result":"Failed"},{"nodeType":"Repetition","name":"Retry 1","result":"Passed"}]}
    ]}
  ]}
]}]}
EOF
cat > "$work_root/variants-rerecorded.txt" <<'EOF'
ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.1.png
ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.1.png
ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.ipad-pro-1366-dark-contrast.png
ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.ios26.2-dark.png
ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.iPad_Mini_深色.png
ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testMulti.1.png
ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testMulti.2.png
ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testInherited.dark mode.png
ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testCard.wide-dark.png
ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/AlphaExtensionTests/testThree.compact-light.png
EOF
if GITHUB_ACTIONS=true python3 "$inventory" --root "$root" verify-results \
  "$work_root/variants.json" \
  --markdown "$work_root/variants.md" \
  --rerecorded-list "$work_root/variants-rerecorded.txt" > "$work_root/out.txt" 2>&1; then
  cat "$work_root/out.txt" >&2
  fail "命名变体与多图重录场景应判失败。"
fi
[[ -f "$work_root/variants.md" ]] || { cat "$work_root/out.txt" >&2; fail "variants 夹具未生成 summary.md。"; }
grep -Fq '| AlphaTests | 3 | 0 | 3 | 3 | 3 | 1 | 0 | 0 |' "$work_root/variants.md" \
  || { cat "$work_root/variants.md" >&2; fail "AlphaTests 应只把真抖动 testOne 计入抖动列，排除 extension 重录的 testThree。"; }
grep -Fq '| GammaSnapshotTests | 3 | 0 | 3 | 3 | 3 | 0 | 0 | 0 |' "$work_root/variants.md" \
  || { cat "$work_root/variants.md" >&2; fail "GammaSnapshotTests 多图与继承方法重录不应计入抖动列。"; }
grep -Fq '| DeltaSnapshotTests | 1 | 0 | 1 | 1 | 1 | 0 | 0 | 0 |' "$work_root/variants.md" \
  || { cat "$work_root/variants.md" >&2; fail "同文件多测试类 DeltaSnapshotTests 重录不应计入抖动列。"; }
grep -Fq "快照漂移（已重录，判失败，不计为抖动）：5 个用例（9 张快照）" "$work_root/variants.md" \
  || { cat "$work_root/variants.md" >&2; fail "多图与去重后的用例数/快照张数统计不正确。"; }
grep -Fq "::error title=快照漂移（已重录）::GammaSnapshotTests/testShot（4 张）" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "多图同用例应聚合输出 4 张并去重重复路径。"; }
shot_err_count="$(grep -Fc "::error title=快照漂移（已重录）::GammaSnapshotTests/testShot" "$work_root/out.txt" || true)"
[[ "$shot_err_count" -eq 1 ]] || fail "多图同用例只应发 1 条 error 注解，实际 ${shot_err_count} 条。"
grep -Fq "::error title=快照漂移（已重录）::DeltaSnapshotTests/testCard" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "同文件多测试类快照未映射到 DeltaSnapshotTests/testCard。"; }
grep -Fq "::error title=快照漂移（已重录）::AlphaTests/testThree" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "extension 拆分文件快照未映射到 AlphaTests/testThree。"; }
grep -Fq "::error title=快照漂移（已重录）::GammaSnapshotTests/testInherited" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "继承方法与含空格变体快照未映射到 GammaSnapshotTests/testInherited。"; }
grep -Fq "::warning title=抖动用例（重试后通过）::AlphaTests/testOne" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "非快照真抖动 AlphaTests/testOne 应保留抖动告警。"; }
if grep -Fq "::warning title=抖动用例（重试后通过）::AlphaTests/testThree" "$work_root/out.txt"; then
  fail "extension 重录的 AlphaTests/testThree 不得标为抖动。"
fi

# 夹具：无法映射/路径穿越/识别不全时保持重录失败，并明确标为未知而非抖动。
new_fixture
write_results "$work_root/unmapped.json" "$gamma_retry" "Passed" "$retry"
cat > "$work_root/unmapped-rerecorded.txt" <<'EOF'
ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/../GammaSnapshotTests/testShot.1.png
/ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.1.png
ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.png
ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/README.txt
ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testDeleted.1.png
ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GhostSnapshotTests/testGhost.1.png
EOF
if GITHUB_ACTIONS=true python3 "$inventory" --root "$root" verify-results \
  "$work_root/unmapped.json" \
  --markdown "$work_root/unmapped.md" \
  --rerecorded-list "$work_root/unmapped-rerecorded.txt" > "$work_root/out.txt" 2>&1; then
  cat "$work_root/out.txt" >&2
  fail "存在无法映射的重录快照时应判失败。"
fi
grep -Fq "快照漂移（已重录，无法映射/未知，判失败）：6 条" "$work_root/unmapped.md" \
  || { cat "$work_root/unmapped.md" >&2; fail "无法映射与路径穿越条目应全部标为未知。"; }
grep -Fq "重试后通过（归属未知：存在无法映射的重录快照，不计为抖动）：2 个" "$work_root/unmapped.md" \
  || { cat "$work_root/unmapped.md" >&2; fail "识别不全时剩余重试通过用例应标为归属未知，而非抖动。"; }
grep -Fq '| AlphaTests | 3 | 0 | 3 | 3 | 2 | 0 | 0 | 1 |' "$work_root/unmapped.md" \
  || { cat "$work_root/unmapped.md" >&2; fail "识别不全时抖动列不应误计。"; }
grep -Fq '| GammaSnapshotTests | 1 | 0 | 1 | 1 | 1 | 0 | 0 | 0 |' "$work_root/unmapped.md" \
  || { cat "$work_root/unmapped.md" >&2; fail "识别不全时快照类抖动列应为 0。"; }
grep -Fq "::error title=快照漂移（已重录，未知）::" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "无法映射的重录路径应输出未知 error 注解。"; }
grep -Fq "::warning title=重试后通过（归属未知）::GammaSnapshotTests/testShot" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "识别不全时重试通过用例应标为归属未知。"; }
if grep -Fq "抖动用例（重试后通过）" "$work_root/out.txt"; then
  cat "$work_root/out.txt" >&2
  fail "识别不全时不得把任何重试通过用例误标为抖动。"
fi

# 夹具：同文件同名方法歧义应标为未知而非强行猜中。
new_fixture
cat > "$root/ios/MimiRemote/Tests/MimiRemoteTests/GammaSnapshotTests.swift" <<'EOF'
import XCTest

final class GammaSnapshotTests: XCTestCase {
    func testShot() {}
}

final class GammaTwinSnapshotTests: XCTestCase {
    func testShot() {}
}
EOF
printf 'GammaTwinSnapshotTests\n' >> "$root/config/ios-tests/nightly-classes.txt"
gamma_ambig=',{"nodeType":"Test Suite","name":"GammaSnapshotTests","children":[{"nodeType":"Test Case","name":"testShot()","nodeIdentifier":"GammaSnapshotTests/testShot()","result":"Passed","children":[{"nodeType":"Repetition","name":"First Run","result":"Failed"},{"nodeType":"Repetition","name":"Retry 1","result":"Passed"}]}]},{"nodeType":"Test Suite","name":"GammaTwinSnapshotTests","children":[{"nodeType":"Test Case","name":"testShot()","nodeIdentifier":"GammaTwinSnapshotTests/testShot()","result":"Passed"}]}'
write_results "$work_root/ambig.json" "$gamma_ambig" "Passed"
printf 'ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.1.png\n' > "$work_root/ambig-rerecorded.txt"
if GITHUB_ACTIONS=true python3 "$inventory" --root "$root" verify-results \
  "$work_root/ambig.json" \
  --rerecorded-list "$work_root/ambig-rerecorded.txt" > "$work_root/out.txt" 2>&1; then
  fail "同文件同名方法歧义重录应判失败。"
fi
grep -Fq "同文件存在多个同名测试方法，无法唯一映射" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "同文件同名方法歧义缺少明确未知提示。"; }
if grep -Fq "抖动用例（重试后通过）" "$work_root/out.txt"; then
  fail "歧义重录场景不得标为抖动。"
fi

# 夹具：重录路径映射到本次未执行（已隔离）的用例时应标为未知并判失败；清单缺失也应判失败。
new_fixture
printf 'GammaSnapshotTests/testShot\t原因\t@owner\t#1\n' >> "$root/config/ios-tests/quarantine.tsv"
write_results "$work_root/quarantined.json" "" "Passed"
printf 'ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.1.png\n' > "$work_root/quarantined-rerecorded.txt"
if python3 "$inventory" --root "$root" verify-results \
  "$work_root/quarantined.json" \
  --rerecorded-list "$work_root/quarantined-rerecorded.txt" > "$work_root/out.txt" 2>&1; then
  fail "映射到未执行用例的重录路径应判失败。"
fi
grep -Fq "本次测试结果中未执行该用例" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "映射到未执行用例时缺少明确提示。"; }

if python3 "$inventory" --root "$root" verify-results \
  "$work_root/quarantined.json" \
  --rerecorded-list "$work_root/non-existent-rerecorded.txt" > "$work_root/out.txt" 2>&1; then
  fail "不存在的 --rerecorded-list 文件应判失败。"
fi
grep -Fq "重录快照清单不存在" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "缺失重录清单时缺少错误提示。"; }

# 夹具：空重录清单、无结果文件/损坏 JSON、以及重录与原有失败（Failed / 0 执行）并存均不放宽。
new_fixture
: > "$work_root/empty-rerecorded.txt"
write_results "$work_root/empty-rerecorded.json" "$gamma" "Passed" "$retry"
GITHUB_ACTIONS=true python3 "$inventory" --root "$root" verify-results \
  "$work_root/empty-rerecorded.json" \
  --rerecorded-list "$work_root/empty-rerecorded.txt" > "$work_root/out.txt" 2>&1 \
  || { cat "$work_root/out.txt" >&2; fail "空重录清单且仅存在真抖动时应通过。"; }
grep -Fq "::warning title=抖动用例（重试后通过）::AlphaTests/testThree" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "空重录清单时真抖动告警应保留。"; }

if python3 "$inventory" --root "$root" verify-results "$work_root/missing-tests.json" > "$work_root/out.txt" 2>&1; then
  fail "缺少 tests.json 时应判失败。"
fi
grep -Fq "测试结果文件不存在" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "缺少 tests.json 时缺少明确提示。"; }

printf '{not-json' > "$work_root/bad.json"
if python3 "$inventory" --root "$root" verify-results "$work_root/bad.json" > "$work_root/out.txt" 2>&1; then
  fail "损坏的 tests.json 应判失败。"
fi
grep -Fq "无法解析测试结果 JSON" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "损坏的 tests.json 缺少明确提示。"; }

write_results "$work_root/failed-and-rerecorded.json" "$gamma_retry" "Failed" "$retry_failed"
if python3 "$inventory" --root "$root" verify-results \
  "$work_root/failed-and-rerecorded.json" \
  --rerecorded-list "$work_root/mixed-rerecorded.txt" > "$work_root/out.txt" 2>&1; then
  fail "同时存在失败用例与重录快照时应判失败。"
fi
grep -Fq "失败用例（1）：" "$work_root/out.txt" || fail "同时存在重录快照时不得掩盖失败用例。"
grep -Fq "快照漂移（已重录，判失败，不计为抖动）：1 个用例（1 张快照）" "$work_root/out.txt" \
  || fail "同时存在失败用例时仍应报告快照漂移。"

# 夹具：端到端验证 scripts/test-ios-full-suite.sh（采集顺序、路径安全、artifact、无结果包与失败语义）。
make_suite_repo() {
  local repo="$1"
  make_fixture "$repo"
  cp "$ROOT_DIR/scripts/test-ios-full-suite.sh" "$repo/scripts/test-ios-full-suite.sh"
  cp "$ROOT_DIR/scripts/check-ios-test-selectors.sh" "$repo/scripts/check-ios-test-selectors.sh"
  cp "$ROOT_DIR/scripts/ios-test-inventory.py" "$repo/scripts/ios-test-inventory.py"
  chmod +x "$repo/scripts/test-ios-full-suite.sh" "$repo/scripts/check-ios-test-selectors.sh" "$repo/scripts/ios-test-inventory.py"
  mkdir -p "$repo/ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests"
  printf 'old-png' > "$repo/ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.1.png"
  cat > "$repo/scripts/ios-dev.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
bundle=""
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == "-resultBundlePath" ]]; then
    bundle="$2"
    shift 2
  else
    shift
  fi
done
if [[ "${MOCK_CREATE_BUNDLE:-true}" == true && -n "$bundle" ]]; then
  mkdir -p "$bundle"
fi
if [[ "${MOCK_RERECORD_MODE:-none}" == "mixed" ]]; then
  snap_root="ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests"
  mkdir -p "$snap_root"
  printf 'new-png-1' > "$snap_root/testShot.1.png"
  printf 'new-png-2' > "$snap_root/testShot.深色 模式.png"
elif [[ "${MOCK_RERECORD_MODE:-none}" == "single" ]]; then
  snap_root="ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests"
  mkdir -p "$snap_root"
  printf 'new-png-1' > "$snap_root/testShot.1.png"
elif [[ "${MOCK_RERECORD_MODE:-none}" == "symlink" ]]; then
  snap_root="ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests"
  mkdir -p "$snap_root"
  ln -sf /etc/hosts "$snap_root/testShot.link.png"
elif [[ "${MOCK_RERECORD_MODE:-none}" == "vt_control" ]]; then
  snap_root="ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests"
  mkdir -p "$snap_root"
  printf 'bad-ctrl-png' > "$snap_root/testShot.1.png"$'\x0b'
fi
exit "${MOCK_IOS_DEV_EXIT:-0}"
EOF
  chmod +x "$repo/scripts/ios-dev.sh"
  git -C "$repo" init -q
  git -C "$repo" config user.name "Test User"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" add .
  git -C "$repo" commit -qm "init fixture"
}

mock_bin="$work_root/mock-bin"
mkdir -p "$mock_bin"
real_git="$(command -v git)"
real_cp="$(command -v cp)"
cat > "$mock_bin/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "xcresulttool" && "${2:-}" == "get" && "${3:-}" == "test-results" && "${4:-}" == "tests" ]]; then
  if [[ "${MOCK_XCRESULT_TESTS_EXIT:-0}" -ne 0 ]]; then
    echo "mock xcresulttool tests extract failure" >&2
    exit "${MOCK_XCRESULT_TESTS_EXIT}"
  fi
  cat "$MOCK_TESTS_JSON"
  exit 0
fi
if [[ "${1:-}" == "xcresulttool" && "${2:-}" == "get" && "${3:-}" == "test-results" && "${4:-}" == "summary" ]]; then
  echo "MOCK_SUMMARY_DIAGNOSTIC"
  exit 0
fi
echo "unexpected xcrun invocation: $*" >&2
exit 1
EOF
chmod +x "$mock_bin/xcrun"

cat > "$mock_bin/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail
real_git="$real_git"
if [[ "\${1:-}" == "status" ]]; then
  has_z=false
  for arg in "\$@"; do
    if [[ "\$arg" == "-z" ]]; then
      has_z=true
      break
    fi
  done
  if [[ "\${MOCK_GIT_FAIL_PHASE:-none}" == "pre" && "\$has_z" == false ]]; then
    echo "fatal: mock pre-test git status failed" >&2
    exit "\${MOCK_GIT_FAIL_EXIT:-128}"
  fi
  if [[ "\${MOCK_GIT_FAIL_PHASE:-none}" == "post" && "\$has_z" == true ]]; then
    echo "fatal: mock post-test git status failed" >&2
    exit "\${MOCK_GIT_FAIL_EXIT:-128}"
  fi
fi
exec "\$real_git" "\$@"
EOF
chmod +x "$mock_bin/git"

cat > "$mock_bin/cp" <<EOF
#!/usr/bin/env bash
set -euo pipefail
real_cp="$real_cp"
if [[ -n "\${MOCK_FAIL_COPY_SUFFIX:-}" ]]; then
  for arg in "\$@"; do
    case "\$arg" in
      *"\${MOCK_FAIL_COPY_SUFFIX}")
        echo "cp: mock copy failure for \$arg" >&2
        exit 1
        ;;
    esac
  done
fi
exec "\$real_cp" "\$@"
EOF
chmod +x "$mock_bin/cp"

# 端到端 1：重录快照（含中文与空格命名变体）+ 真抖动同时出现，重录必须先采集再分类并判失败。
fixture_index=$((fixture_index + 1))
suite_repo="$work_root/suite-mixed"
make_suite_repo "$suite_repo"
suite_result="$work_root/suite-mixed-result"
suite_summary="$work_root/suite-mixed-summary.md"
: > "$suite_summary"
suite_status=0
PATH="$mock_bin:$PATH" \
  MOCK_TESTS_JSON="$work_root/mixed.json" \
  MOCK_RERECORD_MODE="mixed" \
  MOCK_IOS_DEV_EXIT=0 \
  GITHUB_ACTIONS=true \
  GITHUB_STEP_SUMMARY="$suite_summary" \
  bash "$suite_repo/scripts/test-ios-full-suite.sh" \
    --result-dir "$suite_result" \
    --record-failed-snapshots > "$work_root/out.txt" 2>&1 || suite_status=$?
[[ "$suite_status" -eq 1 ]] || { cat "$work_root/out.txt" >&2; fail "有重录快照时 test-ios-full-suite.sh 必须退出 1，实际 ${suite_status}。"; }
grep -Fqx "ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.1.png" "$suite_result/rerecorded-snapshots.txt" \
  || { cat "$suite_result/rerecorded-snapshots.txt" >&2; fail "rerecorded-snapshots.txt 缺少重录 PNG。"; }
grep -Fqx "ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.深色 模式.png" "$suite_result/rerecorded-snapshots.txt" \
  || { cat "$suite_result/rerecorded-snapshots.txt" >&2; fail "含非 ASCII 与空格的重录路径不得被 git 引号转义破坏。"; }
[[ -f "$suite_result/rerecorded-snapshots/ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.深色 模式.png" ]] \
  || fail "含非 ASCII 与空格的重录快照 artifact 未被正确复制。"
grep -Fq "::error title=快照漂移（已重录）::GammaSnapshotTests/testShot（2 张）" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "全量脚本未在分类前向 verify-results 传入重录清单。"; }
grep -Fq "::warning title=抖动用例（重试后通过）::AlphaTests/testThree" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "全量脚本中的真抖动用例应保留 warning 注解。"; }
if grep -Fq "::warning title=抖动用例（重试后通过）::GammaSnapshotTests/testShot" "$work_root/out.txt"; then
  cat "$work_root/out.txt" >&2
  fail "全量脚本不得再把重录快照标成抖动。"
fi
grep -Fq "## iOS 全量 XCTest 按类执行数" "$suite_summary" || fail "GITHUB_STEP_SUMMARY 缺少按类执行数段落。"
grep -Fq "## 重录快照（2 张，需逐张核对后再提交）" "$suite_summary" || fail "GITHUB_STEP_SUMMARY 缺少重录快照段落。"

# 端到端 2：无结果包（full.xcresult 缺失）+ 已重录快照，必须保留原失败码与 artifact，不放宽且不标抖动。
fixture_index=$((fixture_index + 1))
suite_repo="$work_root/suite-no-bundle"
make_suite_repo "$suite_repo"
suite_result="$work_root/suite-no-bundle-result"
suite_summary="$work_root/suite-no-bundle-summary.md"
: > "$suite_summary"
suite_status=0
PATH="$mock_bin:$PATH" \
  MOCK_TESTS_JSON="$work_root/mixed.json" \
  MOCK_CREATE_BUNDLE=false \
  MOCK_RERECORD_MODE="single" \
  MOCK_IOS_DEV_EXIT=65 \
  GITHUB_ACTIONS=true \
  GITHUB_STEP_SUMMARY="$suite_summary" \
  bash "$suite_repo/scripts/test-ios-full-suite.sh" \
    --result-dir "$suite_result" \
    --record-failed-snapshots > "$work_root/out.txt" 2>&1 || suite_status=$?
[[ "$suite_status" -eq 65 ]] || { cat "$work_root/out.txt" >&2; fail "无结果包且 xcodebuild 返回 65 时必须保留退出码 65，实际 ${suite_status}。"; }
grep -Fq "没有生成 ${suite_result}/full.xcresult（xcodebuild 退出码 65），无法核对执行数。" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "无结果包时缺少明确错误提示。"; }
[[ -f "$suite_result/rerecorded-snapshots/ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.1.png" ]] \
  || fail "无结果包时也应保留已重录的快照 artifact。"
grep -Fq "::error title=快照漂移（已重录，未知）::" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "无结果包且有重录时应标为未知 error 注解。"; }
if grep -Fq "抖动用例（重试后通过）" "$work_root/out.txt"; then
  fail "无结果包场景不得输出抖动告警。"
fi

# 端到端 3：无结果包且 xcodebuild 异常返回 0 时也必须判失败。
fixture_index=$((fixture_index + 1))
suite_repo="$work_root/suite-no-bundle-zero"
make_suite_repo "$suite_repo"
suite_result="$work_root/suite-no-bundle-zero-result"
suite_status=0
PATH="$mock_bin:$PATH" \
  MOCK_TESTS_JSON="$work_root/pass.json" \
  MOCK_CREATE_BUNDLE=false \
  MOCK_RERECORD_MODE="none" \
  MOCK_IOS_DEV_EXIT=0 \
  bash "$suite_repo/scripts/test-ios-full-suite.sh" \
    --result-dir "$suite_result" \
    --record-failed-snapshots > "$work_root/out.txt" 2>&1 || suite_status=$?
[[ "$suite_status" -eq 1 ]] || { cat "$work_root/out.txt" >&2; fail "无结果包且 xcodebuild 返回 0 时必须返回 1，实际 ${suite_status}。"; }

# 端到端 4：XCTest 失败（test_status=65）且有重录时保留原退出码 65 与失败诊断。
fixture_index=$((fixture_index + 1))
suite_repo="$work_root/suite-xctest-fail"
make_suite_repo "$suite_repo"
suite_result="$work_root/suite-xctest-fail-result"
suite_status=0
PATH="$mock_bin:$PATH" \
  MOCK_TESTS_JSON="$work_root/failed-and-rerecorded.json" \
  MOCK_RERECORD_MODE="single" \
  MOCK_IOS_DEV_EXIT=65 \
  bash "$suite_repo/scripts/test-ios-full-suite.sh" \
    --result-dir "$suite_result" \
    --record-failed-snapshots > "$work_root/out.txt" 2>&1 || suite_status=$?
[[ "$suite_status" -eq 65 ]] || { cat "$work_root/out.txt" >&2; fail "XCTest 失败时必须保留原退出码 65，实际 ${suite_status}。"; }
grep -Fq "MOCK_SUMMARY_DIAGNOSTIC" "$work_root/out.txt" || fail "XCTest 失败时应保留 xcresulttool summary 诊断。"
[[ -f "$suite_result/rerecorded-snapshots/ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.1.png" ]] \
  || fail "XCTest 失败且有重录时仍应保留重录 artifact。"

# 端到端 5：符号链接快照变更必须拒绝复制、标为未知且不标抖动并判失败。
fixture_index=$((fixture_index + 1))
suite_repo="$work_root/suite-symlink"
make_suite_repo "$suite_repo"
suite_result="$work_root/suite-symlink-result"
suite_status=0
PATH="$mock_bin:$PATH" \
  MOCK_TESTS_JSON="$work_root/mixed.json" \
  MOCK_RERECORD_MODE="symlink" \
  MOCK_IOS_DEV_EXIT=0 \
  GITHUB_ACTIONS=true \
  bash "$suite_repo/scripts/test-ios-full-suite.sh" \
    --result-dir "$suite_result" \
    --record-failed-snapshots > "$work_root/out.txt" 2>&1 || suite_status=$?
[[ "$suite_status" -eq 1 ]] || { cat "$work_root/out.txt" >&2; fail "符号链接快照变更必须返回 1，实际 ${suite_status}。"; }
[[ ! -e "$suite_result/rerecorded-snapshots/ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.link.png" ]] \
  || fail "符号链接快照不得被复制到 artifact 目录。"
grep -Fq "::error title=快照漂移（已重录，未知）::" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "符号链接快照异常应标为未知。"; }
if grep -Fq "抖动用例（重试后通过）" "$work_root/out.txt"; then
  fail "符号链接快照异常场景不得把重试通过标为抖动。"
fi

# 端到端 6：开启 --record-failed-snapshots 但无重录快照且全通过时返回 0。
fixture_index=$((fixture_index + 1))
suite_repo="$work_root/suite-clean"
make_suite_repo "$suite_repo"
suite_result="$work_root/suite-clean-result"
PATH="$mock_bin:$PATH" \
  MOCK_TESTS_JSON="$work_root/pass.json" \
  MOCK_RERECORD_MODE="none" \
  MOCK_IOS_DEV_EXIT=0 \
  bash "$suite_repo/scripts/test-ios-full-suite.sh" \
    --result-dir "$suite_result" \
    --record-failed-snapshots > "$work_root/out.txt" 2>&1 \
  || { cat "$work_root/out.txt" >&2; fail "无重录快照且全部通过时应返回 0。"; }
[[ -f "$suite_result/rerecorded-snapshots.txt" && ! -s "$suite_result/rerecorded-snapshots.txt" ]] \
  || fail "无重录快照时 rerecorded-snapshots.txt 应为空文件。"

# 夹具：清单含 0x0B（垂直制表符）、\r、\x0C 等控制字符时按 LF 读取完整路径，不得被 splitlines() 切分成合法 PNG。
new_fixture
printf 'ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.1.png\x0b\n' \
  > "$work_root/vt-rerecorded.txt"
printf 'ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.2.png\r\n' \
  >> "$work_root/vt-rerecorded.txt"
printf 'ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.3.png\x0c\n' \
  >> "$work_root/vt-rerecorded.txt"
if GITHUB_ACTIONS=true python3 "$inventory" --root "$root" verify-results \
  "$work_root/mixed.json" \
  --markdown "$work_root/vt.md" \
  --rerecorded-list "$work_root/vt-rerecorded.txt" > "$work_root/out.txt" 2>&1; then
  cat "$work_root/out.txt" >&2
  fail "含 0x0B 等控制字符的重录路径必须判失败。"
fi
grep -Fq "快照漂移（已重录，无法映射/未知，判失败）：3 条" "$work_root/vt.md" \
  || { cat "$work_root/vt.md" >&2; fail "含 0x0B/\\r/0x0C 控制字符的路径应全部标为未知。"; }
grep -Fq 'testShot.1.png\x0b（未知：路径包含控制字符）' "$work_root/vt.md" \
  || { cat "$work_root/vt.md" >&2; fail "含 0x0B 控制字符的路径应给出控制字符未知原因。"; }
grep -Fq 'testShot.2.png\x0d（未知：路径包含控制字符）' "$work_root/vt.md" \
  || { cat "$work_root/vt.md" >&2; fail "含 CR（\\r）控制字符的路径不得被 universal newlines 剥离。"; }
grep -Fq 'testShot.3.png\x0c（未知：路径包含控制字符）' "$work_root/vt.md" \
  || { cat "$work_root/vt.md" >&2; fail "含 0x0C 控制字符的路径应给出控制字符未知原因。"; }
if grep -Fq "::error title=快照漂移（已重录）::GammaSnapshotTests/testShot" "$work_root/out.txt"; then
  cat "$work_root/out.txt" >&2
  fail "含 0x0B 控制字符的路径不得被误归类为合法重录快照。"
fi
grep -Fq "::error title=快照漂移（已重录，未知）::" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "含 0x0B 控制字符的路径缺少未知 error 注解。"; }
grep -Fq "::warning title=重试后通过（归属未知）::GammaSnapshotTests/testShot" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "含 0x0B 控制字符场景下重试通过用例应标为归属未知。"; }
grep -Fq '| GammaSnapshotTests | 1 | 0 | 1 | 1 | 1 | 0 | 0 | 0 |' "$work_root/vt.md" \
  || { cat "$work_root/vt.md" >&2; fail "含 0x0B 控制字符场景下已确认抖动列应为 0。"; }
if grep -Fq "抖动用例（重试后通过）" "$work_root/out.txt"; then
  cat "$work_root/out.txt" >&2
  fail "含 0x0B 控制字符场景下不得输出已确认抖动告警。"
fi

# 夹具：结果损坏（无效 JSON）+ 已采集重录快照时，保留摘要诊断并明确标为未知归属。
new_fixture
if GITHUB_ACTIONS=true python3 "$inventory" --root "$root" verify-results \
  "$work_root/bad.json" \
  --markdown "$work_root/bad-rerecorded.md" \
  --rerecorded-list "$work_root/mixed-rerecorded.txt" > "$work_root/out.txt" 2>&1; then
  cat "$work_root/out.txt" >&2
  fail "结果损坏且存在重录快照时应判失败。"
fi
grep -Fq "无法解析测试结果 JSON" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "结果损坏时缺少 JSON 解析错误提示。"; }
[[ -f "$work_root/bad-rerecorded.md" ]] || fail "结果损坏且有重录快照时仍应生成 summary.md 诊断。"
grep -Fq "快照漂移（已重录，无法映射/未知，判失败）：1 条" "$work_root/bad-rerecorded.md" \
  || { cat "$work_root/bad-rerecorded.md" >&2; fail "结果损坏时已采集重录快照应标明未知归属。"; }
grep -Fq "ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.1.png" "$work_root/bad-rerecorded.md" \
  || { cat "$work_root/bad-rerecorded.md" >&2; fail "结果损坏摘要未列出已采集的重录快照路径。"; }
grep -Fq "::error title=快照漂移（已重录，未知）::" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "结果损坏且有重录快照时应输出未知归属 error 注解。"; }
if grep -Fq "抖动用例（重试后通过）" "$work_root/out.txt"; then
  fail "结果损坏场景不得输出抖动告警。"
fi

# 端到端 7：测试前 git status 查询失败时必须立即阻断，不得放行进入测试。
fixture_index=$((fixture_index + 1))
suite_repo="$work_root/suite-pre-git-fail"
make_suite_repo "$suite_repo"
suite_result="$work_root/suite-pre-git-fail-result"
suite_status=0
PATH="$mock_bin:$PATH" \
  MOCK_TESTS_JSON="$work_root/pass.json" \
  MOCK_GIT_FAIL_PHASE="pre" \
  MOCK_GIT_FAIL_EXIT=128 \
  bash "$suite_repo/scripts/test-ios-full-suite.sh" \
    --result-dir "$suite_result" \
    --record-failed-snapshots > "$work_root/out.txt" 2>&1 || suite_status=$?
[[ "$suite_status" -eq 128 ]] || { cat "$work_root/out.txt" >&2; fail "测试前 git status 失败时必须返回退出码 128，实际 ${suite_status}。"; }
grep -Fq "重录前查询" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "测试前 git status 失败时缺少明确提示。"; }
[[ ! -d "$suite_result/full.xcresult" ]] || fail "测试前 git status 失败时不应继续执行测试。"

# 端到端 8a：XCTest 返回 0、全部通过，但测试后 git status 尚未输出即失败，必须保持非零并报告采集失败与归属未知。
fixture_index=$((fixture_index + 1))
suite_repo="$work_root/suite-post-git-fail-pass"
make_suite_repo "$suite_repo"
suite_result="$work_root/suite-post-git-fail-pass-result"
suite_summary="$work_root/suite-post-git-fail-pass-summary.md"
: > "$suite_summary"
suite_status=0
PATH="$mock_bin:$PATH" \
  MOCK_TESTS_JSON="$work_root/pass.json" \
  MOCK_RERECORD_MODE="none" \
  MOCK_IOS_DEV_EXIT=0 \
  MOCK_GIT_FAIL_PHASE="post" \
  MOCK_GIT_FAIL_EXIT=128 \
  GITHUB_ACTIONS=true \
  GITHUB_STEP_SUMMARY="$suite_summary" \
  bash "$suite_repo/scripts/test-ios-full-suite.sh" \
    --result-dir "$suite_result" \
    --record-failed-snapshots > "$work_root/out.txt" 2>&1 || suite_status=$?
[[ "$suite_status" -ne 0 ]] || { cat "$work_root/out.txt" >&2; fail "XCTest 返回 0 但测试后 git status 失败时必须返回非零。"; }
[[ -f "$suite_result/tests.json" && -f "$suite_result/summary.md" ]] \
  || fail "测试后 git status 失败时仍应保留 tests.json 与 summary.md。"
grep -Fq "测试后查询" "$suite_result/summary.md" \
  || { cat "$suite_result/summary.md" >&2; fail "测试后 git status 失败应在 summary.md 报告采集失败。"; }
grep -Fq "无法确认完整清单/归属未知" "$suite_result/summary.md" \
  || { cat "$suite_result/summary.md" >&2; fail "测试后 git status 失败应在 summary.md 报告归属未知。"; }
grep -Fq "::error title=重录快照采集失败::" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "测试后 git status 失败应输出采集失败 error 注解。"; }
grep -Fq "::error title=快照漂移（已重录，未知）::" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "测试后 git status 失败应输出归属未知 error 注解。"; }
grep -Fq "## 重录快照（采集失败，清单不完整" "$suite_summary" \
  || { cat "$suite_summary" >&2; fail "GITHUB_STEP_SUMMARY 应标明重录快照采集失败且清单不完整。"; }

# 端到端 8b：XCTest 返回 0 且存在重试通过用例，但测试后 git status 失败，重试通过必须标为归属未知而非抖动。
fixture_index=$((fixture_index + 1))
suite_repo="$work_root/suite-post-git-fail-retry"
make_suite_repo "$suite_repo"
suite_result="$work_root/suite-post-git-fail-retry-result"
suite_status=0
PATH="$mock_bin:$PATH" \
  MOCK_TESTS_JSON="$work_root/flaky.json" \
  MOCK_RERECORD_MODE="none" \
  MOCK_IOS_DEV_EXIT=0 \
  MOCK_GIT_FAIL_PHASE="post" \
  MOCK_GIT_FAIL_EXIT=128 \
  GITHUB_ACTIONS=true \
  bash "$suite_repo/scripts/test-ios-full-suite.sh" \
    --result-dir "$suite_result" \
    --record-failed-snapshots > "$work_root/out.txt" 2>&1 || suite_status=$?
[[ "$suite_status" -ne 0 ]] || { cat "$work_root/out.txt" >&2; fail "存在重试通过且测试后 git status 失败时必须返回非零。"; }
grep -Fq '| AlphaTests | 3 | 0 | 3 | 3 | 2 | 0 | 0 | 1 |' "$suite_result/summary.md" \
  || { cat "$suite_result/summary.md" >&2; fail "测试后 git status 失败时已确认抖动列必须为 0。"; }
grep -Fq "::warning title=重试后通过（归属未知）::AlphaTests/testThree" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "测试后 git status 失败时重试通过用例应标为归属未知。"; }
if grep -Fq "抖动用例（重试后通过）" "$work_root/out.txt"; then
  cat "$work_root/out.txt" >&2
  fail "测试后 git status 失败时不得把重试通过误标为抖动。"
fi

# 端到端 9：真实文件名 testShot.1.png 后接 0x0B 时保持失败、拒绝复制并标为未知。
fixture_index=$((fixture_index + 1))
suite_repo="$work_root/suite-vt-control"
make_suite_repo "$suite_repo"
suite_result="$work_root/suite-vt-control-result"
suite_status=0
PATH="$mock_bin:$PATH" \
  MOCK_TESTS_JSON="$work_root/mixed.json" \
  MOCK_RERECORD_MODE="vt_control" \
  MOCK_IOS_DEV_EXIT=0 \
  GITHUB_ACTIONS=true \
  bash "$suite_repo/scripts/test-ios-full-suite.sh" \
    --result-dir "$suite_result" \
    --record-failed-snapshots > "$work_root/out.txt" 2>&1 || suite_status=$?
[[ "$suite_status" -eq 1 ]] || { cat "$work_root/out.txt" >&2; fail "含 0x0B 文件名的重录快照必须返回 1，实际 ${suite_status}。"; }
[[ -f "$suite_result/tests.json" && -f "$suite_result/summary.md" ]] \
  || fail "含 0x0B 文件名场景仍应保留 tests.json 与 summary.md。"
if [[ -d "$suite_result/rerecorded-snapshots" ]] && find "$suite_result/rerecorded-snapshots" -type f | grep -q .; then
  fail "含 0x0B 控制字符的快照文件不得被复制到 artifact 目录。"
fi
grep -Fq "::error title=快照漂移（已重录，未知）::" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "含 0x0B 文件名的重录快照应标为未知。"; }
if grep -Fq "::error title=快照漂移（已重录）::GammaSnapshotTests/testShot" "$work_root/out.txt"; then
  cat "$work_root/out.txt" >&2
  fail "含 0x0B 文件名的快照不得误归类为 GammaSnapshotTests/testShot 已确认重录。"
fi
if grep -Fq "抖动用例（重试后通过）" "$work_root/out.txt"; then
  cat "$work_root/out.txt" >&2
  fail "含 0x0B 文件名场景下不得输出已确认抖动告警。"
fi

# 端到端 10：结果提取失败（xcresulttool get test-results tests 非零）时维持非零，保留重录摘要、快照与诊断。
fixture_index=$((fixture_index + 1))
suite_repo="$work_root/suite-extract-fail"
make_suite_repo "$suite_repo"
suite_result="$work_root/suite-extract-fail-result"
suite_summary="$work_root/suite-extract-fail-summary.md"
: > "$suite_summary"
suite_status=0
PATH="$mock_bin:$PATH" \
  MOCK_XCRESULT_TESTS_EXIT=2 \
  MOCK_RERECORD_MODE="single" \
  MOCK_IOS_DEV_EXIT=0 \
  GITHUB_ACTIONS=true \
  GITHUB_STEP_SUMMARY="$suite_summary" \
  bash "$suite_repo/scripts/test-ios-full-suite.sh" \
    --result-dir "$suite_result" \
    --record-failed-snapshots > "$work_root/out.txt" 2>&1 || suite_status=$?
[[ "$suite_status" -eq 2 ]] || { cat "$work_root/out.txt" >&2; fail "结果提取返回 2 时必须保留非零退出码 2，实际 ${suite_status}。"; }
[[ -f "$suite_result/rerecorded-snapshots/ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.1.png" ]] \
  || fail "结果提取失败时必须保留已采集的重录快照 artifact。"
[[ -f "$suite_result/summary.md" ]] || fail "结果提取失败时应保留 summary.md 诊断。"
grep -Fq "提取测试结果失败" "$suite_result/summary.md" \
  || { cat "$suite_result/summary.md" >&2; fail "结果提取失败时 summary.md 应说明提取失败。"; }
grep -Fq "快照漂移（已重录，无法映射/未知，判失败）：1 条" "$suite_result/summary.md" \
  || { cat "$suite_result/summary.md" >&2; fail "结果提取失败时 summary.md 应把已采集重录标为未知归属。"; }
grep -Fq "## 重录快照（1 张，需逐张核对后再提交）" "$suite_summary" \
  || { cat "$suite_summary" >&2; fail "结果提取失败时不得跳过 GITHUB_STEP_SUMMARY 的重录摘要。"; }
grep -Fq "::error title=快照漂移（已重录，未知）::" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "结果提取失败且有重录快照时应输出未知归属 error 注解。"; }
grep -Fq "MOCK_SUMMARY_DIAGNOSTIC" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "结果提取失败时应保留 xcresulttool summary 诊断。"; }
grep -Fq "结果目录：${suite_result}" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "结果提取失败时仍应打印结果目录。"; }

# 端到端 11：结果 JSON 损坏时维持非零，保留快照、损坏结果、未知归属摘要与 GITHUB_STEP_SUMMARY。
fixture_index=$((fixture_index + 1))
suite_repo="$work_root/suite-bad-json"
make_suite_repo "$suite_repo"
suite_result="$work_root/suite-bad-json-result"
suite_summary="$work_root/suite-bad-json-summary.md"
: > "$suite_summary"
suite_status=0
PATH="$mock_bin:$PATH" \
  MOCK_TESTS_JSON="$work_root/bad.json" \
  MOCK_RERECORD_MODE="single" \
  MOCK_IOS_DEV_EXIT=0 \
  GITHUB_ACTIONS=true \
  GITHUB_STEP_SUMMARY="$suite_summary" \
  bash "$suite_repo/scripts/test-ios-full-suite.sh" \
    --result-dir "$suite_result" \
    --record-failed-snapshots > "$work_root/out.txt" 2>&1 || suite_status=$?
[[ "$suite_status" -eq 1 ]] || { cat "$work_root/out.txt" >&2; fail "结果 JSON 损坏时必须返回 1，实际 ${suite_status}。"; }
[[ -f "$suite_result/tests.json" && -f "$suite_result/summary.md" ]] \
  || fail "结果 JSON 损坏时应保留 tests.json 与 summary.md。"
[[ -f "$suite_result/rerecorded-snapshots/ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.1.png" ]] \
  || fail "结果 JSON 损坏时应保留已采集的重录快照。"
grep -Fq "快照漂移（已重录，无法映射/未知，判失败）：1 条" "$suite_result/summary.md" \
  || { cat "$suite_result/summary.md" >&2; fail "结果 JSON 损坏时应把已采集重录标为未知归属。"; }
grep -Fq "## 重录快照（1 张，需逐张核对后再提交）" "$suite_summary" \
  || { cat "$suite_summary" >&2; fail "结果 JSON 损坏时 GITHUB_STEP_SUMMARY 应保留重录快照摘要。"; }
grep -Fq "::error title=快照漂移（已重录，未知）::" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "结果 JSON 损坏且有重录快照时应输出未知归属 error 注解。"; }

# 端到端 12：单张快照复制失败时不得中断后续采集，保留其余快照、tests.json、summary.md 与诊断并维持非零。
fixture_index=$((fixture_index + 1))
suite_repo="$work_root/suite-copy-fail"
make_suite_repo "$suite_repo"
suite_result="$work_root/suite-copy-fail-result"
suite_summary="$work_root/suite-copy-fail-summary.md"
: > "$suite_summary"
suite_status=0
PATH="$mock_bin:$PATH" \
  MOCK_TESTS_JSON="$work_root/mixed.json" \
  MOCK_RERECORD_MODE="mixed" \
  MOCK_FAIL_COPY_SUFFIX="testShot.1.png" \
  MOCK_IOS_DEV_EXIT=0 \
  GITHUB_ACTIONS=true \
  GITHUB_STEP_SUMMARY="$suite_summary" \
  bash "$suite_repo/scripts/test-ios-full-suite.sh" \
    --result-dir "$suite_result" \
    --record-failed-snapshots > "$work_root/out.txt" 2>&1 || suite_status=$?
[[ "$suite_status" -eq 1 ]] || { cat "$work_root/out.txt" >&2; fail "单张快照复制失败时必须返回 1，实际 ${suite_status}。"; }
[[ ! -e "$suite_result/rerecorded-snapshots/ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.1.png" ]] \
  || fail "被 mock 复制失败的 testShot.1.png 不应存在于 artifact 目录。"
[[ -f "$suite_result/rerecorded-snapshots/ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.深色 模式.png" ]] \
  || fail "单张复制失败不得中断后续正常快照的采集与复制。"
[[ -f "$suite_result/tests.json" && -f "$suite_result/summary.md" ]] \
  || fail "单张复制失败不得丢失 tests.json 与 summary.md。"
grep -Fqx "ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.1.png" "$suite_result/rerecorded-snapshots.txt" \
  || fail "复制失败的快照路径仍应保留在 rerecorded-snapshots.txt 清单中。"
grep -Fqx "ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__/GammaSnapshotTests/testShot.深色 模式.png" "$suite_result/rerecorded-snapshots.txt" \
  || fail "后续正常快照路径应保留在 rerecorded-snapshots.txt 清单中。"
grep -Fq "复制重录快照失败" "$suite_result/summary.md" \
  || { cat "$suite_result/summary.md" >&2; fail "summary.md 应记录单张快照复制失败诊断。"; }
grep -Fq "::error title=重录快照采集失败::" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "单张快照复制失败应输出采集失败 error 注解。"; }
grep -Fq "::error title=快照漂移（已重录）::GammaSnapshotTests/testShot（2 张）" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "单张快照复制失败仍应保留已识别的快照漂移分类。"; }
grep -Fq "::warning title=抖动用例（重试后通过）::AlphaTests/testThree" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "单张复制失败但清单完整时仍应保留非快照真抖动分类。"; }
grep -Fq "重录快照采集错误：" "$suite_summary" \
  || { cat "$suite_summary" >&2; fail "GITHUB_STEP_SUMMARY 应包含单张复制失败诊断。"; }

echo "iOS 测试清单自测通过：${fixture_index} 个夹具覆盖失效 selector、文件名 selector、归属、隔离、工程登记、按类执行数、重试抖动、重录快照分类与全量脚本端到端语义。"
