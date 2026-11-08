"""Without iptables NAT the DNS filter can't work: set refuses it, and the
status model tells the UI to hide it. Only a definite answer counts: a passing
iptables failure must not switch the filter off."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CTL = ROOT / "app/init/nospy-ctl.sh"
LIB = ROOT / "app/init/nospy-lib.sh"
STATUS_JS = ROOT / "app/status.js"

RUNNER = r"""
const fs = require('fs');
global.window = {};
eval(fs.readFileSync(process.argv[1], 'utf8'));
const map = JSON.parse(process.argv[2]);
console.log(JSON.stringify(!!window.nospyStatus.read(map).dnsUnsupported));
"""


# What iptables prints on an LG B5 (webOS 25), whose kernel has no ip_tables.
NO_NAT = ("iptables v1.8.7 (legacy): can't initialize iptables table `nat': "
          "Table does not exist (do you need to insmod?)")
# A passing failure: another process holds the xtables lock.
LOCKED = "Another app is currently holding the xtables lock. Perhaps you want to use the -w option?"


def fake_iptables(tmp, rc, stderr=""):
    # The message goes through a file: the B5's has a backtick, which a shell
    # echo would treat as a command substitution.
    msg = Path(tmp) / "iptables.stderr"
    msg.write_text(stderr + "\n" if stderr else "", encoding="utf-8")
    fake = Path(tmp) / "iptables"
    fake.write_text('#!/bin/sh\ncat "%s" >&2\nexit %d\n' % (msg, rc), encoding="utf-8")
    fake.chmod(0o755)
    return dict(os.environ, PATH=tmp + os.pathsep + os.environ.get("PATH", ""))


def ctl_set(key, rc, stderr):
    """Run "nospy-ctl.sh set <key> on" with a fake iptables."""
    with tempfile.TemporaryDirectory() as tmp:
        return subprocess.run(
            [os.environ.get("TEST_SHELL", "sh"), str(CTL), "set", key, "on"],
            env=fake_iptables(tmp, rc, stderr), capture_output=True, text=True,
        )


def lib(script, rc, stderr="", cache=None):
    """Run script after sourcing the library, with a fake iptables and cache."""
    with tempfile.TemporaryDirectory() as tmp:
        env = fake_iptables(tmp, rc, stderr)
        env["LIB"] = str(LIB)
        env["CACHE"] = str(Path(tmp) / "nat")
        if cache is not None:
            Path(env["CACHE"]).write_text(cache + "\n", encoding="utf-8")
        out = subprocess.run(
            [os.environ.get("TEST_SHELL", "sh"), "-c",
             '. "$LIB"; DNS_NAT_CACHE="$CACHE"; ' + script + '; echo "cache=$(cat "$CACHE" 2>/dev/null)"'],
            env=env, capture_output=True, text=True,
        )
        return out.stdout.split()


class SetRefusedWithoutNatTest(unittest.TestCase):
    def test_refuses_both_dns_keys(self):
        for key in ("dns.filter", "dns.disable_ipv6"):
            with self.subTest(key=key):
                out = ctl_set(key, 3, NO_NAT)
                self.assertEqual(out.returncode, 3, out.stderr)
                self.assertIn("needs iptables NAT", out.stderr)

    def test_a_passing_failure_is_not_refused(self):
        out = ctl_set("dns.filter", 4, LOCKED)
        self.assertNotIn("needs iptables NAT", out.stderr)
        self.assertNotEqual(out.returncode, 3)


class NatProbeTest(unittest.TestCase):
    def test_working_nat(self):
        self.assertEqual(lib("dns_filter_nat_check", 0), ["yes", "cache=yes"])

    def test_missing_nat_table(self):
        self.assertEqual(lib("dns_filter_nat_check", 3, NO_NAT), ["no", "cache=no"])

    def test_other_failures_are_unknown_and_not_cached(self):
        for rc, err in ((4, LOCKED), (137, "")):
            with self.subTest(rc=rc):
                self.assertEqual(lib("dns_filter_nat_check", rc, err), ["unknown", "cache="])

    def test_unknown_keeps_an_earlier_answer(self):
        self.assertEqual(lib("dns_filter_nat_check", 4, LOCKED, cache="yes"),
                         ["unknown", "cache=yes"])

    def test_status_reads_the_cache_without_probing(self):
        # the fake iptables would say no; the cached yes wins
        self.assertEqual(lib("dns_filter_nat", 3, NO_NAT, cache="yes"), ["yes", "cache=yes"])

    def test_status_probes_when_nothing_is_cached(self):
        self.assertEqual(lib("dns_filter_nat", 3, NO_NAT), ["no", "cache=no"])


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
