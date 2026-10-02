# Recorded demo: plan

Status: **built** (2026-09-30). M0, M1, M3 and M4 are done: the README GIF is a real take with live Claude Code.
Claims marked *verified* were checked on this machine (§9); §0 is what exists now and how to run it.

The goal is a **silent GIF** for the open-source README showing Paneyard end to end: live Claude Code, two jobs
queued over MCP, herdr, Hunk, merge, close. Everything else (a longer talk video, per-step clips, captions, a
voiceover) waits until the GIF has been seen. The setup is built so those can follow without rework, and so the
operator can also run the same demo live by hand.

## 0. What is built, and how to run it

Everything lives under `demo/`, outside `app/`, and changes no application code.

```
demo/bin/record build      # the paneyard-demo image: Ruby 4.0.1, herdr 0.9.3, Claude Code 2.1.285, Hunk 0.22.0, kitty, Xvfb, ffmpeg
demo/bin/record compat     # Paneyard vs the image's real herdr, stand-in claude: PaneyardSandbox::Verify + a close-by-hand run
demo/bin/record smoke      # 10 s of the herdr UI at the canvas size, plus a glyph check
demo/bin/record rehearse   # the whole story filmed with the stand-in (no model), then cut to rehearsal.mp4/.gif
demo/bin/record take       # the same story with real Claude Code (needs CLAUDE_CODE_OAUTH_TOKEN; spends Pro quota)
demo/bin/record cut NAME   # re-cut rehearsal|take from its .mkv and NAME-timings.json
```

| File | What it is |
| --- | --- |
| `demo/Dockerfile` | The image. `/usr/local/bin/claude` is `demo/bin/claude`, a dispatcher that runs the stand-in while `/work/demo/rehearsal` exists and the real CLI otherwise. |
| `demo/bin/record` | Host entry point. Mounts the repo **read-only** at `/work/src` and only `tmp/demo-output` writable. |
| `demo/bin/in-container` | Container side. Copies the source into a tmpfs and runs from the copy, so a live agent with full access can't write to the operator's checkout. |
| `demo/lib/stage.rb` | herdr, Xvfb, kitty, ffmpeg, the Paneyard instance, the todo repo, registering the workspace. |
| `demo/lib/director.rb` | The story's beats (§5): types into the focused pane with `xdotool`, switches herdr's view, closes workspaces, waits on real state, writes `timings.json`, and checks the take. |
| `demo/lib/cut.rb` | Fits each beat to a budget (sped up with an "N×" badge when it runs long), then a 1280-wide MP4 and a 1200-wide GIF. |
| `demo/rehearsal/claude` | The stand-in: a real herdr detects it as `claude`. It plays both roles in the story for real over MCP and git (queues the jobs, makes canned changes from `demo/rehearsal/changes/`, merges), and understands `[fake-agent: ...]` for `compat`. |
| `demo/scenario/todo/` | The todo repo, laid out so the two jobs touch different files. |

**Results so far:**
- `compat` is all green on herdr 0.9.3 (M0).
- `smoke` gives 1920×1080 at 299–300 of 300 frames (M1).
- A full `rehearse` passes every check in about 80 s of footage.
- The first real `take` (Sonnet) passed every check in 107 s of footage and cuts to a 45 s, 5.2 MB GIF, now in the README.
- The todo repo's first commit is the same on every take (`234ed7b21e62`).

**Changed from the plan while building:**
- **kitty, not xterm.** xterm crops any fallback glyph wider than a cell, which cut Claude's `⏺` in half. kitty scales symbols into the cell, and runs on Xvfb with Mesa's software OpenGL.
- **Canvas 1920×1080 at 15 pt**, not 2560×1440. Scaled down to a README GIF, 2560-wide text becomes unreadable. `DEMO_CANVAS`/`DEMO_FONT_SIZE` go bigger for a talk.
- **The takes don't run as a Paneyard sandbox.** The container is the isolation: its own herdr, filesystem and database, no GitHub credentials, and the source read-only. A sandbox would label every run `[sandbox] …` in herdr's sidebar. `compat` still runs as a sandbox, because that is the path `bin/sandbox --real-herdr` uses on the host.
- **The model is `sonnet`** (`DEMO_MODEL`), not Paneyard's default `opus`, to go easier on Pro quota.

**Found along the way:**
- **A Paneyard edge case, not fixed.** Closing a run's herdr workspace during its launch window (about 10–15 s after `agent.prompt`, while `SessionLauncher` watches the prompt get picked up) fails the launch, so the run ends `failed` even if the agent already reported `done`. Closing it later completes it normally. The demo never closes that early.
- `list_runs` returns only in-flight runs unless called with `includeFinished: true`.
- The herdr client opens a `~` workspace of its own when it attaches. The director closes it before filming.

## 1. Decisions

| Question | Decision |
| --- | --- |
| What's shown | **Terminal only, MCP only.** The operator schedules through MCP, not the web UI, so the video never shows a browser. |
| Agents | **Real Claude Code, live**, Claude only. The operator's own Claude session queues **two** trivial jobs; each runs as its own live Claude session in its own herdr workspace. |
| First deliverable | **A silent README GIF.** No voice and no captions for now; decide after seeing it. |
| herdr | **Upgrade to 0.9.3 (latest)** and pin it. Paneyard's runner was verified live on 0.7.5, so the upgrade is milestone M0 (§3). |
| Auth | The operator has a **Claude Pro subscription, not an API key.** `claude setup-token` ("Set up a long-lived authentication token (requires Claude subscription)", *verified* in `--help`) makes a token, which is passed into the container at run time only (§6). |
| Capture | **One Xvfb display** with a full-screen xterm running the herdr client, recorded by **one `ffmpeg -f x11grab`** at 2560×1440@30. *Verified* at 300 of 300 frames. |
| Driver | A small **director** script that types with visible keystrokes (`xdotool`), clicks in herdr, waits on real state (herdr agent status, git, `/mcp/admin` `get_run`) and writes `timings.json`. |
| Out of scope for now | The web UI, voiceover and captions, Codex/opencode, and registering the workspace on camera (the reset pre-registers it). |

## 2. What the plan relies on in Paneyard

- **`bin/sandbox --real-herdr`** runs this checkout's `bin/production` in isolation (`PANEYARD_SANDBOX=1`) against whatever herdr `HERDR_SOCKET_PATH` names. Inside the container that is the container's own throwaway herdr, not the operator's. `bin/sandbox`'s `warn_untrusted!` documents that real `claude` stops at its folder-trust prompt unless the repo is trusted.
- **`queue_run` over `/mcp/admin`** enqueues `RunDispatchJob` immediately, so each job's herdr workspace appears within seconds. The concurrency cap defaults to 4, so both jobs start at once.
- **The operator's own layout** is an `Agent` tab plus a `Hunk` tab running `hunk diff --watch` (read-only from `storage/production.sqlite3`). The demo workspace uses the same, so "move to the Hunk screen" is a tab switch. Hunk 0.22.0 ships Linux builds (`hunkdiff-linux-x64`/`-arm64` on npm).
- **Closing a run's workspace in herdr is a supported close.** `RunSessionReconcileJob` (every 30 s) treats a workspace closed by hand as "the operator is done with it". It completes the run with its last reported outcome (`RunSessionRunner#mark_pane_lost!` keeps a reported `done`) and calls the same `WorktreeJanitor.release!` that Close session does. No web UI is needed.
- **Cleanup rule:** the janitor removes a worktree only once its session is over and it is clean with HEAD on `main` or a remote branch. So merge, then close, and each worktree disappears.

## 3. herdr: in Docker, and upgraded

*Verified* on 0.7.5 in `ubuntu:24.04`:
- The Linux build is a `static-pie` binary, and `herdr server` runs headless.
- A client in xterm attaches and draws the full UI.
- `herdr agent start --kind claude` on a script named `claude` was detected (`process=claude`) and tracked idle → working → done from what it drew. Detection is screen-based, so real Claude Code is detected the same way in the container as on the host.

**The upgrade to 0.9.3 (protocol 22)**, *verified* from its schema and release notes:
- **API methods:** `herdr api schema --json` for 0.7.5 and 0.9.3 was compared for the 14 methods `Orchestrator::Runner::Herdr` calls (`workspace.create/close`, `tab.create/rename`, `pane.split/rename/send_input/read/process_info`, `agent.start/get/prompt/send_keys`, `notification.show`). **None were removed.** 0.9.3 adds 7: `pane.clear`, `pane.copy_motion`, `pane.copy_search`, `pane.edit_scrollback`, `pane.scroll`, `workspace.move_block`, `workspace.reordered`.
- **Release-note items that touch Paneyard's calls,** none of them blocking on paper:
  - 0.8.0: closing a non-focused workspace no longer moves focus; closing a workspace's last tab through the API closes the workspace.
  - 0.9.0: `workspace.close` needs `close_group: true` only for herdr's own worktree-group workspaces, which Paneyard doesn't create; `--no-session` mode was removed, and Paneyard doesn't use it.
  - 0.9.2: the pane graphics API was removed (unused), and clicking a pane no longer sends a stray Escape to a working agent (good for a clicking director).
- **Not checked:** response shapes and parameter changes of those 14 methods, and real Claude detection under 0.9.3's manifests. **M0** checks them live, cheaply: Paneyard's runner specs plus a lifecycle run against a 0.9.3 herdr in a container with a stand-in `claude`. Only then does the operator upgrade their own herdr (`herdr update`), since production runs against it.

**Pinning in the image:**
1. The binary version, as a build arg (0.9.3).
2. The detection manifests. On the first boot herdr fetched newer remote manifests at startup (claude `2026.07.13.1` → `2026.09.11.1`). Bake the chosen ones in as local overrides (`herdr server reload-agent-manifests` exists; the mechanism is checked in M1). The container can't run offline because Claude needs the network.
3. `~/.config/herdr/config.toml` with `onboarding = false` (otherwise a welcome modal covers the screen), a fixed theme and a fixed sidebar width.

## 4. Capture

**Resolution.** *Verified* in Colima (4 CPUs), 10 s of scrolling xterm:

| Canvas | x264 veryfast crf18 | x264 ultrafast lossless |
| --- | --- | --- |
| 1920×1080 | 300/300 | 300/300 |
| 2560×1440 | 300/300 | 300/300 (6 MB/10 s) |
| 3840×2160 | **202/300** | **275/300** |

**Outputs:**
- **Master:** 2560×1440@30, `libx264 -preset ultrafast -qp 0 -pix_fmt yuv444p` (lossless, sharp coloured text), about 36 MB/min. Any 1920×1080 crop of it is a 1:1 zoom.
- **README GIF (first deliverable):** about 960–1200 px wide, 12–15 fps, `palettegen`/`paletteuse` with a limited palette (terminal colours compress well), under about 8–10 MB. Working stretches are sped up so it lands at roughly 45–60 s. A 1280×720 MP4 of the same cut is a by-product.
- **Later, once the GIF has been seen:** a 1080p/1440p talk video and per-step clips cut at the `timings.json` marks.

**Layout:**
- xterm fills the canvas with a font around 22 px, legible after scaling down.
- The terminal is **never resized during a take**; a resize reflows Claude's TUI and herdr's panes.

**Typing and clicks.** `xdotool type --delay 40–70ms` into the focused herdr pane, so prompts visibly get typed. Real pointer clicks on herdr's sidebar and tabs, recorded with `-draw_mouse 1`. herdr's keybindings (`ctrl+b` prefix) are the fallback if a click target is unreliable.

**Terminal details found while probing:**
- It needs `LANG=C.UTF-8` and `xterm -u8`; without them box drawing rendered as `â`.
- It needs a font that has `⏺` and similar symbols. DejaVu lacks it; use e.g. JetBrains Mono plus Noto Sans Symbols 2.
- A backgrounded ffmpeg in a script needs `-nostdin`; the probe's ffmpeg swallowed the piped script.

## 5. The story

| # | Beat | On screen | Director does | Waits on |
| --- | --- | --- | --- | --- |
| 0 | `idle` | herdr full-screen. An "operator" workspace holds Claude Code, idle, with Paneyard's `/mcp/admin` configured as an MCP server. | nothing (about 2 s) | n/a |
| 1 | `ask` | Typed into Claude: *"queue two paneyard jobs on todo: one to add due dates to todos, one to add a `todo clear` command that removes finished todos"*. Claude calls `queue_run` twice. | types, then Enter | two runs exist (`list_runs`) |
| 2 | `spawn` | **Two** new workspaces appear in herdr's sidebar, both turning to working. | clicks the first | both agents `working` |
| 3 | `work` | Job 1's Claude reads the code, edits it and runs `bin/test` (sped up). | nothing | a few seconds of work |
| 4 | `hunk` | Switch to job 1's **Hunk** tab; the diff grows. Glance at job 2's workspace, then its Hunk tab. | clicks tabs and workspaces | both agents idle with checkpoints |
| 5 | `merge` | In job 1, typed: *"looks good — go ahead and merge to main"*. Then the same in job 2. | types into each | `main` contains both changes, both agents idle |
| 6 | `close` | Close both run workspaces in herdr; they leave the sidebar. | closes each | both workspaces gone |
| 7 | `confirm` | In the operator's Claude, typed: *"how did those jobs go?"*. Claude calls `list_runs`/`get_run`: both completed, worktrees cleaned up. | types, then Enter once both runs show `completed` | the answer on screen |
| 8 | `end` | Hold on the clean sidebar | nothing | n/a |

- **Timing:** closing ends each run at the next reconcile tick (≤30 s). The director types the beat 7 question only once `get_run` already reports `completed`, and post-processing speeds up that wait along with the agents' working stretches.
- **Two jobs that merge cleanly:** they must touch **different files**, or the second merge conflicts. The todo repo is laid out for that (§6). "Due dates" changes the item model and the `list` command; "`todo clear`" adds a new command file and its test.
- **The GIF cut** is beats 1–7 with sped-up gaps, about 45–60 s.

## 6. Keeping live takes repeatable

A take is live: the agents' wording and timing differ each time, and that's accepted. Everything around them is fixed.

- **Same start every take.** `demo/bin/reset`:
  - materialises the todo repo from `demo/scenario/todo/`: a tiny Ruby CLI with `lib/todo/item.rb`, one file per command under `lib/todo/commands/` (auto-discovered), and `bin/test`. Author and dates are pinned, so the SHA is the same every time.
  - adds a bare `origin` (Paneyard requires an `origin` remote),
  - boots a fresh sandbox with the `todo` workspace registered and the Agent + Hunk layout. That replaces `sandbox:seed`'s scratch workspace, a small change to `bin/sandbox` (a `--no-seed` flag or a seed option).
- **Pinned tools.**
  - Claude Code at a fixed version in the image, with auto-update off (`DISABLE_AUTOUPDATER=1`). The host has 2.1.285.
  - The model pinned by name: `PANEYARD_CLAUDE_MODEL` for the runs and `--model` for the operator's session.
  - `~/.claude.json` pre-seeded so neither onboarding nor the trust prompt appears.
- **Auth with a Pro subscription.**
  1. The operator runs `claude setup-token` once on the host.
  2. The token is kept outside the repo, in `~/.config/paneyard/demo.env`.
  3. It is passed into the container at run time as `CLAUDE_CODE_OAUTH_TOKEN`, never baked into the image. The host's own login lives in the macOS Keychain and can't be mounted.
  4. M2 verifies that the container's `claude` picks the token up.
- **Pro usage limits.** A take is three short Claude sessions (the operator's and two jobs) on trivial tasks. That should fit a Pro 5-hour window a few times over, but it isn't free to iterate. So:
  - **Rehearsal mode** develops the director without using the quota: a stand-in `claude` script, like the one probed in §9, shows a spinner, applies a canned patch and reports through `/mcp/run`. A stand-in for the operator's session calls `queue_run`. It's for developing choreography only and never appears in the published GIF.
  - **Real takes** default to one (`--takes 1`), and retakes are explicit.
- **Checks per take:** tests pass in both worktrees, `main` has both merges, and after the herdr closes both runs are `completed` with their worktrees gone. Each wait has a timeout, and a failed take names the check that failed.

## 7. Talk use (later)

- **Live by hand:** `demo/bin/reset --host` prepares the same todo repo and a sandbox instance on the operator's Mac, pointed at their own herdr. The live demo then starts from the same state as the recording, and the operator types the same lines.
- **Fallback:** per-step clips from a recorded take, with a presenter profile (bigger font, high-contrast herdr theme).

## 8. Architecture

```
host                                │ container "paneyard-demo"
demo/bin/record [--takes N]         │  Xvfb :99 2560x1440 + openbox
  [--rehearsal]                     │    └─ xterm (full screen) ── herdr client
  reset, docker run                 │  ffmpeg x11grab ──► master.mkv
  (CLAUDE_CODE_OAUTH_TOKEN from     │  director: xdotool typing/clicks, herdr CLI + git + get_run waits,
   ~/.config/paneyard/demo.env),    │    checks, timings.json
  chown, then post:                 │  herdr server 0.9.3 (pinned, manifests baked in)
  speed-ups, crop, GIF              │    ├─ "operator" workspace: claude (live) → /mcp/admin queue_run ×2, list_runs
                                    │    ├─ job 1 workspace (Paneyard-launched): Agent: claude | Hunk: hunk diff --watch
                                    │    └─ job 2 workspace: same
                                    │  Paneyard sandbox (bin/production, PANEYARD_SANDBOX=1,
                                    │    HERDR_SOCKET_PATH = container herdr, todo pre-registered)
                                    │  /work/demo/todo/{main, origin.git, worktrees}
```

Proposed files, all outside `app/` so `spec/boundary_spec.rb` is unaffected:

- `demo/Dockerfile`
- `demo/bin/{record,reset,in-container}`
- `demo/director/`
- `demo/rehearsal/` (the stand-in `claude` scripts)
- `demo/herdr/` (config and manifests)
- `demo/claude/` (pre-seeded settings, no credentials)
- `demo/scenario/todo/`

Outputs go to `tmp/demo-output/`, which is gitignored.

## 9. Evidence: what was actually run

Host: macOS, Intel (`x86_64`). Docker 29.5.2 through Colima (Ubuntu 24.04 VM, 4 CPUs, 5.8 GiB, `linux/amd64`). Colima shares only `$HOME`, so bind mounts from `/private/tmp` came up empty; the probes piped scripts over `docker exec -i ... bash -s` and used `docker cp` for results.

1. `~/.local/bin/herdr --version` → `herdr 0.7.5` (Mach-O x86_64). `--help` lists `herdr server  Run as headless server` and the socket-API subcommands.
2. `https://herdr.dev/install.sh` picks `${os}-${arch}` from `https://herdr.dev/latest.json` (0.9.3, protocol 22, with sha256 per asset). The GitHub releases API lists every tag back to v0.1.0, with `herdr-linux-{x86_64,aarch64}` assets.
3. Probe image: `ubuntu:24.04` + `xvfb xterm ffmpeg x11-utils xdotool fonts-dejavu-core git`, with herdr from `releases/download/v0.7.5/herdr-linux-x86_64` → `ELF 64-bit ... static-pie linked`.
4. `herdr server &` then `herdr status server` → `running, version 0.7.5, protocol 17, compatible: yes`.
5. `herdr workspace create --cwd /tmp/repo --label paneyard/add-due-dates --no-focus` and `herdr tab create --workspace w2 --label Hunk --no-focus` both succeeded, returning the JSON shapes `Orchestrator::Runner::Herdr` expects.
6. A bash script named `claude` (OSC-title spinner, `✻ Reading …… (4s · esc to interrupt)`, then a result line), started with `herdr agent start probe --kind claude --pane w2:p1`. The server log shows `agent changed ... agent=Some(Claude) process=claude`, and `agent get` went `idle` → `working` → `done`.
7. The first boot's `herdr server agent-manifests --json` showed claude `remote 2026.09.11.1` (fetched at startup) instead of the bundled `2026.07.13.1`.
8. Xvfb 1920×1080, `xterm -u8 -fa 'DejaVu Sans Mono' -fs 16 -e herdr`, `ffmpeg -nostdin -f x11grab ... -t 10` → h264 1920×1080 30/1. The frames show the sidebar with the new workspace, the `1`/`Hunk` tabs, agent status and output. The mojibake, onboarding modal and missing `⏺` from §4 were all seen here.
9. The frame-rate table in §4 came from the same container.
10. The upgrade check in §3: the 0.7.5 and 0.9.3 Linux binaries each ran `herdr api schema --json` in the probe image (78 vs 85 methods, none removed), compared against the `request!` calls in `app/services/orchestrator/runner/herdr.rb`. Release notes for v0.8.0–v0.9.2 were read from the GitHub releases API.
11. `claude setup-token --help` on the host: "Set up a long-lived authentication token (requires Claude subscription)". It was not run.
12. Paneyard files read: `config/recurring.yml`, `queue_run_tool.rb`, `run_session_reconcile_job.rb` and `RunSessionRunner#mark_pane_lost!` (closing by hand), `bin/sandbox` (`warn_untrusted!`, `--real-herdr`), and the workspace layouts from `storage/production.sqlite3` opened `-readonly`.

No real Claude session, `--real-herdr` sandbox or model usage was involved. The probe containers were removed; the image `paneyard-herdr-probe` is left (`docker rmi paneyard-herdr-probe` removes it).

## 10. Milestones (each one a queueable run)

**M0: Verify Paneyard against herdr 0.9.3.**
- *Scope:* in a container with herdr 0.9.3, run Paneyard's runner through a full lifecycle with a stand-in `claude`: queue, workspace and tabs created, agent detected, prompt submitted, `report_idle`, a message sent in, workspace closed, reconcile completes the run, janitor releases the worktree. Diff the response shapes of the 14 methods against what `Orchestrator::Runner::Herdr` parses. Fix anything that broke.
- *Done means:* the lifecycle passes on 0.9.3 (and still on 0.7.5); `bin/verify` passes; the report says whether the operator can `herdr update` production safely.
- *Needs:* no model usage. The operator upgrades their own herdr afterwards.

**M1: Recording container skeleton.**
- *Scope:* Xvfb, openbox, herdr 0.9.3 with config and manifests baked in, a full-screen xterm client and ffmpeg. `demo/bin/record --smoke` records 10 s at 1440p, plus a glyph check.
- *Done means:* the smoke MKV has 300 frames; an extracted frame shows herdr's UI with no missing glyphs and no onboarding modal.

**M2: Paneyard and live Claude in the container.**
- *Scope:*
  - Ruby and gems, and a pinned Claude Code with auto-update off.
  - Pre-seeded `~/.claude.json`: onboarding done, the todo repo trusted, `/mcp/admin` configured for the operator's session.
  - `demo/bin/reset` with the todo scenario and the pre-registered workspace.
  - `CLAUDE_CODE_OAUTH_TOKEN` auth.
- *Done means:* driven by hand over VNC, two live jobs go through beats 1–7; `bin/verify` passes.
- *Needs:* the operator's `setup-token` token and go-ahead to use Pro quota.

**M3: Director, rehearsal mode, then one real take.**
- *Scope:* beats 0–8 with `xdotool`, event waits and timeouts, per-take checks, `timings.json`. `--rehearsal` uses the stand-ins; `--takes N` uses real Claude.
- *Done means:* rehearsal takes pass repeatedly with no quota used; one real take passes its checks; a contact sheet is in the report.
- *Needs:* Pro quota for the real take.

**M4: The silent README GIF.**
- *Scope:* speed-ups for working and waiting stretches, a crop, the GIF and the matching MP4; the README's image TODO replaced.
- *Done means:* the GIF is under the size budget and legible at README width; the README shows it.

**Later, only if wanted after seeing the GIF:** the 1080p/1440p talk video and per-step clips; captions or voiceover; the talk kit (`reset --host`, presenter profile, fallback clips).

## 11. Risks

| Risk | Mitigation |
| --- | --- |
| herdr 0.9.x changed a response shape Paneyard parses | M0 runs before anything else, and fixes land with specs. |
| The two jobs' merges conflict | Disjoint files by scenario design, and a check fails the take if `main` lacks either change. |
| A live agent goes off-script, or asks before merging because it hasn't committed | A trivial task and a pinned model. If it asks, the director answers "yes". Retakes are explicit. |
| Pro quota runs out mid-iteration | Rehearsal mode for all director work, and one real take by default. |
| The `setup-token` token doesn't work in the container | M2 finds out first. Fallback: log in interactively inside the container once (over VNC) with the credentials dir on a persistent volume. |
| Claude Code in the container: onboarding, trust prompt, auto-update | Settled in M2 and baked into the image, except credentials. |
| herdr detection manifests drift (the container needs network) | Baked local overrides and a pinned version. |
| Clicking herdr's sidebar and tabs by pixel is brittle | Fixed geometry and font; herdr keybindings as a fallback. |
| Account details visible in Claude Code's banner | Check the GIF's frames; crop or retake. |
| Colima only shares `$HOME` | `demo/bin/record` mounts the repo (under `$HOME`), never `/tmp`. |

## 12. Open questions

1. **Model:** which model should takes pin? The one Claude Code picks by default on Pro is the natural choice; name it so it doesn't drift.
2. **The two jobs:** are "add due dates" and "add a `todo clear` command" good, or do you want different ones? They must touch different files.
