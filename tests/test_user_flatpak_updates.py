"""Les mises à jour personnelles utilisent exclusivement --user, sans root."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class UserFlatpakTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, body in {
            "flatpak": """
echo "$*" >> "$HOME/commands"
case " $* " in *" --user "*) ;; *) exit 99 ;; esac
if [ "$1" = update ]; then
    touch "$HOME/updated"
    exit "${TEST_UPDATE_RC:-0}"
fi
if [ "${TEST_EMPTY:-0}" = 1 ]; then exit 0; fi
if [ -f "$HOME/updated" ]; then
    printf 'app/example/x86_64/stable\\tnew\\n'
else
    printf 'app/example/x86_64/stable\\told\\n'
fi
""",
            "notify-send": 'exit "${TEST_NOTIFY_RC:-0}"',
        }.items():
            file = self.bin / name
            file.write_text("#!/bin/bash\n" + body + "\n")
            file.chmod(0o755)
        self.script = self.root / "updater"
        self.script.write_text(
            (ROOT / "files/fedora-user-flatpak-update").read_text()
            .replace("export PATH=/usr/bin:/bin", "# PATH des mocks")
            .replace('if [ "$EUID" -eq 0 ]; then', "if false; then"))
        self.env = dict(os.environ, HOME=str(self.root),
                        PATH=f"{self.bin}:{os.environ['PATH']}", INVOCATION_ID="test-invocation")
        self.state = self.root / ".local/state/fedora-auto-update-user"

    def run_update(self, **extra):
        return subprocess.run(["bash", str(self.script)], env=dict(self.env, **extra),
                              capture_output=True, text=True, timeout=10)

    def test_updates_personal_scope_and_counts_commits(self):
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 application(s)", (self.state / "result.txt").read_text())
        self.assertEqual((self.state / "invocation-id").read_text().strip(), "test-invocation")
        self.assertNotIn("--system", (self.root / "commands").read_text())

    def test_flatpak_failure_is_preserved(self):
        self.assertEqual(self.run_update(TEST_UPDATE_RC="1").returncode, 1)
        self.assertEqual((self.state / "status").read_text().strip(), "ERROR")

    def test_notification_failure_does_not_prevent_update(self):
        self.assertEqual(self.run_update(TEST_NOTIFY_RC="1").returncode, 0)
        self.assertTrue((self.root / "updated").exists())

    def test_no_personal_apps_is_success_with_zero_count(self):
        self.assertEqual(self.run_update(TEST_EMPTY="1").returncode, 0)
        self.assertIn("0 application(s)", (self.state / "result.txt").read_text())

    def test_root_is_refused_before_any_changes(self):
        self.script.write_text(self.script.read_text().replace("if false; then", "if true; then"))
        self.assertEqual(self.run_update().returncode, 1)
        self.assertFalse((self.root / "commands").exists())
        self.assertFalse(self.state.exists())
