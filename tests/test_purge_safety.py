import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / 'app/init/nospy-lib.sh'

class PurgeSafetyTest(unittest.TestCase):
    def test_default_off_and_purge_refuses_without_file_operations(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            calls = directory / 'calls'
            for tool in ('find', 'rm'):
                command = directory / tool
                command.write_text('#!/bin/sh\necho called >> "$PURGE_TEST_CALLS"\nexit 99\n')
                command.chmod(0o755)
            env = dict(os.environ, PATH=tmp + ':' + os.environ['PATH'], PURGE_TEST_CALLS=str(calls))
            result = subprocess.run(['sh', '-c', '. "$1"; conf_default purge.boot; purge_residue', 'sh', str(LIB)], env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertTrue(result.stdout.startswith('off\n'))
            self.assertIn('Purge unavailable', result.stdout)
            self.assertFalse(calls.exists(), 'purge invoked a filesystem traversal or removal')

if __name__ == '__main__':
    unittest.main()
