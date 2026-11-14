# Agent Load

A small macOS menu bar app that answers one question at a glance: **which agent session is
making the Mac slow, and can I start another one?**

The menu bar shows a coloured dot and the number of sessions that are running programs right
now (`● 3`). Green means there is room for another session, amber means wait, red means
free something up. Click it for the breakdown: CPU and memory gauges, one row per busy
OpenChamber/opencode session (hover a row to see its programs, click to reveal its folder in
Finder), plus two folded rows for the agent tools and for other apps (hover them for the
details).

The agreed design is in [`docs/design.md`](docs/design.md); the approved look is
[`docs/mockup.html`](docs/mockup.html).

## Build and run

Needs macOS 14 or later and the Xcode Command Line Tools (full Xcode is not needed).

```sh
scripts/build-app.sh            # builds "build/Agent Load.app"
open "build/Agent Load.app"     # starts it; the dot appears in the menu bar
```

To quit, open the dropdown and click **Quit**.

### Start at login

The app does not install itself. To start it at login:

1. Copy `build/Agent Load.app` to `/Applications` (optional, but keeps the path stable).
2. Open **System Settings → General → Login Items & Extensions**.
3. Under **Open at Login**, click **+** and choose **Agent Load**.

## How it works (short)

- Every few seconds (3 s while the dropdown is open, 10 s while closed) it reads the process
  list in-process (sysctl/libproc), plus one `ps` call for processes owned by other users,
  such as Spotlight's indexer.
- A command an agent runs starts as a shell (`zsh -c …`) under `opencode serve`, the
  `opencode-pty` daemon, or a `claude` process. That shell and everything it starts belong
  to one session. The session is found by looking up the exact command text in opencode's
  database (`~/.local/share/opencode/opencode.db`), opened **read-only**.
- Status colour: memory pressure first, then the 1-minute load average against the 8 cores.

## Checking it

```sh
scripts/test.sh                                              # unit tests (Swift Testing)
"build/Agent Load.app/Contents/MacOS/AgentLoad" --dump       # full snapshot as text, incl. every process per row
"build/Agent Load.app/Contents/MacOS/AgentLoad" --verify-db  # proves the command lookup matches recent commands
"build/Agent Load.app/Contents/MacOS/AgentLoad" --render-png /tmp/a.png [--hover] [--dark] [--mockup-data]
```

## Limits

- Only sessions run through OpenChamber/opencode are recognised. Claude Code or Codex
  started on their own count under "Claude Code ×N" or "Everything else".
- A command must run for two refreshes before its session gets a row, so very short commands
  never show (on purpose, to avoid flicker).
- Programs that lost their parent are matched to a session only if they run inside a
  `*-wt/<name>` worktree folder. Other worktree layouts are not detected, because detecting
  them would mean reading files in ~/Documents.
- Memory per row is "footprint" (as in Activity Monitor). Footprints count compressed and
  swapped memory at full size, so the rows can add up to more than "Memory used". "Everything
  else" is the sum of its own processes; a process whose footprint is more than 1 GB above
  what is resident (mostly swapped out, e.g. a virtual machine) counts with its resident size.
- Processes owned by other users (for example Spotlight's `mds`) show their resident memory
  instead of footprint, because macOS does not let a normal app read their footprint.
- If the opencode database cannot be read or its layout changes, session rows fall back to
  folder names. The app never writes to it.
- Does not stop processes, send notifications, or start at login by itself.
