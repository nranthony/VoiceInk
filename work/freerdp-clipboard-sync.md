# Task: FreeRDP (sdl-freerdp) paste, clipboard restore, and build follow-ups

**Status:** open
**Created:** 2026-10-22
**Area:** `VoiceInk/Infrastructure/SystemIntegration/Paste/`, `Makefile`, `LocalBuild.xcconfig`
**Type:** fork-local improvement

Branch: `feature/freerdp-clipboard-sync`. Read this before iterating on paste into the Ubuntu
FreeRDP session, or before rebuilding.

---

## 1. Where it stands (2026-10-22)

Paste into Homebrew `sdl-freerdp` → Ubuntu works, and the clipboard you had before dictating comes
back afterwards. In daily use since 2026-10-18 with no real concerns.

What the branch does, in commit order:

| Commit | What |
|---|---|
| `9316bba` | Paste works at all: focus bounce to Finder and back so SDL reads the Mac clipboard; left-Cmd device bit on the synthetic Cmd+V |
| `c565ad5` | Restore reaches Ubuntu: strip FreeRDP's `x-special/freerdp-clipboard-update-<uuid>` marker from the restored snapshot; bounce focus again after the restore, only once the keyboard is idle |
| `18f7c2c` | `make local` installs to `LOCAL_APP_DEST` (default `~/Applications`) and fails loudly if the install is blocked |

### Why the restore needed two fixes

1. SDL only checks the Mac clipboard when its window becomes key, so the restored contents never
   reached Ubuntu without a second focus bounce.
2. The snapshot included FreeRDP's own ownership marker. FreeRDP (`sdl_clip.cpp` `handleEvent` /
   `contains()`) ignores any local clipboard carrying it, so even a bounce announced nothing.
   SDL exposes MIME types as dynamic UTIs; `UTType(rawValue).preferredMIMEType` decodes them.

### Why the restore bounce waits for an idle keyboard

SDL releases every key when its window loses focus and does not see a modifier still held when
focus returns. A Cmd+V pressed across the bounce reached Ubuntu as a bare `v` (found in test R7).
The bounce now waits for no Cmd/Ctrl/Opt/Shift held and 0.5 s with no key or modifier event, up to
10 s; past that it is left for SDL to pick up on the client's next focus change.

## 2. Current settings on this Mac

`defaults read com.prakashjoshipax.VoiceInk | grep -iE 'rdp|clipboardRestore'`

| Key | Set to | Default | Clamp |
|---|---|---|---|
| `rdpFocusAwayDelay` | 0.05 | 0.10 | 0–3 s |
| `rdpClipboardSyncDelay` | 0.25 | 0.40 | 0–3 s |
| `rdpMinimumClipboardRestoreDelay` | 1.0 | 2.0 | 0–3 s |
| `clipboardRestoreDelay` (Settings → Restore Delay) | 1.0 | 2.0 | 0.25–5 s |
| `rdpFocusTarget` | unset (Finder) | `finder` | any running bundle ID |

The FreeRDP restore delay is `max(clipboardRestoreDelay, rdpMinimumClipboardRestoreDelay)`, capped
at 5 s. Fixed in code: 1.0 s focus-change timeout, 0.5 s keyboard-idle interval, 10 s idle timeout.

Tuning symptoms: the dictation pastes stale text → raise `rdpClipboardSyncDelay` (+0.05);
Ctrl+V right after gives the dictation or nothing → raise `rdpMinimumClipboardRestoreDelay` to 1.5.

## 3. Backlog

Roughly in priority order.

### 3.1 Images copied in Ubuntu are not restored (R8) — open, not yet diagnosed

Observed: copy an image in Ubuntu, dictate, paste → the image does not come back. Text does.
Unknown whether FreeRDP ever puts the image on the Mac clipboard, or VoiceInk loses it at
snapshot time (`snapshotClipboard` reads each type; a lazy FreeRDP read can come back empty).

Diagnose in this order:

1. Without VoiceInk: copy an image in Ubuntu, then Preview → File → New from Clipboard. If that
   fails it is FreeRDP's cliprdr, not VoiceInk; stop there.
2. Copy an image in Ubuntu, dump the Mac clipboard: every type, its MIME type, and its byte count
   (or `NO DATA`). The 2026-10-18 session built a throwaway tool for this in the session
   scratchpad, which will be gone; rebuild it from this sketch:

   ```swift
   import AppKit
   import UniformTypeIdentifiers
   for (i, item) in (NSPasteboard.general.pasteboardItems ?? []).enumerated() {
       for type in item.types {
           let mime = UTType(type.rawValue)?.preferredMIMEType ?? "-"
           let size = item.data(forType: type).map { "\($0.count) B" } ?? "NO DATA"
           print("item \(i)  \(type.rawValue.prefix(40))  mime=\(mime)  \(size)")
       }
   }
   ```

   Build with `swiftc -module-cache-path "$TMPDIR/mc" pbdump.swift -o pbdump` (the module cache
   flag is needed inside Claude's sandbox).
3. Copy the image again, dictate into FreeRDP, wait ~2 s, dump again: what did the restore write?

If `image/*` types read as `NO DATA` in step 2, the fix is on the snapshot side (retry, or read
the image types first). If they have data in 2 but not 3, it is the restore or the marker filter.

### 3.2 Stable code signing so rebuilds keep permissions — open

`make local` finds no signing identity, falls back to ad-hoc, and the designated requirement is a
cdhash, so every rebuild loses Accessibility and Microphone (re-grant: remove and re-add in
Accessibility, restart, toggle the hotkey off Fn and back for the mic prompt).

Fix, no Apple Developer account needed: Keychain Access → Certificate Assistant → Create a
Certificate, name `VoiceInk Local`, Self Signed Root, Code Signing; set its Trust → Code Signing
to Always Trust; confirm with `security find-identity -v -p codesigning`. Then build with
`LOCAL_CODESIGN_IDENTITY="VoiceInk Local" make local`, or put
`LOCAL_CODESIGN_IDENTITY := VoiceInk Local` in `Makefile.local`. One more grant, then stable.
Note the Makefile only auto-picks `Apple Development:` identities, so the variable is required.

### 3.3 Fork version label in About — proposed

About shows upstream's `2.21 (221)`, which cannot tell a stale build from a fresh one. Proposal:
in `LocalBuild.xcconfig`, `MARKETING_VERSION = $(inherited)-fork.$(LOCAL_GIT_HASH)`, with the
Makefile passing the short hash plus `-dirty` for uncommitted changes. Keep `CFBundleVersion`
numeric. The version string is only displayed or stored as metadata (About, changelog header,
diagnostics, backup/dictionary export); nothing compares versions, and local builds have no
Sparkle updates. Verify `$(inherited)` resolves when the xcconfig is passed via `-xcconfig`.

### 3.4 Residual bare-`v` window — watch

Pressing Cmd during the ~0.3 s restore bounce itself can still drop the modifier. Not seen in use.
If it shows up: shorten the bounce (`rdpFocusAwayDelay`, `rdpClipboardSyncDelay`), or after
refocusing, re-assert a still-held Cmd to the client with a synthetic `flagsChanged` event.

### 3.5 Pasteboard snapshot can block on a lazy owner — carry from earlier work

`snapshotClipboard` reads every type synchronously on the main actor. With FreeRDP as the owner
each read becomes a request to the Ubuntu server (the `No synthesizer for format …` lines in the
FreeRDP console are those reads failing for X11 formats such as `compound_text`). The fork's
pasteboard-timeout fix (see [upstream-pasteboard-prs](upstream-pasteboard-prs.md), `344bbf8`)
has not been ported onto the v2.x layout; until it is, a stalled owner can freeze the paste path.

### 3.6 Detection covers Homebrew FreeRDP only — by design, revisit if needed

`RemoteDesktopClipboardSync.frontmostClient()` matches executables under
`/opt/homebrew/Cellar/freerdp/…/bin/sdl-freerdp`. A MacPorts or source build, a renamed binary, or
the X11 `xfreerdp` client is not detected and gets the plain paste path. Windows App / Microsoft
Remote Desktop are deliberately excluded (different clipboard model).

### 3.7 Housekeeping

- Delete `~/Downloads/VoiceInk.app` (old build; Bitdefender will prompt — Allow). The live app is
  `~/Applications/VoiceInk.app`.
- Push `feature/freerdp-clipboard-sync` to `origin` when ready (not pushed as of 2026-10-22).
- `BUILDING.md` is upstream's and still says `~/Downloads`; left alone to avoid merge conflicts.
- Upstream PR candidate: the left-Cmd device bit (`NX_DEVICELCMDKEYMASK`) in
  `CursorPaster.pasteFromClipboard` is small, generic, and fixes any SDL-based target. The
  focus-bounce sync is too FreeRDP-specific to offer upstream.

## 4. Regression checklist

Run after any change to the paste path or an upstream merge. Settings: Keep Clipboard Content on.

FreeRDP (Ubuntu):

| # | Steps | Expect |
|---|---|---|
| R1 | Copy text in Ubuntu, dictate into a text field, Ctrl+V | Dictation pastes; Ctrl+V gives the original |
| R2 | Same in a Ubuntu terminal | Same |
| R3 | Copy on the Mac, switch to FreeRDP, dictate, Ctrl+V | Dictation pastes; Ctrl+V gives the Mac text |
| R4 | Dictate, then type within a second | No dropped keystrokes |
| R5 | Dictate, switch to a Mac app within a second | No bounce; original is there on return |
| R6 | Two dictations back to back | Both paste in order; original restored after the second |
| R7 | Dictate, then Cmd+V immediately and repeatedly, ×10 | Never a bare `v` (first ~1 s gives the dictation) |
| R8 | Copy an image in Ubuntu, dictate, paste | **Currently fails** — see 3.1 |

Mac apps:

| # | Steps | Expect |
|---|---|---|
| M1 | TextEdit/Notes: copy, dictate, Cmd+V | Original back after ~1 s; no focus bounce |
| M2 | Same in Terminal / iTerm / VS Code | Same |
| M3 | Copy an image or rich text on the Mac, dictate, paste | Restored intact |
| M4 | Keep Clipboard Content off | Dictation stays on the clipboard |
| V1 | Windows VM / Microsoft Remote Desktop | Unchanged behaviour |

Logs while testing:

```bash
log stream --predicate 'subsystem == "com.prakashjoshipax.voiceink"' --style compact \
  | grep -E 'RDP|Paste id|Clipboard rest'
```

FreeRDP pastes show a `refocused client` line for the paste and another after `Clipboard
restored`; Mac apps show no `RDP` lines. Any `could not move focus away`, `could not refocus`,
`focus moved before paste`, or `keyboard busy` line is worth noting with the test it came from.
