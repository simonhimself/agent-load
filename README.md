# Agent Load

**See which AI agent session is slowing down your Mac, from the menu bar.**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/dropdown-preview-dark.png">
  <img alt="The Agent Load dropdown: an amber &quot;Busy · memory and CPU&quot; status naming Firefox as the biggest memory user, CPU and memory gauges, six agent sessions each marked with the icon of the tool running it (OpenChamber, Claude Code, Pi, OpenCode, Codex) with their CPU and memory, and a hover panel listing one session's programs including its Claude Code agent" src="docs/assets/dropdown-preview.png">
</picture>

*Rendered from the app with illustrative sample numbers, in your GitHub light or dark theme. On
macOS 26 the real dropdown sits on translucent Liquid Glass, like the system's own menus.*

**[Build it from source →](#install)** · macOS 14+ · no Xcode needed

## Know who is using your Mac

- **See the strain at a glance.** A coloured dot and a session count sit next to Wi-Fi and
  battery: green is calm, amber means wait, red means free something up.
- **Find the culprit.** Every unfinished OpenChamber / OpenCode session gets a row with its
  CPU and memory, and so do Claude Code, Codex and Pi sessions started in a terminal while they
  work. Each row shows the icon of the tool running it, and a session on a Claude model
  includes the Claude Code process that does its thinking. When the Mac is strained, the line under the headline names the biggest
  user, even when it's another app such as a browser.
- **Look inside a session.** Hover a row to see its programs: headless Chrome, test
  runners, dev servers, the Claude Code agent. Click it to open the session's folder in Finder.

## What it recognises

| Tool | How it shows |
| --- | --- |
| OpenChamber | A row per unfinished session: running programs, thinking, or waiting for its sub-sessions. Sessions on a Claude model include their Claude Code agent process. |
| OpenCode (desktop app or terminal) | A row per unfinished session, like OpenChamber. |
| Claude Code, Codex, Pi started in a terminal | A row while it works, named after its conversation, with its programs. |
| Claude desktop app | One "Claude app" line under Agent tools, including its virtual machine. |
| Cua | One "Cua" line under Agent tools, including its Linux virtual machine. |
| Everything else | "Other apps": the biggest apps by name, then everything else. |

## Install

Needs macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`).
Full Xcode is not required.

```sh
git clone https://github.com/simonhimself/agent-load.git
cd agent-load
scripts/install.sh              # builds it, installs it in /Applications and starts it
```

The dot appears in the menu bar. Run `scripts/install.sh` again after pulling changes to
update the installed app. To start it at login, choose **… → Open at Login** in the dropdown.

## How to use it

1. Glance at the dot: the number is how many agent sessions have unfinished work.
2. Click it for the breakdown: status, CPU and memory gauges, one row per session, then
   **Apps & tools**: **Agent tools** (OpenChamber, the Claude app, Cua) and **Other apps**.
3. Hover any row for its details. The **…** button top-right has **Open at Login** and **Quit**.

CPU is shown per core: 100% is one full core, so 8 cores give 800%. The CPU gauge shows how
many cores are actually in use, averaged over the last 30 seconds, so a short spike doesn't
flip the status. When the Mac is busy, the line under the headline names the biggest user of
whatever is short, and sessions sort by that resource.

## How it works

Every few seconds the app reads the process list. Each command an agent runs starts as a
shell under the opencode server, so the app follows every program up to that shell and
looks up the exact command text in opencode's local database, opened read-only, to find
which session sent it. Sessions that are thinking or waiting on sub-sessions are taken from
the same database.

- **Light footprint:** refreshes every 10 s while closed and every 3 s while open, at well
  under 1% CPU.
- **Memory first:** the status colour follows macOS memory pressure, and heavy active
  swapping, before CPU, because on a 16 GB machine memory usually runs out first. The memory
  gauge shows "Swapping N MB/s" while memory is moving to and from disk.
- **Real CPU use:** CPU counts the processors actually in use over the last 30 seconds (amber
  from 85%, red from 95%), not the load average, which on macOS also counts programs waiting
  for disk or memory.
- **Never writes:** the app only reads processes and the database; it can't stop anything.

Details, the attribution rules and diagnostic commands are in
[How it works](docs/HOW-IT-WORKS.md).

## Develop

```sh
scripts/test.sh                                          # Swift Testing unit tests
"build/Agent Load.app/Contents/MacOS/AgentLoad" --dump   # live snapshot as text
```

`scripts/test.sh` passes the extra framework flags Swift Testing needs when only the
Command Line Tools are installed.

## Limitations

- Claude Code, Codex and Pi sessions started on their own are listed only while they work
  (≥ 1% CPU or a transcript written in the last 2 minutes). Their title comes from their
  transcript files, whose format can change. Pi support is built from its documentation and
  has not been tried with a real Pi. Codex desktop-app sessions are not listed.
- A Claude Code started by opencode whose parent has gone looks like one started on its own.
- Sessions disappear once finished: waiting for your next message, or with only an idle shell
  left. A session flagged busy with no sign of life for 12 hours is treated as stuck.
- opencode does not record which Claude Code process serves which session; the app infers it
  from the folder and the latest message. Processes it cannot match show as
  "Claude Code (unmatched)" under Agent tools.
- Claude desktop app threads are not session rows: their work runs on Anthropic's servers or
  inside the app's one shared virtual machine, which can't be split per thread. The app and its
  VM appear together as "Claude app" under Agent tools; Cua (Cua Spaces, its runtime in `~/.cua`
  and its VM) appears as "Cua".
- Commands shorter than two refreshes never get their own row; their CPU lands in
  "Everything else".
- Programs that lost their parent are matched to a session only inside `*-wt/<name>`
  worktree folders.
- Memory per row includes swapped-out memory, so rows can add up to more than
  "Memory used".
- Relies on opencode's internal database layout. If that changes, rows fall back to folder
  names.
- Read-only: it doesn't stop processes or send notifications. Starting at login is opt-in
  (**… → Open at Login**).
- macOS 14 or later; the Liquid Glass look needs macOS 26 (older versions use the previous
  menu material).

## Icons

The OpenChamber, OpenCode, Claude, Codex and Pi icons belong to their owners. The app shows
them only to identify which tool runs a session. It loads them at runtime from the apps
installed on your Mac (Pi's mark is drawn from its MIT-licensed logo); none are stored in
this repository.

## Project guide

| File | Purpose |
| --- | --- |
| [`docs/HOW-IT-WORKS.md`](docs/HOW-IT-WORKS.md) | Sampling, attribution, memory figures, diagnostics, source layout |
| [`docs/design.md`](docs/design.md) | Agreed design: status rules, listing rules, every dropdown element |
| [`docs/mockup.html`](docs/mockup.html) | Approved visual reference |
| [`scripts/build-app.sh`](scripts/build-app.sh) | Builds and ad-hoc signs the `.app` |
| [`scripts/install.sh`](scripts/install.sh) | Builds, installs in `/Applications` and starts the app |
| [`scripts/test.sh`](scripts/test.sh) | Runs the unit tests |
