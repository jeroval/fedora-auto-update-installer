"""Tests isolés : aucun gestionnaire de paquets réel n'est exécuté."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ScriptsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.state = self.root / "state"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        HOME=str(self.root), XDG_CACHE_HOME=str(self.root / "cache"),
                        TEST_ROOT=str(self.root))
        mocks = {
            "dnf5": 'touch "$TEST_ROOT/rpm-done"; exit "${TEST_DNF_STATUS:-0}"',
            "rpm": """
if [ "$1" = -q ]; then
    if [ "${TEST_NEW_KERNEL:-0}" = 1 ]; then echo 99.0-test.x86_64; else uname -r; fi
    exit 0
fi
if [ "${RPM_FAIL:-0}" = 1 ]; then exit 1; fi
if [ -f "$TEST_ROOT/rpm-done" ]; then
    printf 'pkg\\tx86_64\\t0:2-1\\nkernel\\tx86_64\\t0:1-1\\nkernel\\tx86_64\\t0:2-1\\n'
else
    printf 'pkg\\tx86_64\\t0:1-1\\nkernel\\tx86_64\\t0:1-1\\n'
fi
""",
            "flatpak": """
if [ "$1" = update ]; then
    touch "$TEST_ROOT/flatpak-done"
    exit "${TEST_FLATPAK_STATUS:-0}"
fi
if [ -f "$TEST_ROOT/flatpak-done" ]; then
    printf 'app/org.example.App/x86_64/stable\\tnewcommit\\n'
else
    printf 'app/org.example.App/x86_64/stable\\toldcommit\\n'
fi
""",
            "fwupdmgr": """
echo "$*" >> "$TEST_ROOT/fwupd-args"
if [ "${INTERRUPT:-0}" = 1 ]; then kill -TERM "$PPID"; exit 1; fi
exit "${TEST_FWUPD_STATUS:-2}"
""",
            "df": 'printf "Filesystem 1024-blocks Used Available Capacity Mounted\\nmock 999999 1000 ${TEST_FREE_KB:-999999} 1%% /\\n"',
            "busctl": 'echo org.freedesktop.Notifications',
            "notify-send": """
[ "${NOTIFY_FAIL:-0}" = 0 ] || exit 1
echo sent >> "$TEST_ROOT/sent"
""",
        }
        for name, body in mocks.items():
            path = self.bin / name
            path.write_text("#!/bin/bash\n" + body + "\n")
            path.chmod(0o755)
        self.updater = self.root / "updater"
        self.updater.write_text(
            (ROOT / "files/fedora-auto-update").read_text()
            .replace("/var/lib/fedora-auto-update", str(self.state))
            .replace('if [ "$EUID" -ne 0 ]; then', "if false; then")
            .replace("export PATH=/usr/sbin:/usr/bin:/sbin:/bin", "# PATH fourni par les mocks")
            .replace('[ "$(stat -c \'%u\' "$STATE_DIR")" -eq 0 ]', "true"))
        self.notifier = self.root / "notifier"
        self.notifier.write_text(
            (ROOT / "files/fedora-update-notifier").read_text()
            .replace("/var/lib/fedora-auto-update", str(self.state)))

    def run_script(self, script, **overrides):
        return subprocess.run(["bash", str(script)], env=dict(self.env, **overrides),
                              capture_output=True, text=True, timeout=10)

    def state_json(self):
        return json.loads((self.state / "state.json").read_text())

    def test_success_counts_and_firmware_no_action(self):
        result = self.run_script(self.updater)
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.state_json()
        self.assertEqual([e["status"] for e in state["events"]],
                         ["RUNNING_DNF", "RUNNING_FLATPAK", "RUNNING_FIRMWARE", "SUCCESS"])
        details = state["events"][-1]["details"]
        self.assertIn("2 paquet(s)", details)
        self.assertIn("1 application(s)", details)
        self.assertIn("--no-reboot-check", (self.root / "fwupd-args").read_text())
        self.assertTrue((self.state / "last-run.log").exists())

    def test_each_failure_is_reported_and_all_steps_attempted(self):
        for variable in ("TEST_DNF_STATUS", "TEST_FLATPAK_STATUS", "TEST_FWUPD_STATUS"):
            with self.subTest(variable=variable):
                result = self.run_script(self.updater, **{variable: "1"})
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(self.state_json()["events"][-1]["status"], "ERROR")
                self.assertTrue((self.root / "fwupd-args").exists())

    def test_unavailable_count_is_not_zero(self):
        result = self.run_script(self.updater, RPM_FAIL="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("indisponible paquet(s)", (self.state / "details").read_text())

    def test_notification_retry_and_deduplication(self):
        self.assertEqual(self.run_script(self.updater).returncode, 0)
        self.assertEqual(self.run_script(self.notifier, NOTIFY_FAIL="1").returncode, 1)
        self.assertFalse((self.root / "cache/fedora-auto-update/last-event").exists())
        self.assertEqual(self.run_script(self.notifier).returncode, 0)
        self.assertEqual(self.run_script(self.notifier).returncode, 0)
        self.assertEqual((self.root / "sent").read_text().splitlines(), ["sent"] * 4)

    def test_interruption_publishes_error(self):
        result = self.run_script(self.updater, INTERRUPT="1")
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assertEqual(self.state_json()["events"][-1]["status"], "ERROR")

    def test_existing_lock_prevents_second_update(self):
        import fcntl
        self.state.mkdir()
        with (self.state / "update.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.run_script(self.updater).returncode, 0)
            self.assertFalse((self.root / "rpm-done").exists())

    def test_low_disk_stops_before_package_changes(self):
        result = self.run_script(self.updater, TEST_FREE_KB="100")
        self.assertEqual(result.returncode, 78, result.stderr)
        self.assertFalse((self.root / "rpm-done").exists())
        self.assertIn("Libérez", (self.state / "last-result.txt").read_text())

    def test_completed_result_and_history(self):
        self.assertEqual(self.run_script(self.updater).returncode, 0)
        first = json.loads((self.state / "last-result.json").read_text())
        self.assertEqual(first["events"][-1]["status"], "SUCCESS")
        self.assertEqual(self.run_script(self.updater, TEST_DNF_STATUS="1").returncode, 1)
        self.assertEqual(len(list((self.state / "history").glob("*.json"))), 2)
        self.assertEqual(len(list((self.state / "logs").glob("*.log"))), 1)

    def test_kernel_advice_is_not_repeated_during_same_boot(self):
        for _ in range(2):
            self.assertEqual(self.run_script(self.updater, TEST_NEW_KERNEL="1").returncode, 0)
            self.assertEqual(self.run_script(self.notifier).returncode, 0)
        self.assertEqual(len((self.root / "sent").read_text().splitlines()), 9)

    def test_previous_unfinished_run_is_archived_as_error(self):
        self.state.mkdir()
        (self.state / "state.json").write_text(json.dumps({
            "run_id": "old-run", "boot_id": "previous-boot",
            "events": [{"status": "RUNNING_DNF", "details": "en cours"}]}))
        self.assertEqual(self.run_script(self.updater).returncode, 0)
        states = [json.loads(p.read_text()) for p in (self.state / "history").glob("*.json")]
        self.assertTrue(any(x["run_id"] == "old-run" and x["events"][-1]["status"] == "ERROR" for x in states))

    def test_repeated_failure_recommends_investigation(self):
        for _ in range(3):
            self.assertEqual(self.run_script(self.updater, TEST_DNF_STATUS="1").returncode, 1)
        self.assertIn("Plusieurs tentatives", (self.state / "last-result.txt").read_text())


if __name__ == "__main__":
    unittest.main()
