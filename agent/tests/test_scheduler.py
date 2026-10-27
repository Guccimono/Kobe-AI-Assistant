from __future__ import annotations

import unittest

from kobe_agent.scheduler import Scheduler

SCHEDULES = {"stripe": 600, "github": 600, "vercel": 300, "google": 3600}


class SchedulerTests(unittest.TestCase):
    def make(self, start=1000.0):
        return Scheduler(SCHEDULES, start=start)

    def test_first_runs_staggered_within_15s(self):
        s = self.make()
        self.assertEqual(s.due(1000.0)[:1], ["stripe"])
        firsts = {}
        for t in range(0, 16):
            for id in s.due(1000.0 + t):
                firsts.setdefault(id, t)
                s.begin(id)
                s.mark(id, 1000.0 + t)
        self.assertEqual(set(firsts), set(SCHEDULES))
        self.assertTrue(all(0 <= t <= 15 for t in firsts.values()))
        self.assertEqual(len(set(firsts.values())), len(SCHEDULES))

    def test_due_after_interval(self):
        s = self.make()
        for id in SCHEDULES:
            s.begin(id)
            s.mark(id, 1000.0)
        self.assertEqual(s.due(1299.0), [])
        self.assertEqual(s.due(1300.0), ["vercel"])
        self.assertEqual(sorted(s.due(1600.0)), ["github", "stripe", "vercel"])

    def test_no_overlap(self):
        s = self.make()
        s.begin("stripe")
        self.assertNotIn("stripe", s.due(5000.0))
        s.mark("stripe", 5000.0)
        self.assertNotIn("stripe", s.due(5000.0))
        self.assertIn("stripe", s.due(5600.0))

    def test_next_wake(self):
        s = self.make()
        for id in SCHEDULES:
            s.begin(id)
            s.mark(id, 1000.0)
        self.assertEqual(s.next_wake(1290.0), 10.0)
        self.assertEqual(s.next_wake(1400.0), 0.0)
        # Never more than a minute: the kqueue wait doesn't count sleep, the wall clock does.
        self.assertEqual(s.next_wake(1100.0), 60.0)

    def test_failed_runs_retry_with_backoff(self):
        s = self.make()
        s.begin("stripe")
        s.mark("stripe", 1000.0, failed=True)
        self.assertEqual(s.next["stripe"], 1030.0)
        s.mark("stripe", 1030.0, failed=True)
        self.assertEqual(s.next["stripe"], 1090.0)
        s.mark("stripe", 1090.0, failed=True)
        self.assertEqual(s.next["stripe"], 1210.0)
        s.mark("stripe", 1210.0)
        self.assertEqual(s.next["stripe"], 1810.0)
        s.mark("stripe", 1810.0, failed=True)
        self.assertEqual(s.next["stripe"], 1840.0)
        for _ in range(10):
            s.mark("vercel", 0.0, failed=True)
        self.assertEqual(s.next["vercel"], 300.0)

    def test_refresh_soon(self):
        s = self.make()
        for id in SCHEDULES:
            s.begin(id)
            s.mark(id, 1000.0)
        s.soon("google", 1001.0)
        self.assertEqual(s.due(1001.0), ["google"])
