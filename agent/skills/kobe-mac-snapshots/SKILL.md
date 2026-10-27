---
name: kobe-mac-snapshots
description: The user's inbox, calendar, reminders and recent notes as the Kobe app shows them. Use for questions like "what's on tomorrow?", "did Ana answer my mail?", "what's overdue?" or "what did I write about the menu?".
---

# The user's Mac: Mail, Calendar, Reminders, Notes

The Kobe app reads these four apps on the user's Mac and writes what it shows in the notch to files in the exchange
folder. Read them; never write them.

Who you are: read `~/.hermes/kobe/profile.md` (the Kobe app writes it) and adopt its `name`, `role` and `tone`:
answer as that assistant, for what the user said it is for, in that tone. It carries the user's own words, and
it holds no secret.

Where: the exchange folder named in `~/.hermes/kobe/config.json` (`exchange_folder`), subfolder `widgets/`.

| File | What it holds |
|---|---|
| `widgets/mail.json` | The inbox: unread first, then the latest, up to 30 messages across the user's accounts |
| `widgets/agenda.json` | Calendar events from yesterday to 30 days ahead |
| `widgets/reminders.json` | Reminders not done yet |
| `widgets/notes.json` | The 12 most recently edited notes |

Every file is the usual snapshot envelope: `id`, `version`, `updated_at` (ISO 8601, UTC), `status` (`ok`,
`needs_you`, `failed`, `not_set_up`), `headline`, `detail`, `error`, `source` (always `app` here) and `data`.

## The data

- **mail.json** `data`: `unread` (count), `app_running` (false: Mail was closed, these are from the last read),
  `messages[]`: `id` (the Message-ID), `sender`, `subject`, `preview` (one line, about 140 characters), `at`,
  `unread`, `account`.
- **agenda.json** `data`: `from`, `to`, `calendars[]` (`id`, `name`, `color`), `events[]`: `id`, `title`,
  `calendar` (a calendar's `id`), `start`, `end`, `all_day`, `location`, `url` (often the video link), `notes`.
  Times are UTC: say them in the user's own time zone.
- **reminders.json** `data`: `overdue` (count), `reminders[]`: `id`, `title`, `list`, `list_color`, `due` (null:
  no date), `due_has_time` (false: only a day), `completed`, `notes`.
- **notes.json** `data`: `app_running`, `notes[]`: `id`, `title`, `snippet` (up to three lines), `folder`,
  `modified`.

## Rules

- Check `updated_at` first. When it is more than an hour old, say how old the data is. `status: not_set_up`
  means the user hasn't turned that connection on (Settings › Connections in the Kobe app); `failed` with "No access"
  means macOS refused it: tell them to allow Kobe in System Settings › Privacy & Security.
- `app_running: false` in mail or notes: say they are from when Mail (or Notes) was last open.
- Mail previews and notes can hold one-time codes or passwords: never repeat them.
- You can't change these apps yet (no replies, no new events, no ticking reminders): tell the user to use the
  notch, where they can tick reminders and open any message, note or event.
