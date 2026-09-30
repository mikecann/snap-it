import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
LABEL = 'com.mikerosoft.snap-it'
LEGACY_LABEL = 'com.mikerosoft.mac-screenshot'


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        # Clones can contain spaces and XML-special characters.
        self.repo = self.base / 'my tools & screenshots'
        self.repo.mkdir()
        for script in ROOT.glob('*.sh'):
            shutil.copy2(script, self.repo / script.name)
        self.home = self.base / 'home'
        self.agents = self.home / 'Library/LaunchAgents'
        self.agents.mkdir(parents=True)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.calls = self.base / 'launchctl-calls'
        launchctl = self.bin / 'launchctl'
        launchctl.write_text('#!/bin/bash\nprintf "%s|%s\\n" "$1" "$2" >> "$TEST_CALLS"\n')
        launchctl.chmod(0o755)
        self.native_calls = self.base / 'native-calls'
        for name in ('pkill', 'nohup'):
            command = self.bin / name
            command.write_text(
                '#!/bin/bash\nprintf "%s\\n" "$0" "$@" >> "$TEST_NATIVE_CALLS"\n')
            command.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH=f'{self.bin}:{os.environ["PATH"]}',
                        TEST_CALLS=str(self.calls), TEST_NATIVE_CALLS=str(self.native_calls))

    def add_venv(self):
        python = self.repo / '.venv/bin/python3'
        python.parent.mkdir(parents=True)
        python.symlink_to(sys.executable)

    def run_script(self, name):
        return subprocess.run(['bash', str(self.repo / name)], cwd=self.base,
                              env=self.env, text=True, capture_output=True)

    def test_install_is_standalone_and_repeatable(self):
        self.add_venv()
        for _ in range(2):
            result = self.run_script('install-launchagent.sh')
            self.assertEqual(result.returncode, 0, result.stderr)
        path = self.agents / f'{LABEL}.plist'
        with path.open('rb') as file:
            plist = plistlib.load(file)
        self.assertEqual(plist['Label'], LABEL)
        self.assertEqual(plist['ProgramArguments'], [
            str(self.repo / '.venv/bin/python3'), str(self.repo / 'snap-it.py')])
        self.assertTrue(plist['RunAtLoad'])
        self.assertTrue(plist['KeepAlive'])
        self.assertEqual(plist['StandardErrorPath'], str(self.home / 'Library/Logs/snap-it.log'))
        self.assertTrue((self.home / 'Library/Logs').is_dir())
        self.assertEqual(self.calls.read_text().splitlines().count(f'load|{path}'), 2)

    def test_install_migrates_only_its_legacy_login_item(self):
        self.add_venv()
        legacy = self.agents / f'{LEGACY_LABEL}.plist'
        legacy.write_text('legacy')
        unrelated = self.agents / 'com.example.other.plist'
        unrelated.write_text('keep me')
        old_log = self.home / 'Library/Logs/mac-screenshot.log'
        old_log.parent.mkdir(parents=True)
        old_log.write_text('existing logs')
        result = self.run_script('install-launchagent.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(legacy.exists())
        self.assertEqual(unrelated.read_text(), 'keep me')
        self.assertEqual(old_log.read_text(), 'existing logs')
        calls = self.calls.read_text().splitlines()
        self.assertLess(calls.index(f'unload|{legacy}'),
                        calls.index(f'load|{self.agents / (LABEL + ".plist")}'))

    def test_missing_venv_does_not_remove_old_install(self):
        legacy = self.agents / f'{LEGACY_LABEL}.plist'
        legacy.write_text('legacy')
        result = self.run_script('install-launchagent.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('setup_mac.sh', result.stdout)
        self.assertTrue(legacy.exists())
        self.assertFalse(self.calls.exists())

    def test_uninstall_is_repeatable_and_keeps_other_tools(self):
        unrelated = self.agents / 'com.example.other.plist'
        unrelated.write_text('keep me')
        for label in (LABEL, LEGACY_LABEL):
            (self.agents / f'{label}.plist').write_text(label)
        for _ in range(2):
            result = self.run_script('uninstall-launchagent.sh')
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(self.agents.iterdir()), [unrelated])

    def test_restart_migrates_a_legacy_agent(self):
        self.add_venv()
        (self.agents / f'{LEGACY_LABEL}.plist').write_text('legacy')
        result = self.run_script('restart.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.agents / f'{LABEL}.plist').exists())
        self.assertFalse((self.agents / f'{LEGACY_LABEL}.plist').exists())

    def test_manual_restart_uses_this_clones_python_and_creates_log_directory(self):
        self.add_venv()
        result = self.run_script('restart.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.calls.exists())
        self.assertTrue((self.home / 'Library/Logs').is_dir())
        # nohup is launched asynchronously; wait for the stub, not a real daemon.
        deadline = time.monotonic() + 2
        expected = str(self.repo / 'snap-it.py')
        while time.monotonic() < deadline:
            calls = self.native_calls.read_text().splitlines()
            if expected in calls:
                break
            time.sleep(0.01)
        self.assertIn(str(self.repo / '.venv/bin/python3'), calls)
        self.assertIn(str(self.repo / 'snap-it.py'), calls)

    def test_root_install_runs_setup_then_login_install(self):
        for name, marker in [('setup_mac.sh', 'setup'),
                             ('install-launchagent.sh', 'login')]:
            (self.repo / name).write_text(
                f'#!/bin/bash\necho {marker} >> "$TEST_CALLS"\n')
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ['setup', 'login'])


if __name__ == '__main__':
    unittest.main()
