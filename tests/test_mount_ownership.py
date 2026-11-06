"""Check that stub binds don't stack and that only our own mounts come off."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


LIB = Path(__file__).resolve().parents[1] / "app/init/nospy-lib.sh"

# Mount IDs, parent, dev, root, mount point, ... as /proc/self/mountinfo has it.
MOUNTINFO = """\
22 1 253:1 / / ro,relatime shared:1 - squashfs /dev/root ro
90 59 179:59 /var/lib/webosbrew/lifesgoodwithoutspying.stub /usr/sbin/performer rw shared:39 - ext4 /dev/mmcblk0p59 rw
91 59 179:59 /var/lib/webosbrew/other.stub /usr/sbin/acr2 rw shared:39 - ext4 /dev/mmcblk0p59 rw
92 59 179:59 /var/lib/webosbrew/lifesgoodwithoutspying.stub /usr/sbin/nudge rw shared:39 - ext4 /dev/mmcblk0p59 rw
93 92 179:59 /var/lib/webosbrew/other.stub /usr/sbin/nudge rw shared:39 - ext4 /dev/mmcblk0p59 rw
"""


def sh(script, **env):
    full = dict(os.environ, LIB=str(LIB), **env)
    return subprocess.run(
        [os.environ.get("TEST_SHELL", "sh"), "-c", '. "$LIB"\n' + script],
        env=full, capture_output=True, text=True,
    )


class MountIsOursTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.info = Path(self.tmp.name) / "mountinfo"
        self.info.write_text(MOUNTINFO, encoding="utf-8")

    def tearDown(self):
        self.tmp.cleanup()

    def ours(self, path, info=None):
        out = sh('MOUNTINFO="$M"; mount_is_ours "$P" /lifesgoodwithoutspying.stub',
                 M=info or str(self.info), P=path)
        return out.returncode == 0

    def test_our_bind(self):
        self.assertTrue(self.ours("/usr/sbin/performer"))

    def test_someone_elses_bind(self):
        self.assertFalse(self.ours("/usr/sbin/acr2"))

    def test_someone_else_on_top_of_ours(self):
        self.assertFalse(self.ours("/usr/sbin/nudge"))

    def test_nothing_mounted(self):
        # e.g. after a reboot, with the state file still listing the path
        self.assertFalse(self.ours("/usr/sbin/rdxd"))

    def test_unreadable_table_keeps_old_behaviour(self):
        self.assertTrue(self.ours("/usr/sbin/rdxd", info=self.tmp.name + "/missing"))

    def test_unreadable_table_is_not_shown(self):
        # stub_mount binds when it can't tell, as it did before the check
        out = sh('MOUNTINFO="$M"; mount_is_shown /usr/sbin/performer /lifesgoodwithoutspying.stub',
                 M=self.tmp.name + "/missing")
        self.assertNotEqual(out.returncode, 0)


# A fake umount that drops the last line for its mount point, as the kernel
# drops the topmost mount there.
UNSTACK = """
umount() {
    awk -v p="$1" '{ l[NR] = $0; if ($5 == p) last = NR }
        END { for (i = 1; i <= NR; i++) if (i != last) print l[i] }' "$MOUNTINFO" > "$MOUNTINFO.new"
    mv "$MOUNTINFO.new" "$MOUNTINFO"
}
unbind_ours "$P" /lifesgoodwithoutspying.stub
awk -v p="$P" '$5 == p { print $4 }' "$MOUNTINFO"
"""

STUB = "/var/lib/webosbrew/lifesgoodwithoutspying.stub"
OTHER = "/var/lib/webosbrew/other.stub"


class UnbindOursTest(unittest.TestCase):
    def unstack(self, roots):
        with tempfile.TemporaryDirectory() as tmp:
            info = Path(tmp) / "mountinfo"
            info.write_text("".join(
                f"{100 + i} 59 179:59 {root} /usr/sbin/x rw shared:39 - ext4 /dev/mmcblk0p59 rw\n"
                for i, root in enumerate(roots)), encoding="utf-8")
            out = sh('MOUNTINFO="$M"' + UNSTACK, M=str(info), P="/usr/sbin/x")
            self.assertEqual(out.returncode, 0, out.stderr)
            return out.stdout.split()

    def test_removes_a_stack_of_ours(self):
        self.assertEqual(self.unstack([STUB, STUB, STUB]), [])

    def test_stops_at_a_mount_that_is_not_ours(self):
        self.assertEqual(self.unstack([OTHER, STUB, STUB]), [OTHER])

    def test_leaves_someone_elses_bind_on_top(self):
        self.assertEqual(self.unstack([STUB, OTHER]), [STUB, OTHER])


# A fake mount that adds a line for its target, as the kernel adds a mount on
# top of whatever is there.
BIND = """
mount() {
    echo "200 59 179:59 /var/lib/webosbrew/${2##*/} $3 rw shared:39 - ext4 /dev/mmcblk0p59 rw" >> "$MOUNTINFO"
}
STUB_FILE=/var/lib/webosbrew/lifesgoodwithoutspying.stub
STUB_STATE="$T/stubbed"
stub_mount ads.stop "$P"
echo "rc=$?"
awk -v p="$P" '$5 == p' "$MOUNTINFO" | wc -l
cat "$STUB_STATE"
"""


class StubMountTest(unittest.TestCase):
    def bind(self, info_text, info_name="mountinfo"):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "performer"
            target.write_text("", encoding="utf-8")
            info = Path(tmp) / "mountinfo"
            info.write_text(info_text.replace("@P@", str(target)), encoding="utf-8")
            out = sh('MOUNTINFO="$T/' + info_name + '"' + BIND,
                     T=tmp, P=str(target))
            self.assertEqual(out.returncode, 0, out.stderr)
            rc, count, state = out.stdout.splitlines()
            return rc, int(count.strip()), state.replace(str(target), "@P@")

    def test_binds_a_fresh_path(self):
        self.assertEqual(self.bind(""), ("rc=0", 1, "ads.stop @P@"))

    def test_only_records_a_path_that_shows_our_stub(self):
        # e.g. a jail path that got the host bind through a shared /usr
        shown = ("90 59 179:59 /var/lib/webosbrew/lifesgoodwithoutspying.stub @P@ "
                 "rw shared:39 - ext4 /dev/mmcblk0p59 rw\n")
        self.assertEqual(self.bind(shown), ("rc=2", 1, "ads.stop @P@"))

    def test_binds_over_someone_elses_mount(self):
        other = ("90 59 179:59 /var/lib/webosbrew/other.stub @P@ "
                 "rw shared:39 - ext4 /dev/mmcblk0p59 rw\n")
        self.assertEqual(self.bind(other), ("rc=0", 2, "ads.stop @P@"))


if __name__ == "__main__":
    unittest.main()
