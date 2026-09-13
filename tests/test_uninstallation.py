"""Désinstallation simulée dans un dossier temporaire, sans privilèges."""
import fcntl
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class UninstallationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.state = self.root / "var/lib/fedora-auto-update"
        self.state.mkdir(parents=True)
        (self.state / "last-result.txt").write_text("résultat à conserver")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, body in {
            "sudo": 'shift 2\nexec "$@"',
            "systemctl": 'echo "$*" >> "$TEST_TRACE"\ncase " $* " in *" show "*) echo loaded ;; esac',
        }.items():
            path = self.bin / name
            path.write_text("#!/bin/bash\n" + body + "\n")
            path.chmod(0o755)
        self.env = dict(os.environ, SUDO_USER=os.environ.get("USER", "tester"),
                        TEST_USER_HOME=str(self.home), TEST_TRACE=str(self.root / "trace"),
                        PATH=f"{self.bin}:{os.environ['PATH']}")
        source = (ROOT / "uninstall.sh").read_text()
        source = source.replace("export PATH=/usr/sbin:/usr/bin:/sbin:/bin", "# chemins des mocks")
        source = source.replace('if [ "$EUID" -ne 0 ]; then', "if false; then")
        source = source.replace('USER_HOME="$(getent passwd "$INSTALL_USER" | cut -d: -f6)"',
                                'USER_HOME="$TEST_USER_HOME"')
        source = source.replace("-o root -g root ", "")
        for prefix in ("/var/lib/fedora-auto-update", "/usr/local/sbin", "/etc/systemd/system", "/run/user"):
            source = source.replace(prefix, str(self.root) + prefix)
        self.script = self.root / "uninstall.sh"
        self.script.write_text(source)
        self.files = [
            self.root / "usr/local/sbin/fedora-auto-update",
            self.root / "etc/systemd/system/fedora-auto-update.service",
            self.root / "etc/systemd/system/fedora-auto-update.timer",
            self.home / ".local/bin/fedora-update-notifier",
            self.home / ".config/systemd/user/fedora-update-notifier.service",
            self.home / ".config/systemd/user/fedora-update-notifier.timer",
        ]
        for file in self.files:
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text("outil")
        self.unrelated = self.home / ".local/bin/other-tool"
        self.unrelated.write_text("autre outil")

    def run_uninstall(self):
        return subprocess.run(["bash", str(self.script)], env=self.env,
                              capture_output=True, text=True, timeout=10)

    def test_removes_only_tool_and_is_repeatable(self):
        for _ in range(2):
            result = self.run_uninstall()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(all(not p.exists() for p in self.files))
            self.assertTrue((self.state / "last-result.txt").exists())
            self.assertTrue(self.unrelated.exists())

    def test_waits_for_update_lock_before_removing_files(self):
        with (self.state / "update.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            process = subprocess.Popen(["bash", str(self.script)], env=self.env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                time.sleep(0.15)
                self.assertIsNone(process.poll())
                self.assertTrue(all(p.exists() for p in self.files))
                fcntl.flock(lock, fcntl.LOCK_UN)
                _, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, stderr)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

    def test_refuses_symbolic_lock_without_removing_files(self):
        (self.state / "install.lock").symlink_to(self.unrelated)
        result = self.run_uninstall()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(all(p.exists() for p in self.files))
        self.assertEqual(self.unrelated.read_text(), "autre outil")
