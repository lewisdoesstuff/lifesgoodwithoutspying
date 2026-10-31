"""Verify unsupported purge selections without touching system state."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class PurgeControl(unittest.TestCase):
    def test_saved_selection_can_be_cleared_but_not_enabled(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            init = base / 'init'
            init.mkdir()
            for name in ('nospy-ctl.sh', 'nospy-lib.sh'):
                text = (ROOT / 'app/init' / name).read_text()
                text = text.replace('/var/lib/webosbrew', str(base / 'state'))
                text = text.replace('/tmp/lifesgoodwithoutspying', str(base / 'scratch'))
                (init / name).write_text(text)
            (init / 'nospy-apply.sh').write_text('#!/bin/sh\nexit 0\n')
            state = base / 'state'
            state.mkdir()
            conf = state / 'lifesgoodwithoutspying.conf'
            conf.write_text('purge.boot=on\n')
            def run(value):
                return subprocess.run(['sh', str(init / 'nospy-ctl.sh'), 'set', 'purge.boot', value],
                                      capture_output=True, text=True, timeout=10)
            disabled = run('off')
            self.assertEqual(disabled.returncode, 0, disabled.stderr)
            self.assertEqual(conf.read_text(), 'purge.boot=off\n')
            rejected = run('on')
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn('Purge unavailable', rejected.stderr)
            self.assertEqual(conf.read_text(), 'purge.boot=off\n')

if __name__ == '__main__':
    unittest.main()
