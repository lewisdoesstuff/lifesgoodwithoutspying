"""Run nospy-luna-stub.js against a fake palmbus, and its worker against a fake node."""
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
STUB = ROOT / "app/init/nospy-luna-stub.js"
LIB = ROOT / "app/init/nospy-lib.sh"
NODE = os.environ.get("TEST_NODE", "node")
SHELL = os.environ.get("TEST_SHELL", "sh")

ADMANAGER = "com.webos.service.admanager"
VOICECONDUCTOR = "com.webos.service.voiceconductor"
VOICEINPUT = "com.webos.service.voiceinput"

# Records the handles the stub opens, then sends each call in CALLS through
# every handle and prints what came back. ES5, like the stub, as CI runs this
# under the Node releases the TVs ship.
FAKE_PALMBUS = '''
if (process.env.HANDLE_ERROR) throw new Error(process.env.HANDLE_ERROR);
var handles = [];
function Handle(name, isPublic) {
    this.name = name; this.isPublic = isPublic; this.methods = []; this.listeners = [];
    handles.push(this);
}
Handle.prototype.registerMethod = function (c, m) { this.methods.push(c + ' ' + m); };
Handle.prototype.addListener = function (e, f) { this.listeners.push(f); };
exports.Handle = Handle;
setTimeout(function () {
    var out = handles.map(function (h) {
        var replies = {};
        JSON.parse(process.env.CALLS).forEach(function (call) {
            h.listeners[0]({
                category: function () { return call[0]; },
                method: function () { return call[1]; },
                respond: function (r) { replies[call[0] + ' ' + call[1]] = JSON.parse(r); }
            });
        });
        return { name: h.name, isPublic: h.isPublic, methods: h.methods, replies: replies };
    });
    console.log(JSON.stringify(out));
    process.exit(0);
}, 10);
'''


def run_stub(service, calls=(), **env):
    with tempfile.TemporaryDirectory() as tmp:
        Path(tmp, "palmbus.js").write_text(FAKE_PALMBUS, encoding="utf-8")
        return subprocess.run(
            [NODE, str(STUB), service], capture_output=True, text=True,
            env=dict(os.environ, NODE_PATH=tmp, CALLS=json.dumps(calls), **env),
        )


def replies(service, category, method):
    """The reply to one call, which must be the same on both buses."""
    handles = json.loads(run_stub(service, [[category, method]]).stdout)
    private, public = [h["replies"][f"{category} {method}"] for h in handles]
    assert private == public
    return private


@unittest.skipUnless(subprocess.run(["sh", "-c", f'command -v "{NODE}"'], capture_output=True).returncode == 0,
                     "needs node")
class AnswersTest(unittest.TestCase):
    def test_registers_on_both_buses(self):
        handles = json.loads(run_stub(ADMANAGER).stdout)
        self.assertEqual([h["isPublic"] for h in handles], [False, True])
        for handle in handles:
            self.assertEqual(handle["name"], ADMANAGER)
            self.assertEqual(handle["methods"], ["/ getAdid"])

    def test_ad_id_is_zero_and_tracking_limited(self):
        self.assertEqual(replies(ADMANAGER, "/", "getAdid"), {
            "returnValue": True,
            "IFA": "00000000-0000-0000-0000-000000000000",
            "IFAType": "wtaid",
            "LMT": "on",
            "DNS": "on",
            "parentalControl": "off",
            "offUsageTime": "off",
            "recommendPromotion": "off",
        })

    def test_voice_replies_have_the_fields_settings_reads(self):
        self.assertEqual(replies(VOICECONDUCTOR, "/", "getSupportedLanguages"),
                         {"returnValue": True, "voiceEngines": {}, "voiceLanguages": {}})
        self.assertEqual(replies(VOICECONDUCTOR, "/interactor", "register"),
                         {"returnValue": True, "subscribed": True})

    def test_voice_activation_answers_so_settings_menus_open(self):
        self.assertEqual(replies(VOICEINPUT, "/setting", "getActivation"),
                         {"returnValue": True, "subscribed": True})

    def test_other_calls_still_get_an_answer(self):
        self.assertFalse(replies(ADMANAGER, "/", "requestBannerInfo")["returnValue"])

    def test_unknown_service_is_refused(self):
        self.assertEqual(run_stub("com.example.other").returncode, 2)

    def test_failure_to_take_the_name_is_one_line(self):
        result = run_stub(ADMANAGER, HANDLE_ERROR="name in use")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.strip(), "Error: name in use")


WORKER = '''set -u
. "$LIB"
DIR="$ROOT"
STUB_STATE="$ROOT/stubbed"
ANSWER_PREFIX="$ROOT/answer"
ANSWER_RETRY_SECONDS=0
ANSWER_MAX_FAILURES=3
ANSWER_HEALTHY_SECONDS="${HEALTHY:-60}"
"$@"
'''

# A node that notes each start, then stays up, or exits if the "crash" file exists.
FAKE_NODE = '''#!/bin/sh
echo x >> "$ROOT/runs"
if [ -f "$ROOT/crash" ]; then
    echo "stack frame" >&2
    echo "Error: name in use" >&2
    exit 1
fi
while :; do sleep 0.1; done
'''


class WorkerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        fake = self.root / "bin/node"
        fake.parent.mkdir()
        fake.write_text(FAKE_NODE, encoding="utf-8")
        fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
        self.service = ADMANAGER
        self.pidfile = self.root / f"answer.{self.service}.pid"
        self.stubbed("ads.stop /usr/sbin/admanager")
        self.addCleanup(self.sh, "answer_stop", self.service)

    def stubbed(self, line):
        (self.root / "stubbed").write_text(line + "\n", encoding="utf-8")

    def crash(self):
        (self.root / "crash").touch()

    def sh(self, *args, check=True, **env):
        env = dict(os.environ, LIB=str(LIB), ROOT=str(self.root),
                   PATH=f"{self.root}/bin:{os.environ['PATH']}", **env)
        # stdout and stderr go to a file: the worker inherits them and outlives us.
        out = self.root / "out"
        with open(out, "a", encoding="utf-8") as stream:
            offset = stream.tell()
            subprocess.run([SHELL, "-c", WORKER, "sh", *args], env=env, stdout=stream, stderr=stream, check=check)
        with open(out, encoding="utf-8") as stream:
            stream.seek(offset)
            return stream.read()

    def running(self):
        return subprocess.run(
            [SHELL, "-c", WORKER, "sh", "answer_running", self.service],
            env=dict(os.environ, LIB=str(LIB), ROOT=str(self.root)),
        ).returncode == 0

    def runs(self):
        try:
            return len((self.root / "runs").read_text(encoding="utf-8").splitlines())
        except FileNotFoundError:
            return 0

    def stub_pids(self):
        """Pids of every process running our fake stub, whatever the pid file says."""
        pids = []
        for cmdline in Path("/proc").glob("[0-9]*/cmdline"):
            try:
                if f"{self.root}/nospy-luna-stub.js".encode() in cmdline.read_bytes():
                    pids.append(int(cmdline.parent.name))
            except OSError:
                pass
        return pids

    def wait_until(self, condition):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if condition():
                return True
            time.sleep(0.02)
        return False

    def test_refuses_a_service_that_is_not_stubbed(self):
        self.stubbed("ads.stop /usr/sbin/nudge")
        self.assertIn("not stubbed", self.sh("answer_start", self.service))
        self.assertFalse(self.running())
        self.assertEqual(self.runs(), 0)

    def test_start_then_stop(self):
        self.assertIn("answering for admanager", self.sh("answer_start", self.service))
        self.assertTrue(self.wait_until(self.running))
        self.sh("answer_stop", self.service)
        self.assertFalse(self.running())
        self.assertTrue(self.wait_until(lambda: not self.stub_pids()))
        self.assertEqual([p.name for p in self.root.glob("answer.*")], [])

    def test_restarts_a_stub_that_exits(self):
        self.sh("answer_start", self.service)
        self.assertTrue(self.wait_until(self.running))
        first = self.stub_pids()
        os.kill(first[0], 9)
        self.assertTrue(self.wait_until(lambda: self.stub_pids() and self.stub_pids() != first))
        self.assertEqual(self.runs(), 2)

    def test_gives_up_after_quick_failures_and_logs_why(self):
        self.crash()
        self.sh("answer_start", self.service)
        log = self.root / "out"
        self.assertTrue(self.wait_until(lambda: "gave up" in log.read_text(encoding="utf-8")))
        self.assertIn("[-] gave up answering for admanager: Error: name in use", log.read_text(encoding="utf-8"))
        self.assertEqual(self.runs(), 3)

    def test_a_long_enough_run_clears_the_failures(self):
        self.crash()
        self.sh("answer_start", self.service, HEALTHY="0")
        self.assertTrue(self.wait_until(lambda: self.runs() > 3))
        self.assertNotIn("gave up", (self.root / "out").read_text(encoding="utf-8"))

    def test_stop_ends_a_worker_that_is_restarting(self):
        self.crash()
        self.sh("answer_start", self.service, HEALTHY="0")
        self.assertTrue(self.wait_until(lambda: self.runs() > 0))
        self.sh("answer_stop", self.service)
        time.sleep(0.2)
        settled = self.runs()
        time.sleep(0.2)
        self.assertEqual(self.runs(), settled)

    def test_a_newer_start_replaces_the_older_worker(self):
        self.sh("answer_start", self.service)
        self.assertTrue(self.wait_until(self.running))
        older = self.stub_pids()
        self.sh("answer_stop", self.service)
        self.sh("answer_start", self.service)
        self.assertTrue(self.wait_until(lambda: self.stub_pids() and not set(self.stub_pids()) & set(older)))
        # The older worker saw the new token and left without starting another.
        time.sleep(0.3)
        self.assertEqual(len(self.stub_pids()), 1)
        self.assertEqual(self.runs(), 2)

    def test_stale_pid_file_does_not_kill_an_unrelated_process(self):
        other = subprocess.Popen(["sleep", "30"])
        self.addCleanup(other.wait)
        self.addCleanup(other.kill)
        self.pidfile.write_text(f"{other.pid}\n", encoding="utf-8")
        self.assertFalse(self.running())
        self.assertEqual(self.sh("answer_stop", self.service), "")
        self.assertIsNone(other.poll())

    def test_pid_of_a_finished_process_is_quiet(self):
        self.pidfile.write_text("999999999\n", encoding="utf-8")
        self.assertEqual(self.sh("answer_stop", self.service), "")

    def answered_by(self, exec_fn):
        execs = self.root / "execs"
        execs.write_text(self.sh(exec_fn), encoding="utf-8")
        return self.sh("answered_in", str(execs)).split()

    def test_each_toggle_covers_its_own_services(self):
        self.assertEqual(self.answered_by("ads_execs"), [ADMANAGER])
        self.assertEqual(self.answered_by("voice_execs"), [VOICECONDUCTOR, VOICEINPUT])
        self.assertEqual(self.answered_by("thinq_execs"), [])

    @unittest.skipUnless(subprocess.run(["sh", "-c", f'command -v "{NODE}"'], capture_output=True).returncode == 0,
                         "needs node")
    def test_the_stub_has_answers_for_every_service_the_worker_starts(self):
        services = self.sh("eval", "echo $ANSWERED_SERVICES").split()
        self.assertEqual(services, [ADMANAGER, VOICECONDUCTOR, VOICEINPUT])
        for service in services:
            self.assertEqual(run_stub(service).returncode, 0, service)


if __name__ == "__main__":
    unittest.main()
