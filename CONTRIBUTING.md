# Contributing to Coucou

Thanks for wanting to help Mochi grow up! 🫶

## Getting started

```bash
brew install xcodegen
cd NotchBuddy && xcodegen && open NotchBuddy.xcodeproj
```

Never edit `NotchBuddy.xcodeproj` by hand: change `project.yml` and run `xcodegen`.

Check resting island dimensions on screens with and without a notch:

```bash
bash scripts/test-screen-geometry.sh
```

The Windows and Linux app is the Tauri project in `windows/` (Rust + TypeScript):

```bash
cd windows && npm install && npm run tauri dev
```

Anything OS-specific in its Rust code lives in `src-tauri/src/platform/`
(`windows.rs`, `linux.rs`, same functions on both sides); the rest of the app
only calls `platform::…`. A change on one side must still build on the other:
`cargo check --target x86_64-pc-windows-gnu` works from Linux. Build
dependencies and packaging are in [`windows/README.md`](windows/README.md).

## Good first contributions

- A new integration (a poller + a pill + a detail card). Look at `StripePoller.swift` for a compact example.
- A new emote or sound for Mochi.
- Bug fixes — please describe how to reproduce.

## Rules of the house

- Swift 6, SwiftUI + AppKit, **no third-party dependencies** unless there's really no other way.
- Secrets go in the Keychain, never on disk or in git.
- No telemetry, no network calls except to services the user configured.
- Never block Claude Code: if the app doesn't answer, the hook must exit right away.
- Never write `~/.claude/settings.json` without a backup and the user's confirmation.
- Keep it light: 0 % CPU when the island is hidden.
- Windows/Linux port: no new crate or npm package unless it is already in Tauri's own tree.

## Pull requests

- One topic per PR, with a short GIF or screenshot for anything visual.
- Build must pass with no new warnings.
