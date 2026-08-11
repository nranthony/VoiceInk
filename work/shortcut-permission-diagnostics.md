# Work item: surface missing Input Monitoring instead of failing silently

**Status:** open
**Created:** 2026-08-11
**Area:** `VoiceInk/Shortcuts/ShortcutMonitor.swift`
**Type:** fork-local improvement + upstream PR candidate

## Problem

When the Input Monitoring permission (`kTCCServiceListenEvent`) is missing, the global hotkey
stops working and the app says **nothing at all** — no log line, no notification, no UI hint.
`ShortcutMonitor.installEventTap()` (line 78) opens with:

```swift
guard Self.hasListenEventAccess() else {
    return false          // silent
}
```

`hasListenEventAccess()` (line 125) preflights via `CGPreflightListenEventAccess()` and, once per
process, requests via `CGRequestListenEventAccess()`. The one-shot is guarded by the static
`hasRequestedListenEventAccess` (line 27), so if the permission is not granted at that moment the
tap is never created and is **never retried for the lifetime of the process**.

Net effect: pressing the shortcut does literally nothing, and the logs are empty — the absence of
`RecordingShortcutManager: handleShortcutKeyDown` is the only signal, which requires knowing to
look for a log line that isn't there.

Contrast with the Accessibility path, which behaves correctly: `CursorPaster` logs
`"Accessibility permission is required to paste with simulated key events"` on every guarded
entry point. That one is diagnosable from the logs alone. Input Monitoring is not.

## Why this bites repeatedly here

Local builds are ad-hoc signed (`CODE_SIGN_IDENTITY="-"`, no Team ID), so the TCC requirement
falls back to the cdhash, which changes on **every rebuild**. Each new build is a different app as
far as TCC is concerned, so both Accessibility and Input Monitoring silently lapse. Moving the
install location (`~/Downloads` → `~/Applications`) triggered the same thing.

Encountered 2026-08-11: Accessibility was re-granted and paste recovered, but the hotkey stayed
dead. Diagnosing it needed a source read, because there was no observable output to go on.

## Proposed changes

1. **Log the failure.** In `installEventTap()`, log at `.error` when `hasListenEventAccess()`
   returns false, naming Input Monitoring explicitly and pointing at
   System Settings → Privacy & Security → Input Monitoring. Also worth logging when
   `CGEvent.tapCreate` (line 102) returns nil, which is currently a second silent `return false`.
2. **Re-check when the app is reactivated.** Retry `installEventTap()` on
   `applicationDidBecomeActive` (or on `NSWorkspace` activation) so granting the permission takes
   effect without the user knowing they must quit and relaunch. This means relaxing the one-shot
   `hasRequestedListenEventAccess` — keep the single *request* per launch (avoid prompt spam) but
   allow the *preflight* to be re-evaluated.

Optional third: a user-visible notification via `NotificationManager` when the tap cannot be
installed, matching how other unrecoverable states are surfaced.

## Acceptance criteria

- [ ] With Input Monitoring revoked, launching the app logs a clear `.error` naming the permission
- [ ] `CGEvent.tapCreate` returning nil is logged distinctly from the permission case
- [ ] Granting Input Monitoring while the app is running restores the hotkey without a relaunch
- [ ] Granting does not produce repeated system permission prompts
- [ ] No behaviour change when the permission is already granted

## Related

- The recurring re-grant problem is caused by ad-hoc signing, not by this code. The durable fix is
  a stable self-signed code-signing certificate so the TCC requirement keys on the certificate
  rather than a per-build cdhash. Tracked separately — see [stable-local-code-signing](#) (not yet
  written).
- Carry-forward note: upstream v2.1 has no equivalent diagnostics, so this stays fork-local until
  offered as a PR. Add to the carry-forward list in `upstream-v2.1-upgrade.md` §4 if it lands.
