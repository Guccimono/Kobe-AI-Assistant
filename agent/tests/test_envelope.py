from __future__ import annotations

import json
import os
import stat
import tempfile
import unittest
from datetime import datetime, timezone
from importlib import reload
from pathlib import Path

from kobe_agent import envelope as env
from kobe_agent import folder
from kobe_agent.timefmt import from_epoch, iso
from tests import contract_check


class EnvelopeTests(unittest.TestCase):
    def test_iso_has_no_fraction_and_z(self):
        dt = datetime(2026, 10, 23, 14, 28, 10, 123456, tzinfo=timezone.utc)
        self.assertEqual(iso(dt), "2026-10-23T14:28:10Z")

    def test_from_epoch_seconds_and_ms(self):
        expected = datetime(2026, 10, 23, 14, 28, 10, tzinfo=timezone.utc)
        self.assertEqual(from_epoch(1792765690), expected)
        self.assertEqual(from_epoch(1792765690000), expected)
        self.assertIsNone(from_epoch(None))

    def test_envelope_keys_and_version(self):
        now = datetime(2026, 10, 23, 14, 28, 10, tzinfo=timezone.utc)
        e = env.envelope("stripe", "ok", "All good", "3 payments", {"a": 1}, now=now)
        self.assertEqual(list(e), ["id", "version", "updated_at", "status", "headline", "detail", "error", "data", "source"])
        self.assertEqual(e["version"], 1)
        self.assertEqual(e["updated_at"], "2026-10-23T14:28:10Z")
        self.assertEqual(e["source"], "agent")
        self.assertIsNone(e["error"])

    def test_status_must_be_known(self):
        with self.assertRaises(ValueError):
            env.envelope("stripe", "weird", "", "", {})

    def test_write_atomic_mode_0644_and_no_temp_left(self):
        with tempfile.TemporaryDirectory() as root:
            os.environ["KOBE_EXCHANGE_ROOT"] = root
            try:
                reload(folder)
                target = folder.widgets() / "stripe.json"
                folder.write_atomic(target, {"id": "stripe", "headline": "Café"})
                self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o644)
                self.assertEqual(json.loads(target.read_text())["headline"], "Café")
                self.assertEqual([p.name for p in target.parent.iterdir()], ["stripe.json"])
            finally:
                del os.environ["KOBE_EXCHANGE_ROOT"]
                reload(folder)

    def test_contract_check_finds_missing_and_type_mismatch(self):
        fixture = {"a": 1, "b": {"c": "x"}, "d": None, "e": [{"f": 1}]}
        self.assertEqual(contract_check.same_shape({"a": 2, "b": {"c": "y"}, "d": [1], "e": [{"f": 3}]}, fixture), [])
        diffs = contract_check.same_shape({"a": "1", "b": {}, "e": [{"f": 1.5}], "z": 0}, fixture)
        self.assertIn("a: str != int", diffs)
        self.assertIn("b.c: missing", diffs)
        self.assertIn("d: missing", diffs)
        self.assertIn("e[0].f: float != int", diffs)
        self.assertIn("z: extra", diffs)


if __name__ == "__main__":
    unittest.main()
