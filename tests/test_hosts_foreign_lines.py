"""hosts_foreign_lines keeps what another tool wrote into our sink (#78)."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


LIB = Path(__file__).resolve().parents[1] / "app/init/nospy-lib.sh"
MARKER = "# lifesgoodwithoutspying - blocked LG ad/ACR/telemetry endpoints"

UNDERNEATH = "127.0.0.1 localhost\n::1 localhost\n"
OURS = (
    "\n%s generation 1-1\n"
    "0.0.0.0 ads.example\n:: ads.example\n"
    "0.0.0.0 acr.example\n:: acr.example\n" % MARKER
)
SDP = "\n%s SDP clock-sync grace period complete\n0.0.0.0 sdp.example\n:: sdp.example\n" % MARKER
BLOCKER = "# LG App Update Blocker\n0.0.0.0 apps.example\n0.0.0.0 ads.example\n"


class ForeignLinesTest(unittest.TestCase):
    def foreign(self, sink):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            lists = root / "blocklist.d"
            lists.mkdir()
            (lists / "10-ads.txt").write_text("# Ads\nads.example\nacr.example\n", encoding="utf-8")
            (lists / "45-sdp.txt").write_text("# SDP\nsdp.example  \n", encoding="utf-8")
            (root / "sink").write_text(sink, encoding="utf-8")
            out = subprocess.run(
                [os.environ.get("TEST_SHELL", "sh"), "-c", '. "$LIB"; hosts_foreign_lines "$S" "$B"'],
                env=dict(os.environ, LIB=str(LIB), S=str(root / "sink"), B=str(lists)),
                capture_output=True, text=True, check=True,
            )
            return out.stdout

    def test_only_ours(self):
        self.assertEqual(self.foreign(UNDERNEATH + OURS + SDP), "")

    def test_lines_appended_after_our_block(self):
        self.assertEqual(self.foreign(UNDERNEATH + OURS + BLOCKER), BLOCKER)

    def test_lines_between_our_blocks(self):
        # Another tool appended before the SDP grace period ran out.
        self.assertEqual(self.foreign(UNDERNEATH + OURS + BLOCKER + SDP), BLOCKER + "\n")

    def test_headerless_lines(self):
        self.assertEqual(self.foreign(UNDERNEATH + OURS + "0.0.0.0 apps.example\n"),
                         "0.0.0.0 apps.example\n")

    def test_the_file_underneath_is_left_out(self):
        self.assertEqual(self.foreign(UNDERNEATH + "0.0.0.0 apps.example\n" + OURS), "")

    def test_no_sink(self):
        self.assertEqual(self.foreign(UNDERNEATH), "")


if __name__ == "__main__":
    unittest.main()
