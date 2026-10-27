from __future__ import annotations

"""The four snapshots Kobe App writes for the Mac apps: Kobe Agent only reads them. The fixtures are copies of
kobe-notch's Tests/KobeKitTests/Fixtures/snapshot_<id>.json."""
import json
import unittest
from pathlib import Path

CONTRACT = Path(__file__).resolve().parent / "contract"
ENVELOPE = {"id", "version", "updated_at", "status", "headline", "detail", "error", "data"}
DATA = {
    "mail": {"unread", "app_running", "messages"},
    "agenda": {"from", "to", "calendars", "events"},
    "reminders": {"overdue", "reminders"},
    "notes": {"app_running", "notes"},
}
ITEMS = {
    "mail": ("messages", {"id", "sender", "subject", "preview", "at", "unread", "account"}),
    "agenda": ("events", {"id", "title", "calendar", "start", "end", "all_day", "location", "url", "notes"}),
    "reminders": ("reminders", {"id", "title", "list", "list_color", "due", "due_has_time", "completed", "notes"}),
    "notes": ("notes", {"id", "title", "snippet", "folder", "modified"}),
}


class MacContractTests(unittest.TestCase):
    def test_each_mac_fixture_has_the_envelope_and_its_data(self):
        for wid, keys in DATA.items():
            with self.subTest(wid=wid):
                snap = json.loads((CONTRACT / f"snapshot_{wid}.json").read_text())
                self.assertTrue(ENVELOPE <= snap.keys())
                self.assertEqual(snap["id"], wid)
                self.assertEqual(snap["version"], 1)
                self.assertEqual(snap["source"], "app")
                self.assertEqual(set(snap["data"]), keys)
                field, item_keys = ITEMS[wid]
                self.assertTrue(snap["data"][field])
                for item in snap["data"][field]:
                    self.assertEqual(set(item), item_keys)
