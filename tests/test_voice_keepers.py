"""App exceptions: which registrations count, that each one is its own setting
and off until turned on and applied, what stays stubbed while voiceinput is
kept, and that a stand-in only steps aside for a claim from a live, allowed app."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "app/init/nospy-lib.sh"
SHELL = os.environ.get("TEST_SHELL", "sh")
STAYS_STUBBED = ["voiceconductor", "voiceclick", "nlpmanager", "performer", "voiceinput_network",
                 "voiceinput_preprocessor", "voiceinput_hidraw", "voiceinput_sound", "com.webos.app.voice"]
APP = "com.example.recogniser"
SERVICE = "com.webos.service.voiceconductor"
KEEP_KEY = "exception.%s:keep:voiceinput" % APP
CLAIM_KEY = "exception.%s:claim:%s" % (APP, SERVICE)
KEPT = {APP: "keep voiceinput\n"}
CLAIMED = {APP: "claim %s\n" % SERVICE}
# Exceptions are off until turned on and applied; most tests apply them on.
ON = "%s=on\n%s=on\n" % (KEEP_KEY, CLAIM_KEY)


def sh(script, applied=ON, exceptions=None, installed=(APP,), conf="", **env):
    """Run script after sourcing the library, with exceptions {app id: file
    text} registered, the apps in installed present, and the saved and applied
    settings given (applied=None: never applied)."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "conf").write_text(conf, encoding="utf-8")
        if applied is not None:
            (root / "applied").write_text(applied, encoding="utf-8")
        (root / "exceptions.d").mkdir()
        for app, text in (exceptions or {}).items():
            (root / "exceptions.d" / app).write_text(text, encoding="utf-8")
        for app in installed:
            (root / "apps" / app).mkdir(parents=True)
            (root / "apps" / app / "appinfo.json").write_text(
                '{\n  "id": "%s",\n  "title": "Recogniser"\n}\n' % app, encoding="utf-8")
        t = tmp.replace("\\", "/")
        out = subprocess.run(
            [SHELL, "-c", '. "$LIB"\nCONF="$T/conf"\nCONF_APPLIED="$T/applied"\nEXCEPT_DIR="$T/exceptions.d"\n'
             'EXCEPT_APP_DIR="$T/apps"\nANSWER_CLAIM_PREFIX="$T/claim"\n' + script],
            env=dict(os.environ, LIB=str(LIB), T=t, **env), capture_output=True, text=True)
    return out


def names(exceptions=None, **kw):
    out = sh("voice_execs", exceptions=exceptions, **kw).stdout.split()
    return {path.rsplit("/", 1)[1] for path in out}


class ExceptionsTest(unittest.TestCase):
    BOTH = {APP: "keep voiceinput\nclaim %s\n" % SERVICE}

    def test_entries(self):
        self.assertEqual(sh("exception_entries", exceptions=self.BOTH).stdout.splitlines(),
                         ["%s keep voiceinput" % APP, "%s claim %s" % (APP, SERVICE)])

    def test_each_entry_is_a_setting_and_off_by_default(self):
        keys = sh("conf_keys", exceptions=self.BOTH).stdout.split()
        self.assertIn(KEEP_KEY, keys)
        self.assertIn(CLAIM_KEY, keys)
        self.assertEqual(sh("conf_get " + KEEP_KEY).stdout.strip(), "off")
        # Nothing registered, no settings.
        self.assertFalse([k for k in sh("conf_keys").stdout.split() if k.startswith("exception.")])

    def test_only_keepable_and_answered_names_count(self):
        text = "keep voiceconductor\nkeep nlpmanager\nclaim com.webos.service.foo\nclaim voiceinput\n"
        self.assertEqual(sh("exception_entries", exceptions={APP: text}).stdout, "")

    def test_malformed_lines_are_ignored(self):
        text = "voiceinput\n# keep voiceinput\nkeep voiceinput extra\nkeep\nKEEP voiceinput\n"
        self.assertEqual(sh("exception_entries", exceptions={APP: text}).stdout, "")

    def test_last_line_needs_no_newline(self):
        self.assertEqual(sh("exception_entries", exceptions={APP: "keep voiceinput"}).stdout.split(),
                         [APP, "keep", "voiceinput"])

    def test_duplicates_count_once(self):
        out = sh("exception_entries", exceptions={APP: "keep voiceinput\n" * 2}).stdout
        self.assertEqual(len(out.splitlines()), 1)

    def test_an_uninstalled_app_has_none(self):
        self.assertEqual(sh("exception_entries", exceptions=KEPT, installed=()).stdout, "")

    def test_bad_file_names_are_ignored(self):
        for bad in (".hidden", "a b"):
            self.assertEqual(sh("exception_entries", exceptions={bad: "keep voiceinput\n"},
                                installed=(bad,)).stdout, "", bad)

    def test_only_homebrew_apps_count(self):
        out = subprocess.run([SHELL, "-c", '. "$LIB"; echo "$EXCEPT_APP_DIR"'],
                             env=dict(os.environ, LIB=str(LIB)), capture_output=True, text=True)
        self.assertEqual(out.stdout.split(), ["/media/developer/apps/usr/palm/applications"])


class KeepersTest(unittest.TestCase):
    def test_nothing_registered(self):
        self.assertIn("voiceinput", names())
        self.assertEqual(sh("voice_units").stdout.split(), ["voiceinput.service", "voiceconductor.service"])
        self.assertNotEqual(sh("voice_mic_kept").returncode, 0)

    def test_a_registered_app_keeps_only_voiceinput(self):
        kept = names(KEPT)
        self.assertNotIn("voiceinput", kept)
        for name in STAYS_STUBBED:
            self.assertIn(name, kept)
        self.assertEqual(sh("voice_units", exceptions=KEPT).stdout.split(), ["voiceconductor.service"])

    def test_names_the_app(self):
        self.assertEqual(sh("keepers voiceinput", exceptions=KEPT).stdout.split(), [APP])
        self.assertEqual(sh("keeper_titles voiceinput", exceptions=KEPT).stdout.strip(), "Recogniser")

    def test_an_uninstalled_app_keeps_nothing(self):
        self.assertIn("voiceinput", names(KEPT, installed=()))
        self.assertEqual(sh("keepers voiceinput", exceptions=KEPT, installed=()).stdout, "")

    def test_does_nothing_while_voice_is_off(self):
        self.assertNotEqual(sh("voice_mic_kept", exceptions=KEPT, conf="voice.stop=off\n").returncode, 0)

    def test_nothing_is_kept_until_turned_on_and_applied(self):
        # Never applied, applied off, applied without it, saved on but not applied.
        for applied, conf in ((None, ""), (KEEP_KEY + "=off\n", ""), ("", ""), ("", KEEP_KEY + "=on\n")):
            kw = dict(exceptions=KEPT, applied=applied, conf=conf)
            self.assertIn("voiceinput", names(**kw), applied)
            self.assertEqual(sh("keepers voiceinput", **kw).stdout, "", applied)
            self.assertNotEqual(sh("voice_mic_kept", **kw).returncode, 0, applied)
            self.assertEqual(sh("voice_units", **kw).stdout.split(),
                             ["voiceinput.service", "voiceconductor.service"], applied)

    def test_the_last_applied_line_wins(self):
        on_then_off = KEEP_KEY + "=on\n" + KEEP_KEY + "=off\n"
        off_then_on = KEEP_KEY + "=off\n" + KEEP_KEY + "=on\n"
        self.assertEqual(sh("keepers voiceinput", exceptions=KEPT, applied=on_then_off).stdout, "")
        self.assertEqual(sh("keepers voiceinput", exceptions=KEPT, applied=off_then_on).stdout.split(), [APP])

    def test_status_does_not_count_a_kept_voiceinput_as_a_fault(self):
        out = sh("group_targets voice", exceptions=KEPT).stdout
        self.assertNotIn("voiceinput /usr/sbin/voiceinput\n", out)
        # Once the app no longer registers, a voiceinput left running shows.
        self.assertIn("voiceinput /usr/sbin/voiceinput\n", sh("group_targets voice").stdout)


# A claimant: a process running from the app's folder, as an app's would.
CLAIMANT = ('mkdir -p "$T/apps/%s/bin"; echo "sleep 30" > "$T/apps/%s/bin/claimant"\n'
            'sh "$T/apps/%s/bin/claimant" & cpid=$!\n'
            'sleep 1\n' % (APP, APP, APP))


class ClaimTest(unittest.TestCase):
    def claim(self, text, **kw):
        kw.setdefault("exceptions", CLAIMED)
        script = (CLAIMANT + 'echo "%s" > "$T/claim.%s"\nanswer_claimed %s; r=$?\n'
                  'echo "$c_app"; kill $cpid; exit $r' % (text, SERVICE, SERVICE))
        return sh(script, **kw)

    def test_no_claim(self):
        self.assertNotEqual(sh("answer_claimed " + SERVICE, exceptions=CLAIMED).returncode, 0)

    def test_an_allowed_live_claim(self):
        out = self.claim("$cpid $(proc_start_time $cpid) " + APP)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), APP)

    def test_not_until_turned_on_and_applied(self):
        for applied, conf in ((None, ""), (CLAIM_KEY + "=off\n", ""), ("", CLAIM_KEY + "=on\n")):
            out = self.claim("$cpid $(proc_start_time $cpid) " + APP, applied=applied, conf=conf)
            self.assertNotEqual(out.returncode, 0, applied)

    def test_not_unless_registered(self):
        for exceptions in ({}, KEPT, {APP: "claim com.webos.service.voiceinput\n"}):
            out = self.claim("$cpid $(proc_start_time $cpid) " + APP, exceptions=exceptions)
            self.assertNotEqual(out.returncode, 0, exceptions)

    def test_a_reused_pid_fails(self):
        # Same pid, another start time: the claimant exited and the pid moved on.
        out = self.claim("$cpid $(($(proc_start_time $cpid) + 1)) " + APP)
        self.assertNotEqual(out.returncode, 0)

    def test_a_process_outside_the_app_fails(self):
        # The test's own shell doesn't run from the app's folder.
        out = self.claim("$$ $(proc_start_time $$) " + APP)
        self.assertNotEqual(out.returncode, 0)

    def test_another_apps_id_fails(self):
        other = "com.example.other"
        out = self.claim("$cpid $(proc_start_time $cpid) " + other,
                         exceptions=dict(CLAIMED, **{other: "claim %s\n" % SERVICE}),
                         installed=(APP, other),
                         applied=ON + "exception.%s:claim:%s=on\n" % (other, SERVICE))
        self.assertNotEqual(out.returncode, 0)

    def test_dead_pid(self):
        out = sh('echo "999999999 1 %s" > "$T/claim.%s"; answer_claimed %s' % (APP, SERVICE, SERVICE),
                 exceptions=CLAIMED)
        self.assertNotEqual(out.returncode, 0)

    def test_junk(self):
        for text in ("", "self", "1;2", "../1", "$cpid", "$cpid x " + APP,
                     "$cpid $(proc_start_time $cpid)",
                     "$cpid $(proc_start_time $cpid) ../" + APP,
                     "$cpid $(proc_start_time $cpid) %s extra" % APP):
            self.assertNotEqual(self.claim(text).returncode, 0, text)


if __name__ == "__main__":
    unittest.main()
