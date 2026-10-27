from __future__ import annotations

import json
import os
import stat
import tempfile
import unittest
from importlib import reload
from pathlib import Path

from kobe_agent import config, folder, secrets
from kobe_agent.connectors import google
from tests.support import at

NOW = at(1792765690)
CLIENT = {"client_id": "cid", "client_secret": "cs", "refresh_token": "rt"}


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name) / "kobe"
        self.home.mkdir()
        os.environ["KOBE_AGENT_HOME"] = str(self.home)
        os.environ.pop("KOBE_EXCHANGE_ROOT", None)
        os.environ.pop("KOBE_AGENT_SECRETS", None)
        reload(folder)

    def tearDown(self):
        os.environ.pop("KOBE_AGENT_HOME", None)
        os.environ.pop("KOBE_EXCHANGE_ROOT", None)
        os.environ.pop("KOBE_AGENT_SECRETS", None)
        reload(folder)
        self.tmp.cleanup()

    def write(self, obj):
        (self.home / "config.json").write_text(json.dumps(obj))

    def test_missing_file_gives_defaults(self):
        self.assertEqual(config.load(), {})
        expected = Path.home() / "Library" / "Application Support" / "Kobe" / "exchange"
        self.assertEqual(folder.root(), expected)
        self.assertFalse(config.shared())
        self.assertIsNone(config.google_property())
        self.assertIsNone(config.google_site())

    def test_broken_file_gives_defaults(self):
        (self.home / "config.json").write_text("{nope")
        self.assertEqual(config.load(), {})

    def test_exchange_folder_from_config_with_tilde(self):
        self.write({"exchange_folder": "~/Somewhere/exchange", "version": 1})
        self.assertEqual(folder.root(), Path.home() / "Somewhere" / "exchange")
        self.assertEqual(folder.widgets(), Path.home() / "Somewhere" / "exchange" / "widgets")

    def test_env_override_wins(self):
        self.write({"exchange_folder": "/nowhere/config"})
        os.environ["KOBE_EXCHANGE_ROOT"] = "/nowhere/env"
        self.assertEqual(folder.root(), Path("/nowhere/env"))

    def test_google_keys_and_shared_flag(self):
        self.write({"google_property": "42", "google_site": "sc-domain:example.org", "shared": True})
        self.assertEqual(config.google_property(), "42")
        self.assertEqual(config.google_site(), "sc-domain:example.org")
        self.assertTrue(config.shared())

    def test_version_key_is_harmless(self):
        self.write({"exchange_folder": "/x/ex", "version": 1, "google_property": "42", "google_site": "s"})
        self.assertEqual(folder.root(), Path("/x/ex"))
        self.assertEqual((config.google_property(), config.google_site()), ("42", "s"))
        self.assertFalse(config.shared())

    def test_plain_modes_by_default(self):
        os.environ["KOBE_EXCHANGE_ROOT"] = str(Path(self.tmp.name) / "x")
        target = folder.widgets() / "stripe.json"
        folder.write_atomic(target, {"id": "stripe"})
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o644)
        self.assertEqual(stat.S_IMODE(target.parent.stat().st_mode), 0o755)

    def test_shared_modes_when_asked(self):
        self.write({"shared": True})
        os.environ["KOBE_EXCHANGE_ROOT"] = str(Path(self.tmp.name) / "x")
        target = folder.widgets() / "stripe.json"
        folder.write_atomic(target, {"id": "stripe"})
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o660)
        self.assertEqual(stat.S_IMODE(target.parent.stat().st_mode), 0o2770)

    def test_google_without_property_or_site_is_not_set_up(self):
        for cfg in ({}, {"google_property": "42"}, {"google_site": "sc-domain:example.org"}):
            self.write(cfg)
            s = google.run(CLIENT, now=NOW)
            self.assertEqual(s["status"], "not_set_up", cfg)
            self.assertEqual(s["source"], "agent")

    def test_secrets_read_plain_key_files_and_strip_whitespace(self):
        folder_ = self.home / "secrets"
        folder_.mkdir()
        for name, text in (("stripe", " rk_test_x\n"), ("github", "ghp_x\n"), ("vercel", "vt\n")):
            path = folder_ / name
            path.write_text(text)
            os.chmod(path, 0o600)
        self.assertEqual(secrets.load("stripe"), {"key": "rk_test_x"})
        self.assertEqual(secrets.load("github"), {"token": "ghp_x"})
        self.assertEqual(secrets.load("vercel"), {"token": "vt"})
        self.assertIsNone(secrets.load("google"))

    def test_secrets_refuse_open_files_and_flag_empty_ones(self):
        folder_ = self.home / "secrets"
        folder_.mkdir()
        (folder_ / "stripe").write_text("rk_x")
        os.chmod(folder_ / "stripe", 0o644)
        with self.assertRaises(secrets.InsecureFile):
            secrets.load("stripe")
        (folder_ / "github").write_text("  \n")
        os.chmod(folder_ / "github", 0o600)
        with self.assertRaises(ValueError):
            secrets.load("github")

    def test_set_key_roundtrip_is_plain_and_0600(self):
        secrets.save("vercel", {"token": "t"})
        path = self.home / "secrets" / "vercel"
        self.assertEqual(path.read_text().strip(), "t")
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(secrets.load("vercel"), {"token": "t"})

    def test_google_secret_is_json_without_property_or_site(self):
        secrets.save("google", CLIENT)
        self.assertEqual(secrets.load("google"), CLIENT)
        self.assertEqual(stat.S_IMODE((self.home / "secrets" / "google").stat().st_mode), 0o600)
