"""Without iptables NAT the DNS filter can't work: set refuses it, and the
status model tells the UI to hide it."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CTL = ROOT / "app/init/nospy-ctl.sh"
STATUS_JS = ROOT / "app/status.js"

RUNNER = r"""
const fs = require('fs');
global.window = {};
eval(fs.readFileSync(process.argv[1], 'utf8'));
const map = JSON.parse(process.argv[2]);
console.log(JSON.stringify(!!window.nospyStatus.read(map).dnsUnsupported));
"""


def ctl_set(key, iptables_rc):
    """Run "nospy-ctl.sh set <key> on" with an iptables that exits iptables_rc."""
    with tempfile.TemporaryDirectory() as tmp:
        fake = Path(tmp) / "iptables"
        fake.write_text("#!/bin/sh\nexit %d\n" % iptables_rc, encoding="utf-8")
        fake.chmod(0o755)
        env = dict(os.environ, PATH=tmp + os.pathsep + os.environ.get("PATH", ""))
        return subprocess.run(
            [os.environ.get("TEST_SHELL", "sh"), str(CTL), "set", key, "on"],
            env=env, capture_output=True, text=True,
        )


class SetRefusedWithoutNatTest(unittest.TestCase):
    def test_refuses_both_dns_keys(self):
        for key in ("dns.filter", "dns.disable_ipv6"):
            with self.subTest(key=key):
                out = ctl_set(key, iptables_rc=3)
                self.assertEqual(out.returncode, 3, out.stderr)
                self.assertIn("needs iptables NAT", out.stderr)


@unittest.skipIf(shutil.which("node") is None, "node is not installed")
class StatusModelTest(unittest.TestCase):
    def unsupported(self, lines):
        out = subprocess.run(["node", "-e", RUNNER, str(STATUS_JS), json.dumps(lines)],
                             capture_output=True, text=True, check=True).stdout
        return json.loads(out)

    def test_hidden_only_when_status_says_no(self):
        self.assertTrue(self.unsupported({"dns_filter_supported": "no"}))
        self.assertFalse(self.unsupported({"dns_filter_supported": "yes"}))
        # older init scripts don't print the line: keep showing the filter
        self.assertFalse(self.unsupported({}))


if __name__ == "__main__":
    unittest.main()
