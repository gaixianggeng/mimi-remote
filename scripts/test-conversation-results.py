#!/usr/bin/env python3
"""Exercise the real runner with tiny fake bundles; never launch Xcode or a device."""
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


RUNNER = Path(__file__).resolve().parent / "test-conversation-regressions.sh"


class ConversationResultPolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mimi result policy ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copy2(RUNNER, scripts / RUNNER.name)
        (scripts / "ios-test-inventory.py").write_text(
            'print("-skip-testing:MimiRemoteTests/Fixture/testQuarantined")\n'
        )
        (scripts / "ios-dev.sh").write_text(
            '#!/usr/bin/env bash\nexec python3 "$(dirname "$0")/fake-ios.py" "$@"\n'
        )
        (scripts / "fake-ios.py").write_text('''import json, os, signal, sys, time
from pathlib import Path
args = sys.argv[1:]
bundle = Path(args[args.index("-resultBundlePath") + 1])
bundle.mkdir(parents=True)
(bundle / "marker").write_text("synthetic result")
signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
Path(os.environ["FAKE_ARGS"]).write_text(json.dumps(args))
if os.environ.get("FAKE_WAIT") == "1":
    time.sleep(30)
sys.exit(int(os.environ.get("FAKE_STATUS", "0")))
''')
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # Bypass macOS's /usr/bin/python3 shim, which can invoke Xcode discovery.
        (self.bin / "python3").symlink_to(sys.executable)
        summary = self.bin / "xcrun"
        summary.write_text(
            '#!/usr/bin/env bash\necho "fixture failure summary"\nexit "${FAKE_SUMMARY_STATUS:-0}"\n'
        )
        summary.chmod(0o755)
        self.tmp = self.root / "temporary results"
        self.tmp.mkdir()
        self.args_file = self.root / "arguments.json"
        self.env = dict(os.environ, TMPDIR=str(self.tmp), FAKE_ARGS=str(self.args_file),
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        self.command = ["bash", str(scripts / RUNNER.name), "--ios-only"]

    def run_runner(self, *args, **env):
        return subprocess.run(self.command + list(args), env=dict(self.env, **env),
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              timeout=10)

    def bundle(self):
        args = json.loads(self.args_file.read_text())
        return Path(args[args.index("-resultBundlePath") + 1])

    def test_success_removes_only_its_owned_directory_and_keeps_selectors(self):
        existing = self.tmp / "mimi-conversation-tests.existing" / "core.xcresult"
        existing.mkdir(parents=True)
        (existing / "marker").write_text("older evidence")
        result = self.run_runner()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.bundle().parent.exists(), result.stdout)
        self.assertEqual((existing / "marker").read_text(), "older evidence")
        args = json.loads(self.args_file.read_text())
        expected = re.findall(r"^\s+(-only-testing:\S+)", RUNNER.read_text(), re.M)
        self.assertEqual([arg for arg in args if arg.startswith("-only-testing:")], expected)
        self.assertIn("-skip-testing:MimiRemoteTests/Fixture/testQuarantined", args)
        self.assertIn("已清理", result.stdout)

    def test_failure_keeps_summary_and_original_exit_even_if_summary_fails(self):
        result = self.run_runner(FAKE_STATUS="65", FAKE_SUMMARY_STATUS="9")
        self.assertEqual(result.returncode, 65, result.stdout)
        self.assertTrue((self.bundle() / "marker").exists())
        self.assertIn("fixture failure summary", result.stdout)
        self.assertIn(str(self.bundle().parent), result.stdout)

    def test_explicit_directory_keeps_success_and_failure(self):
        for status in [0, 65]:
            with self.subTest(status=status):
                directory = self.root / ("requested results " + str(status))
                directory.mkdir()
                (directory / "unrelated").write_text("keep")
                result = self.run_runner("--result-dir", str(directory), FAKE_STATUS=str(status))
                self.assertEqual(result.returncode, status, result.stdout)
                self.assertEqual(self.bundle(), directory / "core.xcresult")
                self.assertTrue((self.bundle() / "marker").exists())
                self.assertEqual((directory / "unrelated").read_text(), "keep")
                self.assertIn(str(directory), result.stdout)

    def test_existing_bundle_is_rejected_without_overwriting(self):
        directory = self.root / "requested"
        bundle = directory / "core.xcresult"
        bundle.mkdir(parents=True)
        (bundle / "marker").write_text("original")
        result = self.run_runner("--result-dir", str(directory))
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertFalse(self.args_file.exists())
        self.assertEqual((bundle / "marker").read_text(), "original")

    def test_dangling_bundle_symlink_is_also_rejected(self):
        directory = self.root / "requested"
        directory.mkdir()
        bundle = directory / "core.xcresult"
        bundle.symlink_to(self.root / "missing-target")
        result = self.run_runner("--result-dir", str(directory))
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertFalse(self.args_file.exists())
        self.assertTrue(bundle.is_symlink())

    def test_missing_directory_argument_is_rejected_before_running(self):
        result = self.run_runner("--result-dir")
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertFalse(self.args_file.exists())
        self.assertEqual(list(self.tmp.iterdir()), [])

    def assert_cancellation(self, sig, expected_status):
        process = subprocess.Popen(self.command, env=dict(self.env, FAKE_WAIT="1"),
                                   text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            deadline = time.monotonic() + 5
            while not self.args_file.exists() and time.monotonic() < deadline:
                self.assertIsNone(process.poll())
                time.sleep(0.01)
            self.assertTrue(self.args_file.exists(), "fake test did not start")
            # This process group contains only our copied runner and fake build child.
            os.killpg(process.pid, sig)
            output, _ = process.communicate(timeout=5)
            self.assertEqual(process.returncode, expected_status, output)
            self.assertTrue((self.bundle() / "marker").exists())
            self.assertIn(str(self.bundle().parent), output)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=5)

    def test_term_keeps_results_and_exit_143(self):
        self.assert_cancellation(signal.SIGTERM, 143)

    def test_interrupt_keeps_results_and_exit_130(self):
        self.assert_cancellation(signal.SIGINT, 130)

    def test_cleanup_failure_does_not_replace_test_exit_status(self):
        rm = self.bin / "rm"
        rm.write_text('#!/usr/bin/env bash\nexit 42\n')
        rm.chmod(0o755)
        result = self.run_runner()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue((self.bundle() / "marker").exists())
        self.assertIn("清理失败", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
