"""Apps that keep voiceinput: what stays stubbed, who counts as a keeper, and
that a stand-in only steps aside for a live claim."""
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


def sh(script, conf="", keep=None, installed=(APP,), **env):
    """Run script after sourcing the library, with keep {app id: file text}
    registered and the apps in installed present."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "conf").write_text(conf, encoding="utf-8")
        (root / "keep.d").mkdir()
        for app, text in (keep or {}).items():
            (root / "keep.d" / app).write_text(text, encoding="utf-8")
        for app in installed:
            (root / "apps" / app).mkdir(parents=True)
            (root / "apps" / app / "appinfo.json").write_text(
                '{\n  "id": "%s",\n  "title": "Recogniser"\n}\n' % app, encoding="utf-8")
        t = tmp.replace("\\", "/")
        out = subprocess.run(
            [SHELL, "-c", '. "$LIB"\nCONF="$T/conf"\nKEEP_DIR="$T/keep.d"\nKEEP_APP_DIRS="$T/none $T/apps"\n'
             'ANSWER_CLAIM_PREFIX="$T/claim"\n' + script],
            env=dict(os.environ, LIB=str(LIB), T=t, **env), capture_output=True, text=True)
    return out


def names(conf="", keep=None, **kw):
    out = sh("voice_execs", conf, keep, **kw).stdout.split()
    return {path.rsplit("/", 1)[1] for path in out}


KEPT = {APP: "voiceinput\n"}


class KeepersTest(unittest.TestCase):
    def test_nothing_registered(self):
        self.assertIn("voiceinput", names())
        self.assertEqual(sh("voice_units").stdout.split(), ["voiceinput.service", "voiceconductor.service"])
        self.assertNotEqual(sh("voice_mic_kept").returncode, 0)

    def test_a_registered_app_keeps_only_voiceinput(self):
        kept = names(keep=KEPT)
        self.assertNotIn("voiceinput", kept)
        for name in STAYS_STUBBED:
            self.assertIn(name, kept)
        self.assertEqual(sh("voice_units", keep=KEPT).stdout.split(), ["voiceconductor.service"])

    def test_names_the_app(self):
        self.assertEqual(sh("keepers voiceinput", keep=KEPT).stdout.split(), [APP])
        self.assertEqual(sh("keeper_titles voiceinput", keep=KEPT).stdout.strip(), "Recogniser")

    def test_an_uninstalled_app_keeps_nothing(self):
        self.assertIn("voiceinput", names(keep=KEPT, installed=()))
        self.assertEqual(sh("keepers voiceinput", keep=KEPT, installed=()).stdout, "")

    def test_only_keepable_names_count(self):
        keep = {APP: "voiceconductor\nnlpmanager\n"}
        self.assertEqual(names(keep=keep), names())
        self.assertEqual(sh("keepers voiceconductor", keep=keep).stdout, "")

    def test_whole_lines_only(self):
        self.assertIn("voiceinput", names(keep={APP: "voiceinput_sound\n# voiceinput\n"}))

    def test_bad_file_names_are_ignored(self):
        for bad in (".hidden", "a b"):
            self.assertEqual(sh("keepers voiceinput", keep={bad: "voiceinput\n"}, installed=(bad,)).stdout, "", bad)

    def test_does_nothing_while_voice_is_off(self):
        conf = "voice.stop=off\n"
        self.assertNotEqual(sh("voice_mic_kept", conf, KEPT).returncode, 0)

    def test_the_old_setting_is_gone(self):
        self.assertNotIn("voice.keep_mic", sh("conf_keys").stdout.split())

    def test_status_does_not_count_a_kept_voiceinput_as_a_fault(self):
        out = sh("group_targets voice", keep=KEPT).stdout
        self.assertNotIn("voiceinput /usr/sbin/voiceinput\n", out)
        # Once the app no longer registers, a voiceinput left running shows.
        self.assertIn("voiceinput /usr/sbin/voiceinput\n", sh("group_targets voice").stdout)


class ClaimTest(unittest.TestCase):
    CHECK = 'echo "$PID_TEXT" > "$T/claim.svc"; answer_claimed svc'

    def test_no_claim(self):
        self.assertNotEqual(sh("answer_claimed svc").returncode, 0)

    def test_live_pid(self):
        self.assertEqual(sh(self.CHECK.replace("$PID_TEXT", "$$")).returncode, 0)

    def test_dead_pid(self):
        self.assertNotEqual(sh(self.CHECK, PID_TEXT="999999999").returncode, 0)

    def test_junk(self):
        for text in ("", "self", "1;2", "../1"):
            self.assertNotEqual(sh(self.CHECK, PID_TEXT=text).returncode, 0, text)


if __name__ == "__main__":
    unittest.main()
