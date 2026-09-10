# Task: send the pasteboard-timeout fixes upstream

**Status:** open
**Created:** 2026-09-10
**Area:** `VoiceInk/Infrastructure/SystemIntegration/Paste/`, `VoiceInk/Features/Recording/Context/`
**Type:** upstream PR candidate

Branch each of these off `upstream/main` directly — never off this fork's trunk. The whole point
is a diff a maintainer can read in one sitting, with no dependency on fork-only code.

---

## 1. Why bother

These patches are the "upstream has no concept of this" category from [README](README.md): they
must be re-applied by hand on every rebase, forever, until they land upstream. The v2.13 reorg
just demonstrated the cost — none of them cherry-pick any more (see §4).

## 2. The defect, and where it still lives at v2.13

Reading `NSPasteboard` is a synchronous IPC to the pasteboard server, and the owning app supplies
the payload lazily. When the owner is a remote/VM client — Windows App over RDP only fetches from
the guest on demand — the IPC blocks until the server's **~60s timeout**. On the main actor that
freezes the whole app.

Verified present in `upstream/main` at v2.13 (`71b817c`), all unguarded, none with a timeout:

| Site | What it breaks | Fork fix |
|---|---|---|
| `Paste/CursorPaster.swift:79-88` `snapshotClipboard`, called from `performPasteSession:50` | Paste path. Transcript arrives ~60s late in whatever window has focus by then | `344bbf8` |
| `Features/Recording/Context/RecordingContextSnapshot.swift:39` | Recording start. Streaming session cannot flip to `.streaming` | `bd26131` |
| `Features/Enhancement/Workflows/AIEnhancementService.swift:438` `captureClipboardContext` | Same as above, second path, also ungated on `useClipboardContext` | `bd26131` |
| `Paste/ClipboardManager.swift:43` `getClipboardContent` | Nothing — **dead code upstream too**, no callers. Same unguarded read waiting for its first one | `344bbf8` |

Evidence for the paste-path one, from `os_log` on 2026-09-09 (transcription itself took 103ms):

```
14:05:50.139  Streaming transcript received elapsed=0.103s chars=100
14:05:50.152  [AppKit:Pasteboard] data requested public.utf8-plain-text
              <- main thread emits nothing for 60.009s
14:06:50.161  [AppKit:Pasteboard] data requested public.utf8-plain-text
14:06:50.774  dismissMiniRecorder called - state=transcribing
```

Attach this trace to the issue. It is the part a maintainer cannot easily reproduce — it needs a
VM/RDP client owning the Mac clipboard.

## 3. PR order

**PR 1 — paste-path snapshot timeout.** Strongest case: user-visible freeze, one file, ~55 lines,
no dependency on fork-only code. Send this first and let it set the pattern.

**PR 2 — recording-start capture.** Same treatment for the two capture sites. Larger surface
(upstream restructured this into `RecordingContextCaptureService` in `576ed67`) and it wants the
`isEnhancementEnabled && useClipboardContext` gating argument made separately, so it is a harder
review. Hold until PR 1 lands.

**PR 3 — `LOCAL_APP_DEST`.** Unrelated to the pasteboard, but the same "we re-apply this forever"
problem: `make local` copies to `~/Downloads`, which Bitdefender Safe Files guards — a blocked
copy leaves a *stale* app there that you then run by mistake. Fork patch is `7ff0807`. Small,
self-contained, and upstream owns the Makefile.

## 4. What porting PR 1 actually involves

It is a re-author, not a cherry-pick. Two reasons:

1. **Path moved.** `VoiceInk/Paste/` → `VoiceInk/Infrastructure/SystemIntegration/Paste/`.
2. **Repo-wide reformat.** `f20ac14` rewrapped the file. Diffing upstream's `CursorPaster.swift`
   against our pre-fix base, the logic is identical — every difference is either that reformat or
   our fork-only `.controlV` / `.typeCharacters` cases.

**Take from `344bbf8`, adapted to upstream's formatting:**

- the file-private `OneShotResolver`
- `clipboardSnapshotQueue` + `clipboardSnapshotTimeout`
- `snapshotClipboard(timeout:)` — off-main, raced against 2s
- `savedContents` becoming `ClipboardSnapshot?`, and the restore skipped when it is `nil`

That last one is the subtle part and worth calling out explicitly in the PR description: a
timed-out snapshot must not be restored. `scheduleClipboardRestore` runs `clearContents()`
unconditionally, so restoring from a snapshot you failed to take **wipes the user's clipboard**.
Keying `transient:`/`sessionID:` off whether a restore will actually happen falls out of the same
change.

**Leave out of the PR:**

- the `typeCharacters` early return — upstream's `PasteMethod` has only `.standard` and
  `.appleScript`; `.controlV` / `.typeCharacters` are fork-only
- `postPasteCommand(_:using:)` — upstream's takes no argument; the fork changed it to stop the
  skip decision and the paste from disagreeing. Not needed without the skip.

Keep `OneShotResolver` file-private rather than sharing it with the enhancement-service copy.
Sharing couples PR 1 to PR 2, turning a one-file review into a two-patch negotiation. Deduplicate
only if both land.

## 5. Before opening anything

`CONTRIBUTING.md` says in bold that **pull requests are not accepted**. That text was last touched
2026-05-26 and is stale in practice — external PRs merged 2026-07-24 (#835) and 2026-08-02 (#854,
#855), all small single-purpose fixes. But the stated policy gives a maintainer cover to close a
cold PR unread, so **open the issue with the log trace first** and get a signal before spending
the porting effort.
