# AGENTS.md — VoiceInk (personal fork)

Guidance for any coding agent (and humans) working in this repository (Claude Code reads it through the `CLAUDE.md` stub).

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
open ~/Applications/VoiceInk.app
```

`make local` builds **Release** into `.local-build/` and installs to `LOCAL_APP_DEST`, which this
fork defaults to `~/Applications` (upstream hardcodes `~/Downloads`). Override it per machine in
an untracked `Makefile.local`, or per run: `make local LOCAL_APP_DEST=/some/dir`. Avoid
`~/Downloads`: Bitdefender Safe Files guards it and blocks the replace step. A failed install
now stops `make local` with an error instead of leaving a stale app that looks current.
`BUILDING.md` is upstream's and still says `~/Downloads`.

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
