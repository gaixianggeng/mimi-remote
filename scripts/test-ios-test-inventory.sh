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
  cat > "$path" <<EOF
{"testNodes":[{"nodeType":"Test Plan","name":"MimiRemote","children":[
  {"nodeType":"Unit test bundle","name":"MimiRemoteTests","children":[
    {"nodeType":"Test Suite","name":"AlphaTests","children":[
      {"nodeType":"Test Case","name":"testOne()","nodeIdentifier":"AlphaTests/testOne()","result":"Passed"},
      {"nodeType":"Test Case","name":"testTwo()","nodeIdentifier":"AlphaTests/testTwo()","result":"Skipped"},
      {"nodeType":"Test Case","name":"testThree()","nodeIdentifier":"AlphaTests/testThree()","result":"${alpha_three_result}"}
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
grep -Fq '| AlphaTests | 3 | 0 | 3 | 3 | 2 | 0 | 1 |' "$work_root/summary.md" \
  || { cat "$work_root/summary.md" >&2; fail "按类统计表不正确。"; }

write_results "$work_root/zero.json" "" "Passed"
if python3 "$inventory" --root "$root" verify-results "$work_root/zero.json" > "$work_root/out.txt" 2>&1; then
  fail "某个类执行 0 个时应失败。"
fi
grep -Fq "GammaSnapshotTests 应执行 1 个用例，实际执行 0 个" "$work_root/out.txt" \
  || { cat "$work_root/out.txt" >&2; fail "执行 0 个缺少明确提示。"; }

write_results "$work_root/failed.json" "$gamma" "Failed"
if python3 "$inventory" --root "$root" verify-results "$work_root/failed.json" > "$work_root/out.txt" 2>&1; then
  fail "存在失败用例时应失败。"
fi
grep -Fq -- "- AlphaTests/testThree" "$work_root/out.txt" || fail "失败用例没有列出。"

echo "iOS 测试清单自测通过：${fixture_index} 个夹具覆盖失效 selector、文件名 selector、归属、隔离、工程登记与按类执行数。"
