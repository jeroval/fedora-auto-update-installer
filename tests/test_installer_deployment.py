"""Vérifie le remplacement atomique et la restauration sans installer sur l'hôte."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallerDeploymentTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.stage = self.root / "stage"
        self.stage.mkdir()
        (self.stage / "backup").mkdir()
        installer = (ROOT / "install.sh").read_text()
        self.functions = installer[installer.index("atomic_put() {"):installer.index("trap finish_install EXIT")]
        self.header = """
set -Eeuo pipefail
STAGE=$1
USER_BUS=/nonexistent
DEPLOYED=()
COMMITTED=0
run_as_user() { "$@"; }
systemctl() { return 0; }
warn() { echo "$*" >&2; }
die() { echo "$*" >&2; exit 1; }
""" + self.functions + "\ntrap finish_install EXIT\n"

    def run_deployment(self, commands):
        return subprocess.run(
            ["bash", "-c", self.header + commands, "test", str(self.stage)],
            cwd=self.root, capture_output=True, text=True, timeout=10)

    def test_reinstallation_replaces_file_without_truncating_open_version(self):
        (self.root / "installed").write_text("ancienne version\n")
        (self.root / "new").write_text("nouvelle version\n")
        result = self.run_deployment("""
exec 7<installed
deploy new "$PWD/installed" 0755 system
cat <&7 > previously-open
COMMITTED=1
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "installed").read_text(), "nouvelle version\n")
        self.assertEqual((self.root / "previously-open").read_text(), "ancienne version\n")
        self.assertEqual((self.root / "installed").stat().st_mode & 0o777, 0o755)

    def test_failed_deployment_restores_previous_and_removes_new_files(self):
        (self.root / "installed").write_text("ancienne version\n")
        (self.root / "installed").chmod(0o640)
        (self.root / "new").write_text("nouvelle version\n")
        result = self.run_deployment("""
deploy new "$PWD/installed" 0755 system
deploy new "$PWD/user-file" 0644 user
exit 1
""")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual((self.root / "installed").read_text(), "ancienne version\n")
        self.assertEqual((self.root / "installed").stat().st_mode & 0o777, 0o640)
        self.assertFalse((self.root / "user-file").exists())

    def test_symbolic_destination_is_refused(self):
        (self.root / "victim").write_text("à conserver")
        (self.root / "installed").symlink_to(self.root / "victim")
        (self.root / "new").write_text("nouveau")
        result = self.run_deployment('deploy new "$PWD/installed" 0755 system\n')
        self.assertEqual(result.returncode, 1)
        self.assertEqual((self.root / "victim").read_text(), "à conserver")
