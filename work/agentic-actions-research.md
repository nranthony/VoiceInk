# Research: agentic actions from VoiceInk (voice → Claude Code → ClickUp)

**Status:** research complete, nothing implemented
**Created:** 2026-08-11
**Fork base:** upstream v1.79 (`0df2a9a`), 305 commits behind `upstream/main` (`3626442`)
**Related:** [upstream-v2.1-upgrade.md](upstream-v2.1-upgrade.md) — this work depends on that upgrade landing

## Goal being evaluated

Speak into VoiceInk, have the utterance routed by hotkey / modifier / spoken trigger word to a
particular *agent* rather than to the cursor, have that agent run Claude Code inside a local
codebase, connect to ClickUp over MCP, and create the task in the most appropriate list —
returning some confirmation without hijacking the user's focus.

---

## 1. Verdict

**Feasible, and most of the mechanism already exists upstream.** This is not a "bolt an agent onto
a dictation app" project; it is "wire two existing extension points together and fix the places
where their assumptions don't match a 30-second agent run."

Three findings drive everything below:

1. **v1.79 (what we have) already ships a Claude Code integration.** `LocalCLIService` is an AI
   provider that shells out, and one of its four built-in templates is literally `claude -p`.
2. **v2.x (upstream) added the missing half**: a per-Mode `outputMode` of `.customCommand` that
   runs arbitrary shell with the transcript, *instead of* pasting.
3. **The two compose.** Enhancement runs before delivery regardless of output mode, so an LLM can
   structure the utterance and the shell command can deliver the result. That composition is the
   architecture, and neither upstream nor any fork appears to have exploited it.

The blockers are all small and known (§5). None require rearchitecting.

---

## 2. What exists in the fork today (v1.79)

### 2.1 `LocalCLIService` — Claude Code is already a supported provider

`VoiceInk/Services/AIEnhancement/LocalCLIService.swift` runs `/bin/zsh -lc <template>` as the AI
enhancement backend, selected via `AIProvider.localCLI` (`AIService.swift:18`, dispatched at
`AIService.swift:447`).

Four shipped templates (`LocalCLIService.swift:20-31`):

| Template | Command | Tools |
|---|---|---|
| `pi` | `pi -ne -ns -p --no-tools ...` | explicitly **off** |
| `claude` | `claude -p "$VOICEINK_FULL_PROMPT"` | **not disabled** |
| `codex` | `codex exec --skip-git-repo-check ...` | sandboxed |
| `copilot` | `copilot -p ... --available-tools=__none__` | explicitly **off** |

The `claude` template is the only one that does not disable tool use. Whether that is deliberate
or an oversight, it is the seam we want.

Mechanics worth knowing:

- Prompt is passed **both** as `$VOICEINK_FULL_PROMPT` (plus `$VOICEINK_SYSTEM_PROMPT` /
  `$VOICEINK_USER_PROMPT`) **and** written to stdin (`:126-148`).
- `PATH` is discovered by running `zsh -ilc 'print -r -- $PATH'` once and caching it
  (`:207-258`) — so Homebrew / nvm / volta installs of `claude` resolve correctly.
- Timeout: `localCLITimeoutSeconds`, default **45s**, clamped to a minimum of 5s (`:38`, `:54-63`).
  Configurable in the UI (`APIKeyManagementView.swift:200`).
- On timeout it calls `process.terminate()` on the top process only — no process-tree reap.

**Limitation that matters:** the command template is a single global `UserDefaults` key
(`localCLICommandTemplate`, `:35`). It is *not* per-Mode. Modes differentiate by
`selectedPrompt` / `selectedAIProvider` / `selectedAIModel` (`PowerModeConfig.swift:37-38`), so
today you get **one agent binary, many prompts** — not many agents.

**Second limitation:** it's an *enhancement* provider, so whatever the agent prints lands in the
paste buffer and gets typed at the cursor (`TranscriptionPipeline.swift:146` → `:227`). Side
effects happen, but so does an unwanted paste.

### 2.2 Routing surface already present

| Mechanism | Where | Notes |
|---|---|---|
| Per-Mode hotkey | `ShortcutAction.powerMode(UUID)` (`ShortcutAction.swift:13`) | arbitrary modifier combos, so ⌥⌘T vs ⇧⌥⌘T = two different agents |
| Mode picker while recording | `ShortcutAction.miniRecorderPowerMode(Int)` (`:16`) | press 1–9 mid-utterance to redirect |
| Per-Mode AI provider / model / prompt | `PowerModeConfig.swift:37-38` | |
| Screen / selection / clipboard context | `ScreenCaptureService`, `SelectedTextService` | useful for "make a task about *this*" |

So the "different button presses or modifiers" part of the goal is **already solved** and needs no
new code — only new Modes.

---

## 3. What upstream v2.x adds — the decisive piece

### 3.1 `ModeOutputMode`

`upstream/main:VoiceInk/Modes/ModeConfig.swift:23-49`:

```swift
enum ModeOutputMode: String, Codable, CaseIterable {
    case paste          // classic dictation
    case respond        // answer shown in the Assistant panel, nothing pasted
    case customCommand  // run arbitrary shell, per Mode
}
```

with `var customCommand: ModeCustomCommand?` on `ModeConfig` (`:87`) — a per-Mode command string,
edited in a monospaced `TextEditor` with a template menu
(`ModeConfigFormView.swift:630`, `customCommandControls`).

Upstream's own help text in that view states the contract plainly:

> "Runs locally with your user permissions. The final transcript is sent on stdin and exposed as
> VOICEINK_TRANSCRIPT."

### 3.2 `CustomCommandDeliveryRunner`

`upstream/main:VoiceInk/Transcription/Engine/CustomCommandDeliveryRunner.swift`

- `/bin/zsh -lc <command>`, transcript on stdin **and** in `$VOICEINK_TRANSCRIPT`.
- Environment built by `ShellCommandEnvironment.commandEnvironment` (see §5.2 — this is a trap).
- Non-blocking pipe collectors (`PipeOutputCollector`) so a chatty command can't deadlock.
- On timeout: walks the **whole process tree** via `pgrep -P`, SIGTERM, waits 2s, then SIGKILL
  (`terminate`, `processTreeTargets`). This is why a naïvely backgrounded child is unsafe if the
  parent is still alive at the deadline.

### 3.3 Delivery path

`upstream/main:VoiceInk/Transcription/Engine/TranscriptionDelivery.swift:43`

```
deliver() → outputMode == .customCommand
          → deliverCustomCommand()
          → play stop sound, dismiss recorder UI
          → detached Task { CustomCommandDeliveryRunner.run(..., timeout: 10) }
```

The recorder dismisses **before** the command runs — genuinely fire-and-forget from the user's
point of view. Nothing is pasted. `stdout`/`stderr` go only to `os_log`
(`runCustomCommand`, `:120-140`).

### 3.4 Shipped templates prove the intent

`upstream/main:VoiceInk/Modes/CustomCommandTemplate.swift` — five examples: `pasteAndPressTab`,
`lowercaseAndPaste`, `removeTrailingPeriodAndPaste`, `appendToJournal`, `searchWeb`.

All trivial (pbcopy + osascript, append to a markdown file, URL-encode and `open`). Upstream built
the mechanism and stopped at macros. **The agentic use is unclaimed territory.**

### 3.5 Trigger words — voice-selected routing

`upstream/main:VoiceInk/Modes/ModeTriggerWordDetectionService.swift` plus
`ModeConfig.triggerWords: [String]`.

`detect(in:configurations:)` matches trigger words **longest-first**, then by Mode order, then word
order; `detectAndStrip` removes leading *and* trailing occurrences and returns the cleaned text.

So *"**task**, fix the RDP paste latency by Friday"* selects the task Mode and hands the agent
`fix the RDP paste latency by Friday` — no hotkey, no modifier. This is the most natural UX for
the stated goal and it needs zero new code once v2.1 lands.

### 3.6 The composition nobody has used

`upstream/main:VoiceInk/Transcription/Engine/TranscriptionPipeline.swift:128-190`:

`outputMode` gates only `.respond` (`:156`). AI enhancement runs on its own conditions
(`isAIEnhancementEnabled`, configured provider, short-utterance skip). Therefore:

> **A `.customCommand` Mode with AI enhancement enabled receives the *enhanced* text in
> `$VOICEINK_TRANSCRIPT`.**

That is the whole design. The LLM does the understanding — turn rambling speech into a structured
task — and the shell command does the delivery. Two clean layers, both already built:

```
speech → whisper/parakeet → [enhancement: structure it]  → [customCommand: deliver it]
                             ↑ prompt, per Mode             ↑ shell, per Mode
                             can be a cloud model,          detached; can invoke
                             Ollama, or Local CLI           claude -p with MCP
```

Two sub-variants, and the choice matters:

- **Thin enhancement, fat command.** Enhancement emits strict JSON (`{"title":…,"list":…,"due":…}`);
  the command is a `jq` + `curl` to the ClickUp REST API. Fast, deterministic, no agent needed.
  ClickUp list-routing logic lives in the prompt.
- **No enhancement, fat command.** Raw transcript goes to a detached `claude -p` run that decides
  everything with MCP tools in hand. Slower, far more capable (can read the repo, check existing
  tasks, dedupe, attach context), non-deterministic.

Recommendation: **build the second, keep the first as the fallback for when latency matters.**
The whole point of the exercise is agent judgement about "the most appropriate list."

---

## 4. Claude ecosystem inventory

### 4.1 Headless Claude Code — the interface

| Flag | Relevance here |
|---|---|
| `-p` / `--print` | single batch invocation, no REPL |
| `--allowedTools` | **required.** In `-p` mode nothing can answer a permission prompt, so un-allowed tool calls just fail. Prefix matching (`mcp__clickup__*`). |
| `--mcp-config <file>` | attach the ClickUp server without touching global config |
| `--permission-mode` | prefer scoping via `--allowedTools`; avoid `--dangerously-skip-permissions` for anything touching a live workspace |
| `--output-format json` | machine-readable result for the wrapper to parse into a notification |
| `--bare` | skips auto-discovery of hooks/skills/MCP/CLAUDE.md — faster and reproducible, but **also skips the routing Skill**, so do *not* use it if list-routing knowledge lives in a Skill |

### 4.2 Claude Agent SDK — if cold start hurts

TS and Python. Spawns the bundled CLI as a subprocess, adds sessions, subagents, and **in-process
MCP tools** (custom tools with no subprocess or network hop).

Relevant because it turns the VoiceInk side into a one-liner: a long-lived local daemon, and the
custom command becomes `curl -s localhost:PORT/task --data-binary @-`, which returns in
milliseconds and fits the 10s budget with room to spare. It also amortises startup and lets the
agent keep workspace context (list IDs, recent tasks) warm between utterances.

This is the "custom code base" from the original framing, and it is the endgame — but it is not
needed for a first working version.

### 4.3 ClickUp MCP options

| Option | Transport | Notes |
|---|---|---|
| **Official** `https://mcp.clickup.com/mcp` | HTTP, OAuth | first-party, ~40 tools (tasks, docs, chat, time tracking), public beta, all plans. `claude mcp add --transport http clickup https://mcp.clickup.com/mcp` then `/mcp` to auth. |
| `taazkareem/clickup-mcp-server` | stdio (npm) | community, mature, multi-workspace, OAuth 2.1 |
| claude.ai ClickUp connector | — | already attached to Claude Code sessions on this machine; **use it to prototype the routing logic interactively** before freezing it into a script |

Start with the official remote server. Fall back to the npm one if OAuth-from-subprocess proves
awkward (§5.2).

### 4.4 Where the routing knowledge should live

"Which list does a task belong in" is stable workspace knowledge, not per-utterance context. Put it
in a **Skill** or the agent repo's `CLAUDE.md`, not in the VoiceInk enhancement prompt — the
VoiceInk prompt field is a poor editor and the knowledge needs versioning. Note the interaction
with `--bare` in §4.1.

### 4.5 Getting a result back to the user

VoiceInk's `NotificationManager` is **not reachable** from the subprocess, and custom-command
stdout is swallowed into `os_log`. The wrapper must report for itself:

- `osascript -e 'display notification "…" with title "VoiceInk"'` — zero dependencies
- `terminal-notifier` — clickable, can deep-link to the ClickUp task URL (preferred)
- append to `~/Documents/VoiceInk/journal.md`, mirroring upstream's `appendToJournal` template

---

## 5. Hard constraints (design around these)

### 5.1 The 10-second custom-command timeout

`timeout: 10` is **hardcoded** in `TranscriptionDelivery.runCustomCommand`. A `claude -p` run with
MCP auth and a few tool calls is 15–60s+. It will be killed, and the process-tree reap (§3.2) means
a plain background child is *not* automatically safe.

**Mitigation — detach and exit immediately** so the runner's `terminationHandler` fires long before
the deadline and the kill path is never entered:

```sh
printf '%s' "$VOICEINK_TRANSCRIPT" > "$TMPDIR/voiceink-task-$$.txt"
nohup "$HOME/bin/voiceink-agent" task "$TMPDIR/voiceink-task-$$.txt" >/dev/null 2>&1 &
disown
```

`$TMPDIR` is one of the inherited variables (§5.2), so it is safe to use. Passing the transcript via
file rather than argv avoids quoting hazards with apostrophes and newlines in speech.

Longer term, a fork-local change making the timeout configurable (mirroring `localCLITimeoutSeconds`)
is a small, self-contained patch — and a plausible upstream PR.

### 5.2 The environment is an allowlist, not an inheritance

`upstream/main:VoiceInk/Services/ShellCommandEnvironment.swift` passes **only**:

```
HOME, USER, LOGNAME, SHELL, TMPDIR, LANG, LC_ALL, LC_CTYPE   (+ PATH, discovered)
```

Everything else from the login shell is dropped. So:

- `ANTHROPIC_API_KEY` and friends **are not present**. Claude Code must authenticate from its own
  config under `$HOME/.claude`, or the wrapper must source credentials itself.
- Same for any ClickUp token if using the REST fallback path.
- Verify OAuth token refresh actually works from this stripped environment **before** trusting it —
  this is the single most likely cause of a silent failure, and failures are silent by design
  (stdout → `os_log` only).

Note `PATH` discovery here is more robust than `LocalCLIService`'s: it tries `zsh -lc` first, then
`-ilc`, and caches (`preferredPATH`).

### 5.3 Silent failure surface

Custom command failures produce a `logger.error` and nothing else — no banner, no history entry.
Debugging line:

```bash
log show --predicate 'subsystem CONTAINS "voiceink"' --last 1h --info | grep -i "custom command"
```

The wrapper should therefore own its own error reporting (notification on failure, not just on
success) and log to its own file.

### 5.4 Local CLI template is global, not per-Mode

Already covered in §2.1. Consequence: Tier 0 (§6) can only have **one** agent command across all
Modes. Per-Mode agents require the v2.x `customCommand` field.

### 5.5 Summary table

| Constraint | Impact | Mitigation |
|---|---|---|
| 10s custom-command timeout | agent run gets killed | detach + exit immediately; later, make configurable |
| Process-tree SIGTERM/SIGKILL on timeout | naïve `&` child dies too | exit fast so the timeout path never runs; `nohup` + `disown` |
| Allowlisted env (no API keys) | auth fails silently | rely on `~/.claude` config; test from stripped env |
| stdout → `os_log` only | no feedback, silent failures | wrapper sends its own notification, success *and* failure |
| Global CLI template (v1.79) | one agent for all Modes | wait for v2.x `customCommand` |
| Enhancement UI blocks up to 45s (Local CLI path) | recorder stuck in "enhancing" | prefer `customCommand` over Local CLI for agent work |

---

## 6. Implementation ladder

### Tier 0 — today, on v1.79, no Swift changes

Prove the concept end-to-end before committing to the upgrade.

- Power Mode "Task", AI provider = **Local CLI**, timeout 45s.
- Command template:
  ```
  claude -p --mcp-config "$HOME/.voiceink/mcp.json" \
            --allowedTools "mcp__clickup__*" \
            "$VOICEINK_FULL_PROMPT"
  ```
- Prompt: "Convert this into a ClickUp task, choose the most appropriate list, create it, and reply
  with exactly one confirmation line."
- Bind ⌥⌘T to the Mode.

The confirmation line gets pasted at the cursor, which is acceptable and arguably nice.

**Known rough edges:** recorder sits in "enhancing" for the whole run; only one agent command
globally; verify the actual MCP tool prefix (`--output-format json`, or `/mcp` in an interactive
session) since `--allowedTools` is prefix-matched and a wrong prefix fails silently.

### Tier 1 — after the v2.1 upgrade

The real design.

1. Mode "Task": `outputMode = .customCommand`, trigger word `task`, hotkey ⌥⌘T.
2. Enhancement **on**, with a prompt that cleans and structures the utterance (but does not attempt
   the ClickUp routing — leave that to the agent, which has tools).
3. Custom command = the detach stub from §5.1.
4. `~/bin/voiceink-agent` — the wrapper, in its own git repo:
   - reads the transcript file, deletes it
   - `claude -p --mcp-config … --allowedTools "mcp__clickup__*" --output-format json`
   - parses the result, fires `terminal-notifier` with the task URL
   - logs to `~/Library/Logs/voiceink-agent.log`
   - **routes to a "Voice Inbox" list by default** (§7)
5. Additional Modes reuse the same wrapper with a different first argument: `bug`, `note`,
   `calendar`, `research`. Each gets its own trigger word and its own hotkey.

### Tier 2 — fork changes worth making

In rough priority order:

1. **Configurable custom-command timeout** — mirror `localCLITimeoutSeconds`; small, isolated,
   plausible upstream PR.
2. **Surface command results** — route stdout/exit status into `NotificationManager`, or into the
   Assistant panel (`.respond` already renders text there; a `.customCommand` result could reuse it).
   Removes the need for `terminal-notifier` entirely.
3. **Background-job status** — a menu-bar indicator for in-flight agent runs, with cancel. The
   process-tree reap machinery in `CustomCommandDeliveryRunner` is already the hard part.
4. **Per-Mode Local CLI template** — only if the Local CLI path proves better than `customCommand`
   for synchronous work; otherwise skip.

Items 2 and 3 are where this fork would add something upstream genuinely lacks.

---

## 7. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Mis-transcription creates garbage in a live workspace | **high** | route everything to a "Voice Inbox" list; triage manually. Do not let the agent write to sprints directly until confidence is earned. |
| Agent creates duplicates from repeated utterances | medium | wrapper passes recent-task context; agent instructed to search before creating |
| OAuth token refresh fails in the stripped env | medium | test explicitly (§5.2); notify on failure |
| Silent failures go unnoticed for days | medium | wrapper notifies on failure, not just success |
| Accidental hotkey → unwanted task | low | trigger-word routing is harder to fire by accident than a hotkey |
| Spawning processes vs. entitlements | none | the app already does exactly this in `LocalCLIService`; `make local` entitlements are unaffected |
| Cost of a `claude -p` run per utterance | low | real but small; the Agent SDK daemon (§4.2) amortises it |

The first row is the one to design for. A confirmation step is worth more than it costs — the
Spokenly pattern (§8) of the agent asking back by voice is the elegant version, but a triage list is
the cheap version and it works today.

---

## 8. Prior art

**No VoiceInk fork appears to be doing this.** Searched GitHub and the wider web; the ~670 forks are
not visibly pursuing agent output. Upstream itself is drifting toward it (`customCommand`, Local
CLI, Assistant) but has shipped only macro-grade templates.

The community has built the **inverse** — voice as input *to* Claude Code:

| Project | Pattern |
|---|---|
| Claude Code `/voice` | built-in dictation mode |
| `johnmatthewtennant/mcp-voice-hooks` | MCP server, trigger-word gating, browser UI |
| `lee-geyer/claude-code-voice-agent` | wake word ("Athena") → `claude` CLI → TTS reply |
| Aqua Voice / Willow / EmberType | system-wide push-to-talk dictation into the terminal |
| **Spokenly** | exposes `ask_user_dictation` as an MCP tool — **the agent asks *you* by voice mid-task** |

The Spokenly inversion is the one idea worth stealing: it solves the confirmation problem (§7)
without breaking the hands-free flow.

**Conclusion: the direction is unclaimed.** Every primitive exists; nobody has assembled them.

---

## 9. Open questions

- [ ] Does ClickUp MCP OAuth refresh survive the stripped environment of §5.2, or does it need an
      interactive session to have run recently?
- [ ] What is the actual MCP tool-name prefix for the official ClickUp server? Needed for
      `--allowedTools`. Check with `--output-format json` on a probe run.
- [ ] Cold-start latency of `claude -p` with an HTTP MCP server attached — measure. If >30s,
      Tier 1 wants the Agent SDK daemon (§4.2) sooner rather than later.
- [ ] Is `.respond` + Assistant a better fit than `.customCommand` for the *confirmation* half?
      It renders text in-panel without pasting — possibly the cleanest feedback channel, and it
      needs no `terminal-notifier`.
- [ ] Does enhancement-then-command double the latency in a way that matters, or does the detach
      make it invisible? (Enhancement is synchronous and blocks the recorder; the command is not.)
- [ ] Should the agent repo live in this fork, or as a separate `voiceink-agent` repo? Leaning
      separate — different language, different release cadence, no reason to couple it.

---

## 10. Suggested sequence

1. Land [upstream-v2.1-upgrade.md](upstream-v2.1-upgrade.md) first. Tier 1 is blocked on it, and
   Tier 0 is throwaway.
2. In parallel (unblocked): prototype the ClickUp routing logic interactively using the claude.ai
   ClickUp connector — work out what "most appropriate list" actually means for this workspace, and
   write it down as a Skill.
3. Answer the two auth/latency questions in §9 with a throwaway `claude -p` probe from a stripped
   environment (`env -i HOME=$HOME PATH=… claude -p …`).
4. Tier 0 on the current build as a one-evening proof, if the v2.1 upgrade slips.
5. Tier 1 proper: wrapper repo first, then the Mode config, then trigger words.
6. Tier 2 items 1 and 2 once it's in daily use and the annoyances are known rather than guessed.

## 11. Verification checklist (for whenever Tier 1 lands)

- [ ] `claude -p` authenticates from the stripped `ShellCommandEnvironment` allowlist
- [ ] ClickUp MCP tools resolve and are permitted under `--allowedTools`
- [ ] Custom command returns in <1s (detached) — confirm the 10s timeout path never fires:
      `log show --predicate 'subsystem CONTAINS "voiceink"' --last 1h --info | grep -i "custom command"`
- [ ] Recorder dismisses immediately; no paste occurs in `.customCommand` mode
- [ ] Transcript with apostrophes, quotes, and newlines survives the file hand-off intact
- [ ] Trigger word "task" routes correctly and is stripped from the payload
- [ ] Trigger words for two Modes with a shared prefix resolve longest-first as expected
- [ ] Success notification fires with a working ClickUp task URL
- [ ] **Failure notification fires** — test by revoking the ClickUp token
- [ ] Nothing is created outside the Voice Inbox list
- [ ] Enhancement-on and enhancement-off both deliver sane `$VOICEINK_TRANSCRIPT`

---

## Key file references

Fork (v1.79):

| File | What |
|---|---|
| `VoiceInk/Services/AIEnhancement/LocalCLIService.swift:20-31` | CLI templates incl. `claude -p` |
| `VoiceInk/Services/AIEnhancement/LocalCLIService.swift:111-190` | process spawn, env, timeout |
| `VoiceInk/Services/AIEnhancement/AIService.swift:18,447` | `.localCLI` provider case + dispatch |
| `VoiceInk/PowerMode/PowerModeConfig.swift:37-38` | per-Mode provider / model |
| `VoiceInk/Shortcuts/ShortcutAction.swift:13,16` | per-Mode hotkey, in-recorder Mode picker |
| `VoiceInk/Transcription/Engine/TranscriptionPipeline.swift:146,227` | enhance → paste |

Upstream (`git show upstream/main:<path>`):

| File | What |
|---|---|
| `VoiceInk/Modes/ModeConfig.swift:23-49,87` | `ModeOutputMode`, `customCommand` field |
| `VoiceInk/Modes/CustomCommandTemplate.swift` | five shipped templates |
| `VoiceInk/Modes/ModeConfigFormView.swift:630` | custom-command editor UI |
| `VoiceInk/Modes/ModeTriggerWordDetectionService.swift` | trigger-word routing + strip |
| `VoiceInk/Transcription/Engine/TranscriptionDelivery.swift:43,105` | delivery branch, `timeout: 10` |
| `VoiceInk/Transcription/Engine/CustomCommandDeliveryRunner.swift` | spawn, pipes, process-tree reap |
| `VoiceInk/Transcription/Engine/TranscriptionPipeline.swift:128-190` | enhancement independent of output mode |
| `VoiceInk/Services/ShellCommandEnvironment.swift` | env allowlist, PATH discovery |

External:

- Claude Code headless — https://code.claude.com/docs/en/headless
- Claude Code MCP — https://code.claude.com/docs/en/mcp
- ClickUp MCP (official) — https://developer.clickup.com/docs/connect-an-ai-assistant-to-clickups-mcp-server
- `taazkareem/clickup-mcp-server` — https://github.com/taazkareem/clickup-mcp-server
- `johnmatthewtennant/mcp-voice-hooks` — https://github.com/johnmatthewtennant/mcp-voice-hooks
- `lee-geyer/claude-code-voice-agent` — https://github.com/lee-geyer/claude-code-voice-agent
