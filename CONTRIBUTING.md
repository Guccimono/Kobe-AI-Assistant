# Contributing

Thanks for helping. Kobe is a small, single-user macOS app; changes that keep it small and private are the easiest
to merge. `CLAUDE.md` has the code layout and the full rules; this is the short version.

## Build and test

You need macOS 26, Apple Silicon and the Xcode Command Line Tools (Swift 6.2).

```bash
scripts/test.sh                  # Swift tests (KobeKit and the app target) and the agent's Python tests
swift test --filter <Suite>      # while iterating
scripts/bundle.sh                # build/Kobe.app
build/Kobe.app/Contents/MacOS/Kobe --demo --open home    # sample data, no Keychain
```

`scripts/test.sh` must be green before you open a pull request. CI runs on GitHub's latest macOS runner, which can lag behind the macOS 26 SDK this package needs.

## Rules

- Test first. Logic goes in `KobeKit` with a failing Swift Testing test written before the code; the app target
  (`KobeApp`) only wires and draws. Python changes in `agent/` get a test in `agent/tests` first.
- Swift 6 strict concurrency, no third-party dependencies (the agent is Python standard library only).
- Views use the kit in `Sources/KobeApp/Kit/`, colours from `K`/`Theme`, radii from `Radius`, type from `KFont`.
- No telemetry, and no secret on disk, in logs, in URLs or in process arguments: keys live in the Keychain.
- Nothing is approved, sent or deleted without a click or hotkey from the user.
- Copy is short, plain English. Use the assistant's name token (`Copy`), not a hard-coded "Kobe", in persona strings.
- No screenshots in tests or fixtures that show real data. Fixtures use `example.com`, `+1 555` numbers, `acme/*`.

## Add a widget (a page in the notch)

A widget is a snapshot file plus a page that draws it.

1. Add the id to `WidgetID` (`Sources/KobeKit/Snapshots/WidgetSnapshot.swift`), its data type under
   `Sources/KobeKit/Snapshots/`, and a fixture and decoding test in `Tests/KobeKitTests`.
2. Add a freshness window to `SnapshotRules`, and the strip entry in `StripLayout.swift`.
3. Draw it with kit views in `Sources/KobeApp/Views/Pages/`.
4. Produce the snapshot: from Kobe Agent (`agent/kobe_agent/connectors/`) or from your own script. The file format
   is in the README ("Write your own widget").

## Add an icon

Icons are Phosphor only. Add a case to the `PhosphorIcon` enum in `Sources/KobeKit/Icons.swift`, then run
`scripts/fetch-icons.sh` to download the official SVG into `Sources/KobeKit/Resources/Icons`. Do not draw your own and do
not use SF Symbols.

## Commits and pull requests

Small commits, imperative subject with a conventional prefix: `feat:`, `fix:`, `docs:`, `chore:`, `test:`,
`refactor:`. The body says why. One topic per pull request, with the tests that cover it.
