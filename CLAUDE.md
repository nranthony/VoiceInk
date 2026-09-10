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

1. **Power usage** — now `VoiceInk/Features/Modes/`; upstream renamed Power Mode to Modes and the
   old `feature/power-mode-rewrite` / `feature/modes-rename-source-of-truth` branches are gone,
   merged into `main`.
2. **Paste / keystroke injection** — see `VoiceInk/Infrastructure/SystemIntegration/Paste/`
   (`PasteMethod.swift`, `ClipboardManager.swift`, `CursorPaster.swift`).
   Target: pasting into Windows running in a VM / over RDP from the Mac.

The fork's own work sits on branches off this one; see `work/` on those branches for plans and
open items. Nothing fork-specific has been ported onto this layout yet.

## Building

Build locally with **`make local`** — ad-hoc signing, no Apple Developer account needed.
This uses `LocalBuild.xcconfig`, `VoiceInk.local.entitlements`, and the `LOCAL_BUILD`
Swift compilation flag, and does NOT touch the normal Debug/Release configs.

```bash
make local
open ~/Downloads/VoiceInk.app
```

Upstream's `make local` builds **Release** and copies to `~/Downloads`. Two things to know:
Bitdefender Safe Files guards `~/Downloads`, so the copy step can be blocked and leave a *stale*
app sitting there that you then run by mistake; and this fork carries a patch making the
destination configurable (`LOCAL_APP_DEST`, defaulting to `~/Applications`) that has not been
ported onto this layout yet.

Do not switch to `make build` / `make all` for local dev — those expect an Apple
Developer team (`DEVELOPMENT_TEAM` in the project) that this machine isn't set up for.

Full build details (whisper.cpp framework, manual build, troubleshooting) live in
[BUILDING.md](BUILDING.md) — refer there rather than duplicating here.

Build output and cache: `.local-build/` (gitignored).

## Source layout (VoiceInk/)

Upstream reorganized the whole tree in the run-up to v2.x — the flat `Paste/`, `PowerMode/`,
`Services/`, `Views/` directories are gone. Five roots now:

- `App/` — lifecycle, windows, menu bar, navigation, app intents, notifications, migrations
- `Core/` — `Recording/`, `Transcription/` (whisper.cpp pipeline), `Enhancement/`
- `Features/` — one directory per user-facing feature: `Modes/` (ex-PowerMode), `Shortcuts/`,
  `Settings/`, `History/`, `Dashboard/`, `ModelLibrary/`, `Onboarding/`, …
- `Infrastructure/` — system-facing plumbing: `SystemIntegration/Paste/`, `Audio/`, `Providers/`,
  `Persistence/`, `Privacy/`, `TextProcessing/`, `Credentials/`
- `DesignSystem/` — shared SwiftUI components, theme, overlays

Also new alongside the app: `VoiceInkRefineXPC/` (local enhancement XPC service), `Shared/`,
`Tests/`, and `scripts/` + `release/` for the notarized release workflow.
