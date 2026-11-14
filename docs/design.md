# Agent Load: agreed design (v1)

A small native macOS menu bar app that shows machine load broken down by
OpenChamber/opencode **session**, so the question "which session is making the
Mac slow, and can I start another one?" is answered at a glance.

Agreed with the owner on 2026-11-13. The visual reference is `docs/mockup.html`
(v7, layout "A · Folded groups" with harness icons, "option B" chosen 2026-11-14). Match it closely; do not
redesign. The owner reviews the look carefully.

## Menu bar item

- A coloured dot (green / amber / red) followed by the number of session rows in the
  dropdown (every listed session, see below), e.g. `● 3`.
- The dot must really be coloured (not a monochrome template image).

## Status colour and verdict

| Colour | Rule | Headline | Verdict line |
|---|---|---|---|
| Green | memory pressure normal AND 1-min load ≤ cores (8) | Calm | Room for another session |
| Amber | memory pressure "warning" OR load > cores | Busy · memory is tight / Busy · CPU is busy | Wait before starting another session |
| Red | memory pressure "critical" OR load > 2 × cores | Overloaded · … | Too much running: free something up |

- Memory pressure is the primary signal (`kern.memorystatus_vm_pressure_level`:
  1 normal, 2 warning, 4 critical). Load average is second.
- Swap usage never changes the colour by itself (it lingers after a crunch).
- Headline names the reason: memory, CPU, or both.

## Dropdown (top to bottom)

1. Headline with dot, verdict line in grey.
2. Two gauge cards side by side:
   - **CPU**: "7.3 of 8 cores" = 1-minute load average vs core count; bar = load / cores, capped.
   - **Memory**: "13.1 of 16 GB" = memory used as Activity Monitor counts it
     (app memory + wired + compressed); bar = used / total.
   - Bar colour follows the status colour of that resource.
3. **SESSIONS**: one row per session whose work is not completed (decided by the owner
   2026-11-13), whether it is using the machine, thinking, or waiting. A session is
   listed if ANY of:
   1. it has running programs attributed to it (any amount, including sleeping ones at
      0% and 0 GB; no threshold). A new command must be seen in two consecutive
      refreshes first (avoids flicker); this applies only to these process rows;
   2. OpenChamber marks it busy: `session_v2.time_busy > coalesce(time_idle, 0)` and
      `time_archived is null`. Stale-flag guard: a busy session without programs whose
      last sign of life (newest message, session update, or the busy time) is more than
      12 h old is treated as not active;
   3. it is idle itself but a descendant session (via `parent_id`, any depth) qualifies
      under 1 or 2 (e.g. an orchestrator waiting on its workers).
   Finished sessions waiting for the user (`time_idle > time_busy`) are not listed.
   Throwaway test sessions (e.g. ones other agents create in /tmp) are listed like any
   other session, because they use capacity (owner, 2026-11-14).
   - Folder part of a process row: the worktree name when the programs run in a
     `*-wt/<name>` worktree, otherwise the session directory's name (omitted for chat folders).
   The DB is read with one short read-only query per refresh (non-archived sessions
   updated in the last 7 days plus their ancestors; about 0.5 ms).
   Sorted by CPU (then memory); when memory is amber/red, by memory (then CPU) instead. Rows at 0%: thinking first, then waiting, then sleeping
   (process rows), each newest first.
   - Rows without programs use the same design: grey line
     `<project> · thinking · <time since busy>` or
     `<project> · waiting for N sessions · <time since the oldest active descendant became busy>`
     ("waiting for 1 session" for one); the project part is omitted for chat folders
     (~/.config/openchamber/chats). Numbers show 0% and 0.0 GB. Hover: thinking rows show
     one grey line "Thinking. No programs running on this Mac"; waiting rows list the
     active descendant session titles. Click reveals the session directory (nothing for
     chat folders).
   - Line 1: a 16 × 16 pt icon of the harness running the session (see "Harnesses" below),
     6 pt gap, the session title (medium weight), and to its right the project name
     in the small grey font. Long titles truncate with "…"; the project stays visible.
   - Line 2 (small grey, always one line, truncate with "…"), indented 22 pt (icon + gap)
     so it aligns with the title text:
     `<worktree or folder name> · <activity> · <running time>`,
     e.g. `wiki-w14 · browser tests · 6 min`.
   - Right side: CPU % (100% = one core), memory in GB, and a small grey chevron "›"
     hinting at the hover panel (row grid `minmax(0,1fr) 42px 52px 8px`).
   - Hover: a side panel headed `<TITLE> · <HARNESS>` (e.g. "FIX LOGIN REDIRECT · CLAUDE CODE")
     lists that session's programs grouped by kind
     (e.g. "Headless Chrome ×6", "workerd", "Playwright runner", "vite"), each with CPU and memory.
   - Click: reveal the session's folder in Finder. No other actions.
4. **APPS & TOOLS** (heading renamed 2026-11-14; was "Everything that is not a session"): exactly two folded rows, styled like
   session rows (medium-weight title, one grey line truncated with "…", CPU, memory,
   chevron). Hovering either opens the same side panel as a session, headed
   AGENT TOOLS / OTHER APPS and listing ALL its items with CPU and memory (no hiding of
   small items). Clicking them does nothing.
   - **Agent tools**: grey line = member names, e.g. `OpenChamber, opencode, Claude Code ×9`;
     numbers = sum of its items. Items: OpenChamber app (main app + all its helper
     processes), opencode server (the `opencode serve` started by OpenChamber),
     opencode service (`opencode serve --service` and its helpers such as opencode-pty),
     Claude Code ×N (all `claude` CLI processes).
   - **Other apps**: grey line = the named top apps in order, then "everything else",
     e.g. `Firefox, Spotlight indexing, everything else`; numbers = sum of its items.
     Items: the biggest non-session apps by name (up to 3, ranked by share of CPU +
     share of memory; Spotlight indexing for mds/mdworker), then "Everything else".
     Everything else: CPU = machine total minus everything listed; memory = sum of the
     memory of the unlisted processes themselves (footprint; resident size when a
     process's footprint is more than 1 GB above its resident size, i.e. mostly swapped
     out, such as a virtual machine).
5. No footer. A grey "…" button top-right in the header opens a small native menu: "Open at Login" (checkmark) and "Quit ⌘Q" (owner chose this, 2026-11-14; replaces the footer Quit and the "Updated N s ago" timer).

## Attribution (how a program is assigned to a session)

1. Every command an agent runs starts as a shell (`zsh … -c <command>`) that is a
   direct child of an agent host: an `opencode serve` process, the `opencode-pty daemon`
   (long-running commands run there; seen 2026-11-13), or a `claude` CLI process.
   That shell and all its descendants belong to one session. A shell must be seen in
   two consecutive refreshes before it creates a row.
2. The session is found by looking up the exact command text in OpenChamber's
   opencode database (`~/.local/share/opencode/opencode.db`, read-only),
   table `session_message` (column `data`, JSON), joined to `session_v2`
   (title, directory, agent). Verified 2026-11-13: a running test command matched
   "T2 concurrent e2e measurement" exactly.
3. Programs that lost their parent (re-parented to launchd) but run inside a
   worktree folder are counted under the session that owns that worktree
   (the session whose recent messages mention that folder most).
4. Anything else falls into "Everything else".
5. If the database cannot be read or its layout changed, rows fall back to folder
   names. The app never writes to it.

## Harnesses (owner, 2026-11-14, "option B")

One SESSIONS list, sorted as before; every session row shows the official icon of the tool
running it: OpenChamber, OpenCode, Claude Code, Codex or Pi. The folded "Agent tools" /
"Other apps" rows keep no icon and no indent.

- **OpenChamber vs OpenCode** (same opencode database): OpenChamber when `session_v2.metadata`
  of the session or of any ancestor session contains an `"openchamber"` key (OpenChamber writes
  it as soon as it creates a session; older sub-sessions lack it themselves), or when the
  session's commands run under the `opencode serve` whose parent is OpenChamber.app.
  Everything else in the database is OpenCode.
- **Claude Code, Codex, Pi started on their own** (in a terminal): their CLI process with no
  opencode process among its ancestors, plus all its descendants, is one session. `claude`
  processes under opencode stay in "Claude Code ×N" as before.
  - Listed only while working: its processes used ≥ 1% CPU in the last sample, or its
    transcript was written in the last 2 minutes. A harness waiting for the user disappears
    (its processes then count under "Everything else").
  - Title from its transcript: Claude Code `custom-title`, then `ai-title` / `summary`, then the
    first user message; Codex: thread name in `~/.codex/session_index.jsonl`, then the first user
    message; Pi: `session_info` name, then the first user message. Fallback: the tool's name.
    Project = name of its working folder.
  - Grey line `<activity> · <time>`: the usual label of the programs it runs, or `working` when
    it runs none; time since the last user message (at most since the process started).
  - Hover lists its own processes as "<Harness> itself".
- **Icons**: loaded at runtime from the installed apps (OpenChamber.app, OpenCode.app,
  Claude.app for Claude Code, Codex.app or the Codex icon inside ChatGPT.app); Pi's mark is drawn
  from its MIT-licensed logo. A grey "terminal" symbol when the app is not installed. No other
  company's icon is stored in the repository.

## Not in v1

Stopping processes, opening a session from the menu, notifications, a project-specific
browser-test lock/queue, splitting "Claude Code ×N" per session, Codex desktop-app sessions.

## Culprit line (owner, 2026-11-14)

When the status is not green, the grey line under the headline names the main culprit
instead of the generic advice: the biggest user of the resource that is short, among
sessions, agent tools and all named apps (also ones not shown in the top 3), memory first
when both are short. E.g. "Firefox is using 6.8 GB", "W14 Images is using 2.7 cores".
Green keeps "Room for another session".

## Swapping (owner, 2026-11-14)

- The memory card shows a grey line "Swapping N MB/s" (or "N.N GB/s") while memory is
  actively moving between RAM and disk (swap-ins + swap-outs since the last refresh) at
  1 MB/s or more. Otherwise the card looks as before. The amount sitting in swap is never shown.
- Heavy swapping, 30 MB/s or more in two consecutive refreshes, makes memory amber even when
  macOS still reports normal pressure. Headline: "Busy · memory is swapping"; the culprit line
  and memory sorting then apply as for any memory problem. Real pressure keeps its own wording.

