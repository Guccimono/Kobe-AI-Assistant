from __future__ import annotations

import json
import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from kobe_agent.watcher import Watcher


class WatcherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "requests").mkdir()
        self.handled = []

        def handle(request):
            self.handled.append(request)
            if request.get("action") != "refresh":
                return {"ok": False, "error": "Unknown action"}
            if request.get("id") != "stripe":
                return {"ok": False, "error": f"Kobe Agent doesn't run {request.get('id')} yet"}
            return {"ok": True, "error": None}

        self.watcher = Watcher(self.root, handle)

    def tearDown(self):
        self.watcher.close()
        self.tmp.cleanup()

    def drop(self, name, text, age=1.0):
        path = self.root / "requests" / name
        path.write_text(text)
        old = time.time() - age
        os.utime(path, (old, old))
        return path

    def result(self, name):
        return json.loads((self.root / "results" / name).read_text())

    def test_refresh_runs_connector_and_writes_result(self):
        req = self.drop("a1.json", json.dumps({"action": "refresh", "id": "stripe"}))
        self.watcher.poll()
        r = self.result("a1.json")
        self.assertEqual((r["id"], r["ok"], r["error"]), ("a1", True, None))
        self.assertRegex(r["done_at"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertFalse(req.exists())

    def test_unknown_action_result(self):
        self.drop("b.json", json.dumps({"action": "send_money", "id": "stripe"}))
        self.watcher.poll()
        self.assertEqual(self.result("b.json")["error"], "Unknown action")

    def test_not_owned_result(self):
        self.drop("c.json", json.dumps({"action": "refresh", "id": "whatsapp"}))
        self.watcher.poll()
        r = self.result("c.json")
        self.assertEqual((r["ok"], r["error"]), (False, "Kobe Agent doesn't run whatsapp yet"))

    def test_partial_file_skipped_then_read(self):
        self.drop("d.json", '{"action": "refr', age=0.0)
        self.assertGreater(self.watcher.poll(), 0)  # asks to be woken again soon
        self.assertFalse((self.root / "results" / "d.json").exists())
        self.drop("d.json", json.dumps({"action": "refresh", "id": "stripe"}))
        self.watcher.poll()
        self.assertTrue(self.result("d.json")["ok"])

    def test_malformed_json_gets_error_result_not_crash(self):
        self.drop("e.json", "{not json")
        self.drop("f.json", json.dumps(["refresh"]))
        self.watcher.poll()
        self.assertEqual(self.result("e.json")["error"], "Unreadable request")
        self.assertEqual(self.result("f.json")["error"], "Unreadable request")
        self.assertEqual(self.handled, [])

    def test_handler_crash_is_a_result(self):
        self.watcher.handle = lambda request: 1 / 0
        self.drop("g.json", json.dumps({"action": "refresh", "id": "stripe"}))
        self.watcher.poll()
        self.assertEqual(self.result("g.json")["error"], "Kobe Agent hit an internal error")

    def test_request_from_another_user_is_ignored(self):
        watcher = Watcher(self.root, lambda r: {"ok": True, "error": None}, owner_uid=os.getuid() + 1)
        self.drop("h.json", json.dumps({"action": "refresh", "id": "stripe"}))
        watcher.poll()
        watcher.close()
        self.assertFalse((self.root / "results" / "h.json").exists())

    def test_hidden_and_non_json_files_ignored(self):
        self.drop(".h.json.tmp", "{")
        self.drop("notes.txt", "x")
        self.watcher.poll()
        self.assertFalse((self.root / "results").exists() and any((self.root / "results").iterdir()))

    def test_wait_returns_on_new_file(self):
        self.drop("i.json", json.dumps({"action": "refresh", "id": "stripe"}))
        started = time.monotonic()
        self.watcher.wait(2.0)
        self.assertLess(time.monotonic() - started, 1.5)

    def test_result_write_error_still_clears_the_request(self):
        path = self.drop("r1.json", '{"action":"refresh","id":"stripe"}')
        with mock.patch("kobe_agent.watcher.folder.write_atomic", side_effect=OSError("disk full")):
            self.watcher.poll()
        self.assertFalse(path.exists())

    def test_deeply_nested_request_is_unreadable(self):
        self.drop("r2.json", "[" * 200_000)
        self.watcher.poll()
        self.assertEqual(self.result("r2.json")["error"], "Unreadable request")
