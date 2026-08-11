# work/

Working notes for this fork: upgrade plans, open work items, and anything worth remembering
between sessions. Not part of the app; safe to ignore when building.

## Convention

One file per item, kebab-case, named for the thing rather than the date. Each starts with a
short frontmatter block:

```
**Status:** open | in progress | done | superseded
**Created:** YYYY-MM-DD
**Area:** path or subsystem
**Type:** fork-local improvement | upstream PR candidate | upgrade plan | investigation
```

Prefer appending a dated section to an existing file over rewriting it — the history of how a
problem was understood is usually the useful part.

## Items

| Item | Status | Summary |
|---|---|---|
| [upstream-v2.1-upgrade](upstream-v2.1-upgrade.md) | open | Rebasing the fork onto upstream v2.1: PowerMode→Modes rename, conflict map, migration traps, and which fork patches must be carried forward |
| [shortcut-permission-diagnostics](shortcut-permission-diagnostics.md) | open | Missing Input Monitoring kills the global hotkey with no log output; add diagnostics and retry-on-activate |

## Fork patch categories

Worth keeping in mind when planning any upstream merge:

- **Patches upstream will absorb** — anything matching an upstream concept (flag names, per-Mode
  settings). Mirror upstream's naming and the merge does the work.
- **Patches upstream has no concept of** — the clipboard capture gating, the pasteboard timeout,
  `ConcealedType` handling, permission diagnostics. These are permanent fork carry and must be
  re-applied on every rebase. Each is a candidate PR; landing them upstream is the only way to
  stop re-applying them.
