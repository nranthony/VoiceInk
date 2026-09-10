# work/

Working notes for this fork: upgrade plans, open work items, and anything worth remembering
between sessions. Not part of the app; safe to ignore when building.

These live on `main` so they survive the branches they describe. They were written on
`feature/paste-shortcuts`, now frozen as `local-release/v1.79`; that branch still carries its own
copy at the state it was frozen in.

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
| [upstream-pasteboard-prs](upstream-pasteboard-prs.md) | open | Sending the pasteboard-timeout fixes upstream: the four unguarded reads still in v2.13, PR order, what to port and what to leave out |
| [upstream-v2.1-upgrade](upstream-v2.1-upgrade.md) | superseded | Started as the v2.1 rebase plan; the v2.13 section at the end is the current one. The v2.1 conflict map is stale — the whole tree was reorganized |
| [shortcut-permission-diagnostics](shortcut-permission-diagnostics.md) | open | Missing Input Monitoring kills the global hotkey with no log output; add diagnostics and retry-on-activate |
| [agentic-actions-research](agentic-actions-research.md) | research complete | Voice → Claude Code → ClickUp: routing surface, upstream `customCommand` seam, constraints, implementation ladder |
| [paste-shortcuts-branch-review](paste-shortcuts-branch-review.md) | open | Security + validity review of the branch (clean / 3 minor fixes) and of the v2.1 plan (claims verified; conflict map + step 6 stale) |

## Fork patch categories

Worth keeping in mind when planning any upstream merge:

- **Patches upstream will absorb** — anything matching an upstream concept (flag names, per-Mode
  settings). Mirror upstream's naming and the merge does the work.
- **Patches upstream has no concept of** — the clipboard capture gating, the pasteboard timeout,
  `ConcealedType` handling, permission diagnostics. These are permanent fork carry and must be
  re-applied on every rebase. Each is a candidate PR; landing them upstream is the only way to
  stop re-applying them.
