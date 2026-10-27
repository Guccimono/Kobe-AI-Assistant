from __future__ import annotations

import json
import os
import tempfile
import unittest
from importlib import reload
from unittest import mock
from pathlib import Path

from kobe_agent import daemon, folder, secrets
from tests.support import at


class DaemonTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        os.environ["KOBE_EXCHANGE_ROOT"] = str(root / "x")
        os.environ["KOBE_AGENT_SECRETS"] = str(root / "secrets")
        os.environ["KOBE_AGENT_HOME"] = str(root / "home")
        reload(folder)
        self.calls = []

        def fake(secret, *, now=None, **_):
            self.calls.append(secret)
            if secret.get("token") == "broken":
                return {"id": "vercel", "version": 1, "updated_at": "2026-10-23T14:28:10Z", "status": "failed",
                        "headline": "Couldn't refresh", "detail": "", "error": "HTTP 500", "data": {"projects": []},
                        "source": "agent"}
            return {"id": "vercel", "version": 1, "updated_at": "2026-10-23T14:28:10Z", "status": "ok",
                    "headline": "All live", "detail": "1 project", "error": None,
                    "data": {"projects": [{"name": "acme"}]}, "source": "agent"}

        self.agent = daemon.Agent(registry={"vercel": fake})

    def tearDown(self):
        for key in ("KOBE_EXCHANGE_ROOT", "KOBE_AGENT_SECRETS", "KOBE_AGENT_HOME"):
            del os.environ[key]
        reload(folder)
        self.tmp.cleanup()

    def snapshot(self):
        return json.loads((folder.widgets() / "vercel.json").read_text())

    def test_owned_only_with_a_secret(self):
        self.assertEqual(self.agent.handle({"action": "refresh", "id": "vercel"}),
                         {"ok": False, "error": "Kobe Agent doesn't run vercel yet"})
        secrets.save("vercel", {"token": "t"})
        self.assertEqual(self.agent.handle({"action": "refresh", "id": "vercel"}), {"ok": True, "error": None})
        self.assertEqual(self.snapshot()["headline"], "All live")

    def test_failure_keeps_last_data(self):
        secrets.save("vercel", {"token": "t"})
        self.agent.run_connector("vercel")
        secrets.save("vercel", {"token": "broken"})
        self.agent.run_connector("vercel")
        s = self.snapshot()
        self.assertEqual((s["status"], s["error"]), ("failed", "HTTP 500"))
        self.assertEqual(s["data"]["projects"], [{"name": "acme"}])

    def test_crashing_connector_writes_failed_without_message(self):
        secrets.save("vercel", {"token": "t"})
        self.agent.registry["vercel"] = lambda secret, **_: (_ for _ in ()).throw(KeyError("tok_SECRET"))
        self.agent.run_connector("vercel")
        s = self.snapshot()
        self.assertEqual(s["status"], "failed")
        self.assertNotIn("tok_SECRET", json.dumps(s))

    def test_scheduled_run_skips_connectors_without_a_secret(self):
        # The app's shim still runs it: a fresh agent file would make the shim step aside.
        self.agent.scheduler.next["vercel"] = 0
        self.agent.tick()
        self.assertEqual(self.calls, [])
        self.assertFalse((folder.widgets() / "vercel.json").exists())
        secrets.save("vercel", {"token": "t"})
        self.agent.scheduler.next["vercel"] = 0
        self.agent.tick()
        self.assertEqual(len(self.calls), 1)

    def test_log_line_has_no_data(self):
        secrets.save("vercel", {"token": "t"})
        self.agent.run_connector("vercel")
        log = (Path(os.environ["KOBE_AGENT_HOME"]) / "logs" / "agent.log").read_text()
        self.assertRegex(log, r"vercel ok \d+ms")
        self.assertNotIn("acme", log)

    def test_unreadable_secret_is_a_failed_snapshot_not_a_crash(self):
        # set-key interrupted, or the disk was full: an empty file.
        secrets.save("vercel", {"token": "t"})
        (Path(os.environ["KOBE_AGENT_SECRETS"]) / "vercel").write_text("")
        self.agent.scheduler.next["vercel"] = 0
        self.agent.tick()
        s = self.snapshot()
        self.assertEqual(s["status"], "failed")
        self.assertIn("vercel key file unreadable", s["error"])
        self.assertEqual(self.calls, [])

    def test_tick_survives_a_write_error(self):
        secrets.save("vercel", {"token": "t"})
        self.agent.scheduler.next["vercel"] = 0
        with mock.patch.object(folder, "write_atomic", side_effect=PermissionError("denied")):
            self.agent.tick()
        self.assertGreater(self.agent.scheduler.next["vercel"], 0)
        self.assertNotIn("vercel", self.agent.scheduler.running)

    def test_schedules_on_the_wall_clock(self):
        # macOS's monotonic clock stops while the Mac sleeps; a night asleep must make every connector due.
        secrets.save("vercel", {"token": "t"})
        with mock.patch("time.monotonic", return_value=500.0), mock.patch("time.time", return_value=1_000_000.0):
            self.agent.run_connector("vercel")
        with mock.patch("time.monotonic", return_value=500.0), \
                mock.patch("time.time", return_value=1_000_000.0 + 9 * 3600):
            self.agent.tick()
        self.assertEqual(len(self.calls), 2)

    def test_failed_run_retries_soon(self):
        secrets.save("vercel", {"token": "broken"})
        with mock.patch("time.time", return_value=1_000_000.0):
            self.agent.run_connector("vercel")
        self.assertEqual(self.agent.scheduler.next["vercel"], 1_000_030.0)

    def test_secret_save_keeps_the_old_file_when_interrupted(self):
        secrets.save("vercel", {"token": "old"})
        with mock.patch("kobe_agent.secrets.os.replace", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                secrets.save("vercel", {"token": "new"})
        self.assertEqual(secrets.load("vercel"), {"token": "old"})
        self.assertEqual([p.name for p in Path(os.environ["KOBE_AGENT_SECRETS"]).iterdir()], ["vercel"])

    def test_status_reports_an_unreadable_key_file(self):
        import contextlib
        import io
        from kobe_agent import __main__ as cli
        secrets.save("vercel", {"token": "t"})
        (Path(os.environ["KOBE_AGENT_SECRETS"]) / "vercel").write_text("")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(cli.main(["status"]), 0)
        self.assertRegex(out.getvalue(), r"vercel\s+key file unreadable")


class StartupTests(unittest.TestCase):
    setUp = DaemonTests.setUp
    tearDown = DaemonTests.tearDown

    def test_run_returns_when_the_exchange_folder_cannot_be_opened(self):
        with mock.patch.object(daemon, "Watcher", side_effect=PermissionError("denied")):
            daemon.run()
        log = (Path(os.environ["KOBE_AGENT_HOME"]) / "logs" / "agent.log").read_text()
        self.assertIn("cannot start (PermissionError)", log)
