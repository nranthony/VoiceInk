# Task: rebase this fork onto upstream v2.1

**Status:** superseded — see the v2.13 section at the end
**Created:** 2026-08-10
**Fork base at time of writing:** upstream v1.79 (`0df2a9a`), 305 commits behind `upstream/main` (`3626442`)
**Snapshot of pre-upgrade state:** branch `alpha`, tag `alpha-v1.79-20260810`

This document is the running plan for moving the fork onto upstream v2.1. It is meant to be
revisited and appended to when later upstream versions land — see [Appending for future
versions](#appending-for-future-versions) at the end.

> **Also blocked on this upgrade:** [agentic-actions-research.md](agentic-actions-research.md) —
> the per-Mode `outputMode: .customCommand` and trigger-word routing that arrive with v2.x are the
> foundation for voice-triggered agent actions.

---

## 1. Why this is not a plain rebase

Upstream renamed and restructured the exact subsystem this fork modifies. `VoiceInk/PowerMode/`
no longer exists; it is now `VoiceInk/Modes/`, with `PowerModeConfig` split across several files.

Dry-run result (`git merge-tree --write-tree upstream/main feature/paste-shortcuts`):

| File | Conflict | Notes |
|---|---|---|
| `VoiceInk/Paste/CursorPaster.swift` | none | auto-merges |
| `VoiceInk/Paste/PasteMethod.swift` | content | from repo-wide reformat `f20ac14`; trivial to resolve |
| `VoiceInk/PowerMode/PowerModeConfig.swift` | modify/delete | → `VoiceInk/Modes/ModeConfig.swift` |
| `VoiceInk/PowerMode/PowerModeConfigView.swift` | modify/delete | → `ModeConfigEditorView.swift` + `ModeConfigFormView.swift` |
| `VoiceInk/PowerMode/PowerModeSessionManager.swift` | modify/delete | → `VoiceInk/Modes/` (session handling reworked) |

`main` itself merges `upstream/main` cleanly — this fork's `main` only adds `CLAUDE.md`, which
does not exist upstream.

**Recommendation: do not resolve the three modify/delete conflicts.** Take upstream's files
wholesale and re-author the per-Mode paste method against the new structure. Upstream added a
natural home for it that did not exist at v1.79 (see §3).

## 2. What is in the 305 commits

Relevant to this fork:

- **`9b40d31` Rename Power Mode to Modes** — the structural change driving all the conflicts.
- **`035c129` Refactor power mode config into editor draft and form files** — `ModeConfigDraft`
  now sits between the UI and the model; new fields need wiring through it.
- **`61965f8` Refactor power mode config layout and shared settings row** — the config UI our
  paste-method picker attaches to was rewritten.
- **`f20ac14` Reformat Swift source with consistent style** — repo-wide; cause of the
  `PasteMethod.swift` content conflict and of noisy diffs generally.
- **`cc9b597` feat: add VoiceInk Refine local enhancement** — new local XPC enhancement path,
  with its own model lifecycle tied to recording sessions.
- **`576ed67` perf: reduce recording UI contention** — restructured recording-start context
  capture into `RecordingContextSnapshot` / `RecordingContextCaptureService`. **Directly collides
  with our clipboard-hang fix — see §4.**
- **`eb4fabd` / `35ea001` FluidAudio transcription finalization** — adds `stopDisposition` /
  `StreamingStopDisposition` so short recordings fall back to batch instead of returning a
  clipped streaming result. Worth having; we run Parakeet V2.
- **`4be8719` avoid HTTP/3 for custom cloud model uploads** — ephemeral URLSession per request to
  dodge a 60s QUIC-over-VPN stall. Not our current bug, but same failure signature; worth knowing
  about if cloud models get used later.
- **`a319571` / `65e5738` macOS release workflow** — new GitHub Actions release pipeline.

Build tooling is **not** a concern: `Makefile`, `LocalBuild.xcconfig`, and
`VoiceInk/VoiceInk.local.entitlements` are all upstream's own files, and `make local` still
exists upstream with improvements. Nothing fork-local to preserve there.

## 3. Re-authoring the per-Mode paste method

Current fork implementation (`f3d6951`) adds to `PowerModeConfig`:

```swift
var pasteMethod: PasteMethod = .standard
```

plus the `CodingKeys` entry, the `init` parameter, and encode/decode handling; applied in
`PowerModeSessionManager.applyConfiguration` via `PasteMethod.setCurrent(config.pasteMethod)`,
with a picker in `PowerModeConfigView`.

Upstream `ModeConfig` already has adjacent concepts to hang this off:

```swift
enum ModeOutputMode: String, Codable, CaseIterable {
    case paste
    case respond
    case customCommand

    var usesPasteOptions: Bool { self == .paste }
}
```

and `ModeConfig.outputMode: ModeOutputMode = .paste`.

**Plan:**

1. Add `case controlV` and `case typeCharacters` to upstream's `PasteMethod` enum (it is down to
   `.standard` / `.appleScript` upstream), including `displayName` cases. Upstream's enum is
   **not** `Codable` — our version added that conformance; re-add it.
2. Add `pasteMethod: PasteMethod = .standard` to `ModeConfig`, with encode/decode.
3. Gate the picker on `outputMode.usesPasteOptions` so it only shows when the mode actually
   pastes — an improvement over the v1.79 version, which always showed it.
4. Thread the field through `ModeConfigDraft` (new indirection that did not exist at v1.79).
5. Add the picker to `ModeConfigFormView`, using the shared settings-row component from
   `61965f8` rather than hand-rolled layout.
6. Apply it wherever upstream's session manager applies mode settings (equivalent of the old
   `applyConfiguration`), via `PasteMethod.setCurrent(...)`.
7. Port `CursorPaster.pasteUsingControlV` / `typeText` — these auto-merge, but re-check them
   against upstream's `576ed67` changes to `CursorPaster.swift`.

### ⚠ Data-migration trap

Upstream migrates saved modes with:

```swift
LegacyModeDataKey.configurations = "powerModeConfigurationsV2"   // our current key
private let configKey            = "modeConfigurationsV2"        // new key
```

`migratedModeConfigurationData` copies the old blob to the new key verbatim. `ModeConfig`'s
decoder then **silently ignores** the unknown `pasteMethod` field, and the next save re-encodes
without it — so the setting is lost on first mode edit after upgrading.

**Therefore: land step 2 (the `ModeConfig` field) before running the migrated build against real
settings.** Otherwise back up `powerModeConfigurationsV2` first:

```bash
defaults read com.prakashjoshipax.VoiceInk powerModeConfigurationsV2 > work/powermode-backup.txt
```

## 4. Carry forward the clipboard-hang fix — upstream has NOT fixed it

The 60s recording-start freeze (main thread blocked in `NSPasteboard.general.string(forType:)`
when the clipboard is owned by Windows App over RDP) is **still present in v2.1**.

Upstream moved the code but kept the defect:

```swift
// upstream/main VoiceInk/Services/RecordingContextSnapshot.swift
Task { @MainActor in
    store.updateClipboardText(NSPasteboard.general.string(forType: .string))
}
```

Still `@MainActor`, still no timeout, still ungated. `VoiceInkEngine.startRecordingContextCapture`
calls it unconditionally on every recording. Upstream's per-mode `useClipboardContext` /
`useSelectedTextContext` flags gate **use**, not **capture**.

It is arguably worse there: the same fan-out also runs `SelectedTextService.fetchSelectedText()`
(synthetic ⌘C — hazardous into an RDP window) and a screen capture + OCR.

**Port our fix into `RecordingContextCaptureService.startCapture`:**

- gate each capture on whether anything will consume it
- move the pasteboard read off the main thread
- time-box it (we use 2s) so a wedged pasteboard yields `nil` instead of freezing the app
- consider skipping the selected-text ⌘C entirely for modes whose paste method is
  `controlV` / `typeCharacters`, i.e. VM/RDP targets

This is a good candidate to offer upstream as a PR — it is a real bug affecting anyone dictating
into a VM, RDP session, or Remote Desktop client, and the fix is small.

### ⚠ `useSelectedTextContext` defaults to ON after the merge

`ModeConfig`'s decoder falls back to the **legacy global UserDefaults keys** when a saved mode
lacks the field — which ours all do, since v1.79's `PowerModeConfig` never had them:

```swift
useClipboardContext = try container.decodeIfPresent(...)
    ?? UserDefaults.standard.bool(forKey: "useClipboardContext")

if let decoded = try container.decodeIfPresent(Bool.self, forKey: .useSelectedTextContext) {
    useSelectedTextContext = decoded
} else if UserDefaults.standard.object(forKey: "useSelectedTextContext") == nil {
    useSelectedTextContext = true          // ← ON when the key is absent
} else {
    useSelectedTextContext = UserDefaults.standard.bool(forKey: "useSelectedTextContext")
}
```

- `useClipboardContext` — unset globally → decodes to `false`. Safe.
- `useSelectedTextContext` — unset globally → decodes to **`true`**. Every mode comes up with
  selected-text capture enabled, including the synthetic ⌘C (`.menuAction` strategy) fired into
  whatever window has focus. In a VM/RDP target that is both a privacy and a correctness problem.

**Mitigation, cheapest first:** set the global key explicitly before merging —

```bash
defaults write com.prakashjoshipax.VoiceInk useSelectedTextContext -bool false
```

— or better, add a fork-local global flag using exactly that key name so the value is set through
the app. Upstream's migration then carries `false` into every `ModeConfig` for free.

**What mirroring upstream does and does not buy us:**

| Piece | Mirrors upstream | Survives merge |
|---|---|---|
| Key name `useSelectedTextContext` / `useClipboardContext` | yes | yes — upstream decodes from it |
| The value we set | — | yes — migrated into every mode |
| Per-mode plumbing (`ModeConfig`/`Draft`/`FormView`/`ModeRuntimeConfiguration`) | upstream has it, we don't | theirs wins, and theirs is richer |
| **Gating the capture, not just its use** | **no upstream equivalent** | **no — re-apply by hand** |

The last row is the one that matters: upstream's flags are read at prompt-assembly time
(`AIEnhancementService.swift:116-117`), never at capture time. Matching the names is worth doing,
but it does **not** carry the protection across — the capture-side gating, the off-main pasteboard
read, and the timeout are all fork-local and must be re-applied to
`RecordingContextCaptureService.startCapture`.

## 5. Suggested sequence

1. `git switch main && git merge upstream/main && git push` — clean, no conflicts.
2. Branch `feature/modes-paste-method` off the updated `main`.
3. Take upstream's `VoiceInk/Modes/` wholesale; delete the old `VoiceInk/PowerMode/` conflict
   remnants rather than resolving them.
4. Re-apply the paste work per §3, in the order given (field before UI before migration testing).
5. Re-apply the clipboard fix per §4.
6. `make local`, then launch from `.local-build/Build/Products/Debug/VoiceInk.app` — the copy to
   `~/Downloads` is blocked by Bitdefender Safe Files on this machine.
7. Verify against the checklist below.
8. Tag the result `alpha-v2.1-<yyyymmdd>` and fast-forward `alpha`.

## 6. Verification checklist

- [ ] Existing modes survive the `powerModeConfigurationsV2` → `modeConfigurationsV2` migration
- [ ] "Windows App" mode retains `pasteMethod: typeCharacters` after a mode edit + app restart
- [ ] Paste method picker hidden when `outputMode != .paste`
- [ ] Ctrl+V paste works into the Windows VM (Scan code keyboard mode)
- [ ] Type-characters paste works into the Windows VM (Unicode keyboard mode)
- [ ] Recording start does not stall with the Windows App clipboard active — confirm via:
      `log show --predicate 'subsystem CONTAINS "voiceink"' --last 1h --info | grep elapsed=`
      (`Streaming connected` should be well under 1s)
- [ ] Enhancement still receives clipboard context when enhancement + `useClipboardContext` are on
- [ ] Parakeet V2 streaming still finalizes correctly, including very short recordings

---

## Appending for future versions

When a later upstream release lands, add a new dated section below rather than rewriting the
above — the history of what changed between rebases is the useful part.

Template:

```
## Upgrade to upstream vX.Y — <date>
- Commits behind at start:
- New/renamed files touching our surface area:
- Conflicts from `git merge-tree --write-tree upstream/main <branch>`:
- Fork patches that still apply cleanly:
- Fork patches needing re-authoring:
- Upstream fixes that supersede a fork patch (delete ours):
- Snapshot tag created:
```

Useful commands:

```bash
git fetch upstream
git rev-list --count main..upstream/main                        # how far behind
git log --oneline main..upstream/main -- VoiceInk/Paste/        # churn in our areas
git merge-tree --write-tree --name-only upstream/main <branch>  # conflict dry run
git diff --find-renames --name-status main upstream/main -- VoiceInk/Modes/
```

---

## Upgrade to upstream v2.13 — 2026-09-10

**The v2.1 plan above is stale. Read this section first; treat everything above it as history.**

Upstream never sat still at v2.1. It is now **v2.13** (`71b817c`), and the reorganization is far
wider than the `PowerMode/` → `Modes/` rename the plan was built around — §1's conflict table is
wrong in every row, because none of those paths exist any more.

- **Commits behind at start:** 385 (`main` was `b18bc07`, 1 ahead with CLAUDE.md only)
- **New/renamed files touching our surface area:** the whole tree. Flat `VoiceInk/{Paste,PowerMode,
  Services,Views}/` is gone, split across `App/ Core/ DesignSystem/ Features/ Infrastructure/`.
  - `VoiceInk/Paste/` → `VoiceInk/Infrastructure/SystemIntegration/Paste/`
  - `VoiceInk/PowerMode/` → `VoiceInk/Features/Modes/` (+ `Features/Modes/State/ModeConfigDraft.swift`)
  - recording-start capture → `VoiceInk/Features/Recording/Context/RecordingContextSnapshot.swift`
  - `AIEnhancementService` → `VoiceInk/Features/Enhancement/Workflows/`
- **Conflicts:** `main` + `upstream/main` merges **clean** (CLAUDE.md does not exist upstream);
  merged as `0c8abaf` and pushed. `local-release/v1.79` + `upstream/main` conflicts, as expected —
  do not try to rebase it.
- **Fork patches that still apply cleanly:** none. The reorg plus the `f20ac14` reformat means
  every one is a re-author.
- **Upstream fixes that supersede a fork patch:** none. All four unguarded `NSPasteboard` reads
  are still present at v2.13 — see [upstream-pasteboard-prs](upstream-pasteboard-prs.md) for the
  site-by-site table.
- **Build tooling:** §2's "not a concern" still holds, with one exception — upstream's `make local`
  builds **Release** and copies to `~/Downloads`, so the `LOCAL_APP_DEST` patch (`7ff0807`) is
  still worth carrying, and is now PR 3 in the pasteboard-PR doc.
- **Snapshot tag created:** `local-v1.79-20260910` on `local-release/v1.79` (the frozen build in
  daily use, ex-`feature/paste-shortcuts`). The older `alpha-v1.79-20260810` was local-only until
  2026-09-10 and is now pushed to `origin`.

### Still valid from the plan above

§3's re-authoring plan for the per-Mode paste method, and its **data-migration trap** — upstream's
`migratedModeConfigurationData` copies the old blob verbatim, `ModeConfig`'s decoder silently drops
the unknown `pasteMethod`, and the next save re-encodes without it. Land the `ModeConfig` field
before running a migrated build against real settings, or back the key up first. Verify the key
names again at v2.13 before relying on them.

### Order of work

1. PR 1 from [upstream-pasteboard-prs](upstream-pasteboard-prs.md), off `upstream/main`.
2. Port the fork features onto a fresh branch off the new `main`, taking upstream's files
   wholesale — §1's original recommendation, just against a different target.
3. Re-tag a new local release once the port is the build in daily use.

Doing 1 before 2 means the PRs go out against a stable upstream while the port is in flight, and
if they land there is less to carry.
