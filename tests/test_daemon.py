import importlib.util
from pathlib import Path
import types
import unittest
from unittest.mock import MagicMock, patch


ROOT = Path(__file__).resolve().parents[1]


class DaemonTests(unittest.TestCase):
    def setUp(self):
        # Import without the macOS backend or writing a real user log.
        self.keyboard = MagicMock()
        pynput = types.ModuleType('pynput')
        pynput.keyboard = self.keyboard
        spec = importlib.util.spec_from_file_location('snap_it', ROOT / 'snap-it.py')
        self.daemon = importlib.util.module_from_spec(spec)
        with patch.dict('sys.modules', pynput=pynput), patch('logging.basicConfig'):
            spec.loader.exec_module(self.daemon)

    def test_startup_registers_f11_and_joins_listener(self):
        with patch.object(self.daemon.signal, 'signal'), patch.object(self.daemon, 'log') as log:
            self.daemon.main()
        self.keyboard.GlobalHotKeys.assert_called_once_with({'<f11>': self.daemon.on_hotkey})
        self.keyboard.GlobalHotKeys.return_value.__enter__.return_value.join.assert_called_once()
        self.assertIn('snap-it starting', log.info.call_args_list[0].args[0])

    def test_capture_cancellation_does_not_copy_or_open(self):
        with patch.object(self.daemon, 'build_filepath', return_value='/tmp/shot.png'), \
                patch.object(self.daemon.subprocess, 'run', return_value=types.SimpleNamespace(returncode=1)), \
                patch.object(self.daemon, 'copy_to_clipboard') as copy, \
                patch.object(self.daemon.subprocess, 'Popen') as preview, \
                patch.object(self.daemon, 'notify') as notify:
            self.daemon.take_screenshot()
        copy.assert_not_called()
        preview.assert_not_called()
        notify.assert_not_called()

    def test_successful_capture_copies_and_opens_preview(self):
        path = '/tmp/shot.png'
        with patch.object(self.daemon, 'build_filepath', return_value=path), \
                patch.object(self.daemon.subprocess, 'run', return_value=types.SimpleNamespace(returncode=0)), \
                patch.object(self.daemon.os.path, 'exists', return_value=True), \
                patch.object(self.daemon, 'copy_to_clipboard') as copy, \
                patch.object(self.daemon.subprocess, 'Popen') as preview, \
                patch.object(self.daemon, 'notify') as notify:
            self.daemon.take_screenshot()
        copy.assert_called_once_with(path)
        preview.assert_called_once_with(['open', '-a', 'Preview', path])
        notify.assert_called_once_with('Saved shot.png')

    def test_notification_uses_new_name(self):
        with patch.object(self.daemon.subprocess, 'run') as run:
            self.daemon.notify('Saved shot.png')
        self.assertIn('with title "snap-it"', run.call_args.args[0][-1])


if __name__ == '__main__':
    unittest.main()
