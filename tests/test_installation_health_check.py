"""Le bilan ne doit jamais considérer un ancien succès comme un nouveau test."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallationHealthCheckTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        source = (ROOT / "install.sh").read_text()
        start = source.index("verify_update_receipt() {")
        end = source.index("\n}\n", start) + 3
        self.function = source[start:end]
        self.state = {
            "run_id": "new-run",
            "boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
            "events": [{"status": status, "details": status} for status in
                       ("RUNNING_DNF", "RUNNING_FLATPAK", "RUNNING_FIRMWARE", "SUCCESS")]
        }

    def verify(self, previous="old-run", current=None):
        (self.root / "last-result.json").write_text(json.dumps(self.state))
        (self.root / "state.json").write_text(json.dumps(self.state if current is None else current))
        return subprocess.run(
            ["bash", "-c", self.function + '\nverify_update_receipt "$1" "$2"',
             "test", str(self.root), previous],
            text=True, capture_output=True, timeout=5)

    def test_fresh_complete_success_returns_notification_receipt(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "new-run:3")

    def test_old_success_is_rejected(self):
        self.assertNotEqual(self.verify(previous="new-run").returncode, 0)

    def test_previous_boot_is_rejected(self):
        self.state["boot_id"] = "old-boot"
        self.assertNotEqual(self.verify().returncode, 0)

    def test_failed_update_is_rejected(self):
        self.state["events"][-1]["status"] = "ERROR"
        self.assertNotEqual(self.verify().returncode, 0)

    def test_incomplete_sequence_is_rejected(self):
        self.state["events"].pop(1)
        self.assertNotEqual(self.verify().returncode, 0)

    def test_new_attempt_in_progress_is_not_confused_with_last_success(self):
        current = dict(self.state, run_id="other-run")
        self.assertNotEqual(self.verify(current=current).returncode, 0)

    def test_missing_result_is_rejected(self):
        result = subprocess.run(
            ["bash", "-c", self.function + '\nverify_update_receipt "$1" old-run',
             "test", str(self.root)], text=True, capture_output=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
