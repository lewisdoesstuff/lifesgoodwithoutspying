"""Check status.js, which decides what the UI says, against fixture status."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest


STATUS_JS = Path(__file__).resolve().parents[1] / "app/status.js"

# Loads status.js with a stand-in window, reads one status fixture and prints
# what the UI would show.
RUNNER = r"""
const fs = require('fs');
global.window = {};
eval(fs.readFileSync(process.argv[1], 'utf8'));
const S = window.nospyStatus;
const lines = JSON.parse(process.argv[2]);
const map = {};
lines.forEach(l => { const i = l.indexOf('='); map[l.slice(0, i)] = l.slice(i + 1); });
const m = S.read(map);
const hero = S.hero(m, true, false, 30);
console.log(JSON.stringify({
  verdict: hero.verdict, why: hero.why || null, params: hero.params || null,
  dirty: Object.keys(m.dirty).filter(k => m.dirty[k]), saved: Object.keys(m.saved),
  groups: m.groups.map(g => [g.id, g.label, g.procs.map(p => p.name + ':' + p.pip).join(' '),
                            S.groupLine(g).key]),
  ipv6: S.cell(m, 'dns.disable_ipv6', 30), sdp: S.cell(m, 'domains.sdp', 30),
  main: S.mainAction(m).command, fault: S.serviceFault(m), exceptions: m.exceptions
}));
"""

BASE = [
    "autostart=on", "changes=none", "job=done", "hosts=ours", "blocklist=392", "dns_filter=yes",
    "saved.domains.sdp=on", "saved.dns.filter=on", "saved.dns.disable_ipv6=on", "saved.voice.stop=on", "saved.ads.stop=off",
    "applied.domains.sdp=on", "applied.dns.filter=on", "applied.dns.disable_ipv6=on",
    "applied.voice.stop=on", "applied.ads.stop=off",
    "proc.voice.voiceinput=stopped", "proc.voice.performer=absent",
    "proc.ads.acr2=running", "proc.extra.thing=stopped",
    "voice=stopped", "ads=running", "extra=stopped", "proc_scan=ok",
    # Bare on/off lines that aren't settings, as status prints them.
    "autostart=on", "connman_ipv6=off", "voice.stop=on",
]


def model(lines):
    out = subprocess.run(["node", "-e", RUNNER, str(STATUS_JS), json.dumps(lines)],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def edit(**changes):
    keys = {k.replace("__", "."): v for k, v in changes.items()}
    lines = [l for l in BASE if l.split("=")[0] not in keys]
    return lines + ["%s=%s" % kv for kv in keys.items()]


@unittest.skipIf(shutil.which("node") is None, "node is not installed")
class StatusModelTest(unittest.TestCase):
    def test_protected(self):
        m = model(BASE)
        self.assertEqual(m["verdict"], "verdict.protected")
        self.assertEqual(m["main"], "disable")
        # Absent processes are dropped; a group that is off is idle, not a
        # fault, so its running acr2 doesn't count; an unknown group keeps
        # its id as the label.
        self.assertEqual(m["groups"], [
            ["voice", "group.voice", "voiceinput:stopped", "state.stopped"],
            ["ads", "group.ads", "acr2:idle", "state.off"],
            ["extra", "extra", "thing:stopped", "state.stopped"],
        ])
        self.assertEqual(m["fault"], "")
        self.assertEqual(m["ipv6"], {"cls": "on", "key": "cell.ipv6Off"})
        # Only saved.<key> lines are settings.
        self.assertNotIn("connman_ipv6", m["saved"])

    def test_kept_process(self):
        # An app registered to keep voiceinput: still protected, and named.
        lines = [l for l in BASE if not l.startswith("proc.voice.voiceinput")]
        m = model(lines + ["kept.voice.voiceinput=Local Voice"])
        self.assertEqual(m["verdict"], "verdict.protected")
        self.assertEqual(m["groups"][0][2], "voiceinput:kept")
        self.assertEqual(m["groups"][0][3], "state.stopped")

    def test_claimed_process(self):
        # LG's voiceconductor stays stubbed while an app answers for it: its own
        # dot turns blue and names the app, and it's still protected.
        m = model(BASE + ["proc.voice.voiceconductor=stopped", "claimed.voice.voiceconductor=Local Voice"])
        self.assertEqual(m["verdict"], "verdict.protected")
        self.assertEqual(m["groups"][0][2], "voiceinput:stopped voiceconductor:kept")

    def test_exceptions(self):
        keep = "exception.com.example.app:keep:voiceinput"
        claim = "exception.com.example.app:claim:com.webos.service.voiceconductor"
        m = model(BASE + ["saved.%s=on" % keep, "applied.%s=on" % keep, "saved.%s=on" % claim,
                          "applied.%s=off" % claim, "exception_app.%s=Example" % keep,
                          "exception_app.%s=Example" % claim, "exception_in_use.%s=yes" % keep])
        self.assertEqual(m["exceptions"], [
            {"key": keep, "app": "com.example.app", "title": "Example", "kind": "keep",
             "name": "voiceinput", "inUse": True},
            {"key": claim, "app": "com.example.app", "title": "Example", "kind": "claim",
             "name": "com.webos.service.voiceconductor", "inUse": False},
        ])
        # Turning one on is a change to apply, like any other setting.
        self.assertEqual(m["dirty"], [claim])
        self.assertEqual(m["main"], "apply")

    def test_running_listed_process_wins(self):
        m = model(edit(saved__ads__stop="on", applied__ads__stop="on"))
        self.assertEqual((m["verdict"], m["why"]), ("verdict.partial", "why.running"))
        self.assertEqual(m["params"], {"names": ["acr2"]})
        self.assertEqual(m["fault"], "bad")

    def test_unknown_scan(self):
        m = model(edit(saved__ads__stop="on", applied__ads__stop="on", proc__ads__acr2="unknown"))
        self.assertEqual(m["verdict"], "verdict.unverified")
        self.assertEqual([g["id"] for g in m["params"]["groups"]], ["ads"])
        self.assertEqual(m["fault"], "warn")

    def test_dirty_comes_from_applied_lines(self):
        m = model(edit(saved__voice__stop="off", changes="pending"))
        self.assertEqual(m["verdict"], "verdict.pending")
        self.assertEqual(m["dirty"], ["voice.stop"])
        self.assertEqual(m["main"], "apply")
        self.assertEqual(m["groups"][0][3], "state.restartsOnApply")

    def test_local_set_is_seen(self):
        # app.js records a toggle it just saved as saved.<key> and re-reads;
        # a bare key line would be ignored.
        m = model(BASE + ["saved.domains.sdp=off"])
        self.assertEqual(m["dirty"], ["domains.sdp"])
        self.assertEqual(m["verdict"], "verdict.pending")

    def test_hosts_sink_not_ours(self):
        # A list is on but the hosts file isn't ours: not "Protected".
        m = model(edit(hosts="external"))
        self.assertEqual((m["verdict"], m["why"]), ("verdict.hostsDown", "why.hostsOther"))
        self.assertEqual(m["sdp"]["cls"], "warn")
        self.assertEqual(model(edit(hosts="open"))["why"], "why.hostsOff")
        # With every list off, an unmounted hosts file is expected.
        self.assertEqual(model(edit(hosts="open", saved__domains__sdp="off", applied__domains__sdp="off"))["verdict"],
                         "verdict.protected")

    def test_dns_warnings(self):
        self.assertEqual(model(edit(dns_filter="no"))["verdict"], "verdict.dnsDown")
        m = model(edit(saved__dns__disable_ipv6="off", applied__dns__disable_ipv6="off"))
        self.assertEqual(m["verdict"], "verdict.ipv4")
        self.assertEqual(m["ipv6"], {"cls": "warn", "key": "cell.ipv6On"})

    def test_sdp_grace(self):
        m = model(edit(hosts="waiting", hosts_wait="42"))
        self.assertEqual((m["verdict"], m["params"]), ("verdict.grace", {"seconds": 30}))
        self.assertEqual(m["sdp"], {"cls": "warn", "key": "cell.sdpWait", "params": {"seconds": 30}})

    def test_off(self):
        m = model(edit(autostart="off"))
        self.assertEqual((m["verdict"], m["main"], m["dirty"]), ("verdict.off", "enable", []))


if __name__ == "__main__":
    unittest.main()
