"""The init scripts source nospy-lib.sh, so a function they define with a
library function's name replaces it for every library caller."""
from pathlib import Path
import re
import unittest


INIT = Path(__file__).resolve().parents[1] / "app/init"
DEF = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{", re.M)


def defined(path):
    return set(DEF.findall(path.read_text(encoding="utf-8")))


class FunctionNamesTest(unittest.TestCase):
    def test_scripts_do_not_redefine_library_functions(self):
        lib = defined(INIT / "nospy-lib.sh")
        self.assertTrue(lib)
        for script in sorted(INIT.glob("*.sh")):
            if script.name == "nospy-lib.sh":
                continue
            if "nospy-lib.sh" not in script.read_text(encoding="utf-8"):
                continue
            with self.subTest(script=script.name):
                self.assertEqual(sorted(defined(script) & lib), [])


if __name__ == "__main__":
    unittest.main()
