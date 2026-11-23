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
cat > "$mock_bin/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "xcresulttool" && "${2:-}" == "get" && "${3:-}" == "test-results" && "${4:-}" == "tests" ]]; then
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

echo "iOS 测试清单自测通过：${fixture_index} 个夹具覆盖失效 selector、文件名 selector、归属、隔离、工程登记、按类执行数、重试抖动、重录快照分类与全量脚本端到端语义。"
