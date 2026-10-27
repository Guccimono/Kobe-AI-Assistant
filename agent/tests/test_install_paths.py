from __future__ import annotations

import io
import json
import plistlib
import re
import tempfile
import unittest
from pathlib import Path

from kobe_agent import google_auth, install

ROOT = Path(__file__).resolve().parent.parent


class InstallTests(unittest.TestCase):
    def test_gitignore_edit_is_idempotent_and_only_appends(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / ".gitignore"
            path.write_text(".env\nauth.json")  # no trailing newline
            self.assertTrue(install.ensure_gitignore(path))
            once = path.read_text()
            self.assertTrue(once.startswith(".env\nauth.json\n"))
            self.assertIn("kobe/secrets/\n", once)
            self.assertIn("kobe/logs/\n", once)
            self.assertFalse(install.ensure_gitignore(path))
            self.assertEqual(path.read_text(), once)

    def test_gitignore_created_when_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / ".gitignore"
            install.ensure_gitignore(path)
            self.assertEqual(path.read_text().splitlines(), list(install.IGNORED))

    def test_launch_agent_template_runs_as_the_user_without_secrets(self):
        plist = plistlib.loads((ROOT / "launchd" / "com.kobe-assistant.agent.plist").read_bytes())
        self.assertEqual(plist["Label"], "com.kobe-assistant.agent")
        self.assertNotIn("UserName", plist)
        self.assertEqual(plist["ProgramArguments"], ["/usr/bin/env", "python3", "-m", "kobe_agent", "run"])
        self.assertEqual(plist["WorkingDirectory"], "~/.hermes/kobe")
        self.assertTrue(plist["KeepAlive"])
        self.assertTrue(plist["StandardOutPath"].startswith("~/.hermes/kobe/logs/"))
        text = json.dumps(plist)
        self.assertIsNone(re.search(r"rk_|sk_|ghp_|ya29\.|token|secret|KEY", text, re.IGNORECASE))

    def test_client_file_from_stdin(self):
        obj = {"installed": {"client_id": "a", "client_secret": "b"}}
        self.assertEqual(google_auth.load_client("-", stdin=io.StringIO(json.dumps(obj))), obj)

    def test_no_second_user_scripts_ship(self):
        self.assertFalse((ROOT / "scripts" / "stage.sh").exists())
        self.assertFalse((ROOT / "scripts" / "install-as-hermes.sh").exists())

    def test_mac_snapshot_skill_names_the_four_files_from_the_config(self):
        skill = (ROOT / "skills" / "kobe-mac-snapshots" / "SKILL.md").read_text()
        self.assertTrue(skill.startswith("---\nname: kobe-mac-snapshots\n"))
        self.assertIn("~/.hermes/kobe/config.json", skill)
        self.assertIn("exchange_folder", skill)
        for name in ("mail", "agenda", "reminders", "notes"):
            self.assertIn(f"widgets/{name}.json", skill)
        self.assertIn("updated_at", skill)
        self.assertNotRegex(skill, r"/Us" "ers/|Mexico|his accounts")
