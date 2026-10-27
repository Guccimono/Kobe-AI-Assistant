from __future__ import annotations

import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class SystemPythonTests(unittest.TestCase):
    def test_imports_on_the_system_python(self):
        # launchd's PATH puts /usr/bin/python3 (3.9) first for `/usr/bin/env python3`.
        py = Path("/usr/bin/python3")
        if not py.exists():
            self.skipTest("no system python3")
        r = subprocess.run([str(py), "-B", "-c", "import kobe_agent.daemon, kobe_agent.__main__"], cwd=ROOT,
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
