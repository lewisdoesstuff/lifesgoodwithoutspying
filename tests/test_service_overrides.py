"""Check which jailed .service files get overridden, and how."""
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


LIB = Path(__file__).resolve().parents[1] / "app/init/nospy-lib.sh"

SERVICES = {
    # started through the jailer, and a target: overridden
    "performer.service": """\
        [D-BUS Service]
        Name=com.webos.service.voice.performer.plugin
        Exec=/usr/bin/jailer -t native_mvpd -i com.webos.service.voice.performer -p /usr /usr/sbin/performer
        Type=dynamic
        """,
    # jailed, but not a target: left alone
    "dangbei.service": """\
        [D-BUS Service]
        Name=dangbei.adapter.plugin
        Exec=/usr/bin/jailer -t native_mvpd -i dangbei.adapter -p /usr /usr/sbin/dangbei-adapter
        Type=dynamic
        """,
    # a target, but started from the host path, which the stub already covers
    "voiceinput.service": """\
        [D-BUS Service]
        Name=com.webos.service.voiceinput
        Exec=/usr/sbin/voiceinput
        """,
    # a bare jailer on PATH
    "thinqai.service": """\
        [D-BUS Service]
        Name=lg.thinqai.adapter
        Exec=jailer -t native_mvpd -i lg.thinqai.adapter -p /usr /usr/sbin/lg.thinqai.adapter
        Type=dynamic
        """,
}

EXECS = [
    "/usr/sbin/performer",
    "/usr/sbin/voiceinput",
    "/usr/sbin/lg.thinqai.adapter",
    "/var/palm/jail/com.webos.service.voice.performer/usr/sbin/performer",
]

def sh(script, **env):
    full = dict(os.environ, LIB=str(LIB), **env)
    return subprocess.run(
        [os.environ.get("TEST_SHELL", "sh"), "-c", '. "$LIB"\n' + script],
        env=full, capture_output=True, text=True,
    )


class JailedServiceFilesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.dir = self.root / "services.d"
        self.dir.mkdir()
        for name, body in SERVICES.items():
            (self.dir / name).write_text(textwrap.dedent(body), encoding="utf-8")
        self.execs = self.root / "execs"
        self.execs.write_text("\n".join(EXECS) + "\n", encoding="utf-8")

    def tearDown(self):
        self.tmp.cleanup()

    def test_only_jailed_targets(self):
        out = sh('LUNA_SERVICE_DIR="$D"; jailed_service_files "$E"',
                 D=str(self.dir), E=str(self.execs))
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(sorted(Path(p).name for p in out.stdout.split()),
                         ["performer.service", "thinqai.service"])

    def test_no_service_dir(self):
        out = sh('LUNA_SERVICE_DIR="$D/missing"; jailed_service_files "$E"',
                 D=str(self.dir), E=str(self.execs))
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout, "")

    def test_override_body_points_exec_at_stub(self):
        out = sh('service_override_body "$F"', F=str(self.dir / "performer.service"))
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.splitlines(), [
            "[D-BUS Service]",
            "Name=com.webos.service.voice.performer.plugin",
            "Exec=/var/lib/webosbrew/lifesgoodwithoutspying.stub",
            "Type=dynamic",
        ])


# Fake mount/umount over a fixture mountinfo, as in test_mount_ownership.
ROUND_TRIP = """
mount() { echo "200 59 179:59 $2 $3 rw shared:39 - ext4 /dev/mmcblk0p59 rw" >> "$MOUNTINFO"; }
umount() {
    awk -v p="$1" '{ l[NR] = $0; if ($5 == p) last = NR }
        END { for (i = 1; i <= NR; i++) if (i != last) print l[i] }' "$MOUNTINFO" > "$MOUNTINFO.new"
    mv "$MOUNTINFO.new" "$MOUNTINFO"
}
bounded() { echo "rescan $*" >> "$T/rescans"; }
command() { [ "$2" = ls-control ] && echo /usr/sbin/ls-control; }
MOUNTINFO="$T/mountinfo"; : > "$MOUNTINFO"
LUNA_SERVICE_DIR="$D"
SERVICE_OVERRIDE_DIR="$T/lifesgoodwithoutspying.services"
SERVICE_STATE="$T/overridden"
service_override voice.stop "$D/performer.service"
service_override domains.thinq "$D/thinqai.service"
services_rescan
service_clear_key voice.stop
services_rescan
echo "state:"; cat "$SERVICE_STATE"
echo "mounted:"; awk '{ print $5 }' "$MOUNTINFO"
echo "copy:"; grep '^Exec=' "$SERVICE_OVERRIDE_DIR/thinqai.service"
echo "rescans: $(grep -c . "$T/rescans")"
"""


class OverrideRoundTripTest(unittest.TestCase):
    def test_clearing_one_category_keeps_the_others(self):
        with tempfile.TemporaryDirectory() as tmp:
            services = Path(tmp) / "services.d"
            services.mkdir()
            for name in ("performer.service", "thinqai.service"):
                (services / name).write_text(textwrap.dedent(SERVICES[name]), encoding="utf-8")
            out = sh(ROUND_TRIP, T=tmp, D=str(services))
            self.assertEqual(out.returncode, 0, out.stderr)
            text = out.stdout.replace(tmp, "@T@")
        self.assertEqual(text.splitlines(), [
            "[+] hub rescanned the service files",
            "[+] hub rescanned the service files",
            "state:",
            "domains.thinq @T@/services.d/thinqai.service",
            "mounted:",
            "@T@/services.d/thinqai.service",
            "copy:",
            "Exec=/var/lib/webosbrew/lifesgoodwithoutspying.stub",
            "rescans: 2",
        ])


if __name__ == "__main__":
    unittest.main()
