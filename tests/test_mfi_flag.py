"""The AirPlay MFi key flag held while SDP is blocked (#66)."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


LIB = Path(__file__).resolve().parents[1] / "app/init/nospy-lib.sh"


class MfiFlagTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.flag = self.root / "mfi_key_requested"
        self.ours = self.flag / "lifesgoodwithoutspying"

    def sh(self, fn):
        return subprocess.run(
            [os.environ.get("TEST_SHELL", "sh"), "-c", '. "$LIB"\nMFI_FLAG="$F"\n' + fn],
            capture_output=True, text=True, env=dict(os.environ, LIB=str(LIB), F=str(self.flag)),
        ).returncode

    def test_hold_makes_a_directory_rm_cannot_remove(self):
        self.assertEqual(self.sh("mfi_flag_hold"), 0)
        self.assertTrue(self.ours.is_file())
        # What airplay and mfi do with the flag.
        self.assertNotEqual(subprocess.run(["rm", str(self.flag)], capture_output=True).returncode, 0)
        self.assertTrue(self.flag.is_dir())

    def test_hold_replaces_airplays_own_flag(self):
        self.flag.touch()
        self.assertEqual(self.sh("mfi_flag_hold"), 0)
        self.assertTrue(self.ours.is_file())

    def test_hold_twice_is_fine(self):
        self.sh("mfi_flag_hold")
        self.assertEqual(self.sh("mfi_flag_hold"), 0)
        self.assertTrue(self.ours.is_file())

    def test_hold_does_not_follow_a_symlink(self):
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        self.flag.symlink_to(elsewhere)
        self.assertNotEqual(self.sh("mfi_flag_hold"), 0)
        self.assertEqual(list(elsewhere.iterdir()), [])

    def test_release_removes_what_hold_made(self):
        self.sh("mfi_flag_hold")
        self.assertEqual(self.sh("mfi_flag_release"), 0)
        self.assertFalse(self.flag.exists())

    def test_release_keeps_a_directory_someone_else_also_keeps(self):
        self.flag.mkdir()
        (self.flag / "keep").mkdir()
        self.sh("mfi_flag_hold")
        self.sh("mfi_flag_release")
        self.assertEqual([p.name for p in self.flag.iterdir()], ["keep"])

    def test_release_leaves_a_flag_we_did_not_make(self):
        self.flag.touch()
        self.assertEqual(self.sh("mfi_flag_release"), 0)
        self.assertTrue(self.flag.is_file())
        self.flag.unlink()
        self.flag.mkdir()
        (self.flag / "keep").mkdir()
        self.sh("mfi_flag_release")
        self.assertTrue((self.flag / "keep").is_dir())

    def test_release_with_no_flag_is_quiet(self):
        self.assertEqual(self.sh("mfi_flag_release"), 0)


if __name__ == "__main__":
    unittest.main()
