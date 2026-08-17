# Review: validity + security of `feature/paste-shortcuts` and the v2.1 upgrade plan

**Status:** open
**Created:** 2026-08-17
**Area:** VoiceInk/Paste/, VoiceInk/PowerMode/, VoiceInk/Services/AIEnhancement/, work/upstream-v2.1-upgrade.md
**Type:** investigation

Security + correctness review of the 7 commits on `feature/paste-shortcuts` (vs `main`), plus the
same check applied to the proposals in [upstream-v2.1-upgrade.md](upstream-v2.1-upgrade.md).
Upstream claims were verified directly against `upstream/main` (`3626442`).

---

## Part 1 — the branch itself

### Security: clean

Full-branch security review (paste-method feature, clipboard-freeze fix, Makefile change, work
docs) found **no high-confidence vulnerabilities**. What was traced:

- **Synthetic keystroke injection** (`CursorPaster.pasteUsingControlV` / `typeText`) — both gated
  on `AXIsProcessTrusted()`, use a `.privateState` event source, inject only the app's own
  transcript or a bare Ctrl+V chord. No new trust boundary; the "transcript typed into a focused
  terminal" risk is inherent to a dictation app and identical to the pre-existing Cmd+V path.
  Transcript content is never logged.
- **Clipboard capture rework** (`AIEnhancementService`) — a net security *improvement*: the
  remote-owned pasteboard (the untrusted input) is read only when enhancement + clipboard context
  are enabled, time-boxed, off-main. `OneShotResolver` correctly prevents double-resume; the
  timeout log line interpolates only the timeout constant, never clipboard content.
- **Per-mode `pasteMethod` decoding** — string-raw-value enum from UserDefaults; no path from a
  decoded value to code execution, and UserDefaults is inside the local single-user trust boundary.
- **Makefile `-include Makefile.local` + `rm -rf`** — exploiting the include requires write access
  to the working directory, at which point the Makefile itself is editable; no privilege gained.
  Paths consistently quoted; `xattr -cr` applies only to the just-built local app.

### Validity: sound, three minor findings

The clipboard-freeze fix is correct — the `Task { }` in `captureClipboardContext` inherits the
MainActor so the `@Published` write is safe, and there is no suspension point between the
`Task.isCancelled` check and the assignment, so `clearCapturedContexts` cannot be raced into
leaving stale clipboard text. `PowerModeSessionManager` correctly snapshots `PasteMethod.current()`
before applying a mode and restores after.

- [ ] **`typeCharacters` still round-trips the transcript through the clipboard.**
      `performPasteSession` (`CursorPaster.swift:49`) unconditionally calls
      `ClipboardManager.setClipboard(text, ...)` before dispatching on paste method. In
      type-characters mode this (a) clobbers the user's clipboard for no reason when
      restore-clipboard is off, (b) syncs the transcript into the VM clipboard if host↔guest
      sharing is on — the one mode chosen specifically to avoid the clipboard, and (c) aborts the
      whole paste if `setClipboard` fails even though typing doesn't need it. Fix: early-out for
      `.typeCharacters` before the clipboard write. *(The one worth fixing.)*
- [ ] **Unknown `pasteMethod` raw value fails the whole config decode.**
      `decodeIfPresent(PasteMethod.self, ...)` (`PowerModeConfig.swift:106`) throws rather than
      returning nil on a raw value from a newer build, failing the entire mode's decode on
      downgrade. Consistent with the existing `autoSendKey` pattern, so low priority; a `String`
      decode + `PasteMethod(rawValue:) ?? .standard` is more forgiving.
- [ ] **`typeText` reports `.commandPosted` even if every character's event creation failed**
      (the `continue` at `CursorPaster.swift:170`). Cosmetic.
- [ ] **Doc drift:** `CLAUDE.md` still says `open ~/Downloads/VoiceInk.app`; `make local` now
      installs to `~/Applications` (or the `Makefile.local` override) since `7ff0807`.

---

## Part 2 — the v2.1 upgrade plan

### Validity: core claims verified, conflict map has drifted

Checked against `upstream/main` (`3626442`) on 2026-08-14:

- **Confirmed** — clipboard hang still unfixed upstream: `RecordingContextCaptureService.startCapture`
  runs `NSPasteboard.general.string(forType:)` in a `Task { @MainActor }` with no timeout and no
  gating, and fans out the synthetic ⌘C selected-text fetch and screen capture unconditionally.
  The fix must be carried forward, exactly as the plan says.
- **Confirmed** — migration keys (`powerModeConfigurationsV2` → `modeConfigurationsV2`,
  `ModeDataMigration.swift:90` / `ModeConfig.swift:284`); the pasteMethod-dropped-on-first-save
  trap is real, and the plan's mitigation order (land the `ModeConfig` field before running the
  migrated build) is right.
- **Confirmed** — `useSelectedTextContext` decoder (upstream `ModeConfig.swift:175-181`) falls back
  to `true` when both the mode field and the global key are absent, and upstream reads these flags
  only at prompt-assembly time (`AIEnhancementService.swift:116-117`), never at capture time.
- [ ] **Stale — conflict table.** §1's table predates the last two code commits. Re-running
      `git merge-tree --write-tree upstream/main feature/paste-shortcuts` now shows **two
      additional content conflicts: `Makefile`** (from `LOCAL_APP_DEST`, `7ff0807`) **and
      `AIEnhancementService.swift`** (from the clipboard-freeze fix, `bd26131`). Both resolvable,
      but the AIEnhancementService one is exactly the §4 carry-forward work, so the table
      understates the re-authoring surface. Append a dated correction to the plan.
- [ ] **Stale — §5 step 6** says to launch from `.local-build/.../VoiceInk.app` because
      Bitdefender blocks the copy to `~/Downloads`. Superseded by `7ff0807`: `make local` installs
      to `~/Applications` by default.
- [ ] **Minor** — the backup command `defaults read ... powerModeConfigurationsV2 > ...` produces
      output that can't be cleanly re-imported. Use
      `defaults export com.prakashjoshipax.VoiceInk work/voiceink-backup.plist` instead.

### Security of the proposal: the real risks are already addressed, mitigations correct

- The **`useSelectedTextContext` default-on trap is the significant security item** in the
  upgrade: post-merge, every mode would silently fire a synthetic ⌘C into whatever window has
  focus and attach the selection to enhancement requests — selected text (possibly credentials,
  private content, or content inside an RDP session) flowing to a possibly-cloud AI provider
  without opt-in. The plan's mitigation (set the global key to `false` before merging so the
  migration bakes `false` into every mode) is correct and sufficient; the fork-local in-app flag
  variant is the more durable version.
- The plan correctly identifies that **mirroring upstream's flag names does not carry the
  capture-side protection across** — gating capture (not just use), the off-main read, and the
  timeout have no upstream equivalent and must be re-applied to
  `RecordingContextCaptureService.startCapture`. That keeps the reduced-capture posture intact
  after the rebase.
- **Skipping the synthetic ⌘C for `controlV`/`typeCharacters` modes** is a genuine security
  improvement — it stops injecting a copy chord into remote sessions.
- Nothing in the proposal introduces new attack surface: no new shell execution, no new
  entitlements, no credential handling. (The adjacent
  [agentic-actions-research.md](agentic-actions-research.md) does propose shelling out to
  `claude -p` with MCP, but it is explicitly research-only, scopes tools via `--allowedTools`
  rather than `--dangerously-skip-permissions`, and routes writes to a triage list — reasonable
  posture if ever implemented.)

---

## Bottom line

The branch is safe and its code is correct apart from three minor items (the `typeCharacters`
clipboard round-trip being the one worth fixing). The v2.1 plan is technically accurate on
everything verifiable against upstream, handles the one real security trap correctly, and needs a
dated appendix noting the two new merge conflicts and the superseded launch workaround.
