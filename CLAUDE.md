# CLAUDE.md

Guidance for Claude Code (and humans) working in this repository.

## What this fork is

This is a personal fork of [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk),
a macOS dictation/transcription app built on whisper.cpp.

Remotes:
- `origin` → this fork (`nranthony/VoiceInk`)
- `upstream` → original (`Beingpax/VoiceInk`)

Keep `main` clean and in sync with `upstream/main`; do feature work on branches.

```bash
# pull upstream fixes
git fetch upstream
git switch main && git merge upstream/main && git push
# then rebase a feature branch on the updated main
git switch <feature-branch> && git rebase main
```

## Focus areas for this fork

1. **Power usage** — see `VoiceInk/PowerMode/` and `VoiceInk/Shortcuts/PowerModeShortcutManager.swift`.
   Note upstream branches `feature/power-mode-rewrite` and `feature/modes-rename-source-of-truth` —
   review before building new power-mode work.
   Active feature branch: `feature/power-usage`.
2. **Paste / keystroke injection** — see `VoiceInk/Paste/`
   (`PasteMethod.swift`, `ClipboardManager.swift`, `CursorPaster.swift`).
   Target: pasting into Windows running in a VM / over RDP from the Mac.
   Active feature branch: `feature/paste-shortcuts`.

## Building

Build locally with **`make local`** — ad-hoc signing, no Apple Developer account needed.
This uses `LocalBuild.xcconfig`, `VoiceInk.local.entitlements`, and the `LOCAL_BUILD`
Swift compilation flag, and does NOT touch the normal Debug/Release configs.

```bash
make local
open ~/Downloads/VoiceInk.app
```

Do not switch to `make build` / `make all` for local dev — those expect an Apple
Developer team (`DEVELOPMENT_TEAM` in the project) that this machine isn't set up for.

Full build details (whisper.cpp framework, manual build, troubleshooting) live in
[BUILDING.md](BUILDING.md) — refer there rather than duplicating here.

Build output and cache: `.local-build/` (gitignored).

## Source layout (VoiceInk/)

- `Paste/` — clipboard + cursor paste / keystroke injection
- `PowerMode/` — power mode config, session, active-window detection
- `Shortcuts/` — global keyboard shortcut managers
- `Transcription/` — whisper.cpp transcription pipeline
- `Services/`, `Models/`, `Views/` — app services, data models, SwiftUI views
- `AppIntents/`, `Notifications/` — system integration
