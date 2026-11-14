"""jail_hosts_sync copies the live hosts table into each app jail (#68) without
following anything the app could have put in its jail's etc."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


LIB = Path(__file__).resolve().parents[1] / "app/init/nospy-lib.sh"

LIVE = "127.0.0.1 localhost\n0.0.0.0 ad.lgsmartad.com\n:: ad.lgsmartad.com\n"
OLD = "127.0.0.1 localhost\n"


class JailHostsTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.jails = self.root / "jail"
        self.jails.mkdir()
        self.live = self.root / "hosts"
        self.live.write_text(LIVE, encoding="utf-8")
        self.outside = self.root / "outside"
        self.outside.mkdir()

    def jail(self, name, hosts=OLD):
        etc = self.jails / name / "etc"
        etc.mkdir(parents=True)
        if hosts is not None:
            (etc / "hosts").write_text(hosts, encoding="utf-8")
        return etc

    def sync(self, root=None):
        script = '. "$LIB"\nJAIL_ROOT="$J"\nJAIL_HOSTS_SRC="$S"\njail_hosts_sync\n'
        result = subprocess.run(
            [os.environ.get("TEST_SHELL", "sh"), "-c", script], capture_output=True, text=True,
            env=dict(os.environ, LIB=str(LIB), J=str(root or self.jails), S=str(self.live)),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return int(result.stdout.strip())

    def leftovers(self):
        return sorted(str(p) for p in self.root.rglob(".hosts.*"))

    def test_stale_copies_get_the_live_table(self):
        a = self.jail("amazon")
        b = self.jail("lg.thinqai.adapter", hosts=LIVE)
        self.assertEqual(self.sync(), 2)
        for etc in (a, b):
            self.assertEqual((etc / "hosts").read_text(encoding="utf-8"), LIVE)
            self.assertEqual((etc / "hosts").stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.leftovers(), [])

    def test_the_copy_follows_the_live_table_back(self):
        etc = self.jail("netflix", hosts=LIVE)
        self.live.write_text(OLD, encoding="utf-8")
        self.sync()
        self.assertEqual((etc / "hosts").read_text(encoding="utf-8"), OLD)

    def test_a_jail_without_a_copy_gets_none(self):
        etc = self.jail("com.webos.app.browser", hosts=None)
        self.assertEqual(self.sync(), 0)
        self.assertFalse((etc / "hosts").exists())

    def test_a_symlinked_copy_is_not_written_through(self):
        target = self.outside / "shadow"
        target.write_text("secret\n", encoding="utf-8")
        etc = self.jail("evil", hosts=None)
        (etc / "hosts").symlink_to(target)
        self.assertEqual(self.sync(), 0)
        self.assertEqual(target.read_text(encoding="utf-8"), "secret\n")
        self.assertTrue((etc / "hosts").is_symlink())

    def test_a_symlinked_etc_is_skipped(self):
        (self.outside / "hosts").write_text("theirs\n", encoding="utf-8")
        (self.jails / "evil").mkdir()
        (self.jails / "evil" / "etc").symlink_to(self.outside)
        self.assertEqual(self.sync(), 0)
        self.assertEqual((self.outside / "hosts").read_text(encoding="utf-8"), "theirs\n")
        self.assertEqual(self.leftovers(), [])

    def test_a_symlinked_jail_is_skipped(self):
        (self.outside / "etc").mkdir()
        (self.outside / "etc" / "hosts").write_text("theirs\n", encoding="utf-8")
        (self.jails / "evil").symlink_to(self.outside)
        self.assertEqual(self.sync(), 0)
        self.assertEqual((self.outside / "etc" / "hosts").read_text(encoding="utf-8"), "theirs\n")

    def test_a_directory_named_hosts_is_left_alone(self):
        etc = self.jail("odd", hosts=None)
        (etc / "hosts").mkdir()
        self.assertEqual(self.sync(), 0)
        self.assertEqual(list((etc / "hosts").iterdir()), [])

    def test_no_jail_root_is_nothing_to_do(self):
        self.assertEqual(self.sync(root=self.root / "missing"), 0)


if __name__ == "__main__":
    unittest.main()
