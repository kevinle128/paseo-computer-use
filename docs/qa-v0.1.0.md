# QA record: computer-use plugin v0.1.0

Date: 2026-10-24, 01:20Z to 02:23Z, with follow-up runs to 05:31Z. Host: macOS 26 (Darwin 25.6),
Paseo dev daemon 0.13.0-beta.2 on a local test port with its own Paseo home, started from a
terminal app so that app is the TCC-responsible app. The everyday Paseo daemon was not touched.
The independent oracle was a separate computer-use CLI (AX reads of TextEdit, list-windows), plus small local
probes: a cursor sampler (250 ms and 5 ms), a TextEdit text-length poller, and a listen-only event tap.
Raw evidence stayed on the test machine; key excerpts are below.

## Result matrix

| # | Scenario | Provider / client | Result | Evidence excerpt | Timing |
| --- | --- | --- | --- | --- | --- |
| 1 | Install, ready, TCC; injection off/on | Claude | pass | `plugin ls`: `computer-use running yes`; status `helperBuildState: ready, axTrusted: true, screenCaptureGranted: true`. Setting off: agent config has no `mcpServers`. Setting on: `mcpServers.paseo-computer` stdio shim, and Claude launched with `--allowedTools mcp__paseo-computer__status,…list_apps,…list_windows,…get_app_state` only | - |
| 2 | TextEdit `xin chào`, Telex on | Claude | pass | Telex active (`status`: `VietnameseSimpleTelex (input method active)`); `paste_text` -> `verified`; oracle text `xin chào`, code points `78 69 6e 20 63 68 e0 6f` (NFC) | 49 s |
| 2 | TextEdit `xin chào`, Telex on | Codex (`full-access`) | pass | Follow-up run 05:11Z with Telex selected for the whole run (no input-source change seen by a 200 ms watcher). Plugin `status` before the run: `VietnameseSimpleTelex (input method active)`. Tools: `press_key Command+n`, `paste_text` -> `verified`. Oracle (AX read): `Untitled 18` text `xin chào`, code points `78 69 6e 20 63 68 e0 6f` (NFC). Earlier ABC-only runs: before the Codex tool-policy fix Codex saw only the 4 read tools (fail); after it, pass | 56 s |
| 2 | TextEdit `xin chào`, Telex on | Oh My Pi (`full`) | pass | Same Telex window, 05:12Z. The agent's own `status` returned `input source: …VietnameseSimpleTelex (input method active)`; `type_text` returned `verified` with `input: pasted through the clipboard (an input method is active)`. Oracle: `Untitled 19` text `xin chào`, code points `78 69 6e 20 63 68 e0 6f` (NFC). Its first two calls failed with `invalid_arguments` (see Findings) | 42 s |
| 2b | `type_text` reports the paste path | direct MCP client | pass | Telex active: `verified` / `input: pasted through the clipboard (an input method is active)`; oracle `xin chào`. Without a prior click, the same call returned `unverified: field value did not change; pasted because input source … is not a plain keyboard layout` (honest, see Findings) | 0.4 s |
| 3 | Esc stops `type_text`, re-arms next turn | Claude | pass | Turn 1: Escape posted 02:11:58.765Z, tool returned `error: aborted_by_user` at 02:11:58.823Z, text frozen within 170 ms. Turn 2 (same agent): `get_app_state` and `click` worked, Escape 02:12:35.610Z, `aborted_by_user` 02:12:35.664Z | 58 ms / 54 ms |
| 4 | Paseo Stop stops `type_text` | Claude | pass | Daemon `Cancel request received` 02:13:26.227Z; plugin audit `type_text status: cancelled` 02:13:26.229Z; text frozen 02:13:26.383Z; status `activeOwner: null`. Claude discards the result of a cancelled turn, so its transcript cannot show the code. The `aborted_by_user` text from a Stop was observed on the fallback row below | 2 ms cancel, 156 ms to last char |
| 4 | Paseo Stop stops `type_text` | Codex (`full-access`) | pass, code not observed | Run 05:22Z-05:23Z, 999-character `type_text` into a new TextEdit document. Daemon `Cancel request received` 05:23:28.730Z; plugin audit `type_text status: cancelled` 05:23:28.768Z. Codex replaces the result with its own text: its session rollout file has `custom_tool_call_output` `"aborted by user after 1.9s"` at 05:23:28.731Z, then `turn_aborted`. The plugin's text never reaches the transcript | 38 ms cancel |
| 4 | Paseo Stop stops `type_text` | Oh My Pi (`full`) | pass, code not observed | Run 05:27Z, 1500-character `type_text`. Daemon `Cancel request received` 05:27:30.762Z; plugin audit `type_text status: cancelled` 05:27:30.768Z. Its session file has `tool_execution_start` for `type_text` at 05:27:28.830Z and no `toolResult` for it; the turn ends with `stopReason: "aborted"` | 6 ms cancel |
| 4 | Paseo Stop aborts an unmapped owner (fallback path) | direct MCP client (owner) + Claude (stopped) | pass, observed | The direct client `<direct-client>` matches no host agent and owned the computer with a 4000-character `type_text`. A Claude agent ran a 120 s shell command; `paseo stop` on that agent at 05:30:35.029Z. Daemon `Cancel request received` 05:30:35.839Z. The direct client received, at 05:30:35.841Z: `type_text (1982 ms, isError=true)` / `error: aborted_by_user` / `Computer Use was stopped because the user pressed Stop in Paseo. …`. Audit `type_text status: cancelled` 05:30:35.840Z, `activeOwner: null` after. TextEdit length 200 at 05:30:35.846Z and 203 at the last read. This observes the documented fallback (a canceled turn stops an owner the plugin cannot map), not an agent's own call. Evidence kept on the test machine | 2 ms from cancel to result; 812 ms from CLI start to cancel |
| 5 | Second caller gets `computer_busy` | Claude (A) + direct MCP client (B) | pass | B `press_key` -> `error: computer_busy … controlled by another session (<agent-a-id>)` | 1 ms |
| 5 | Second caller gets `computer_busy` | Claude (A) + Codex (B), two real agents | pass | A in one long `type_text` (length 1089 when B started, still growing). Codex B, 02:48:16Z: `paseo-computer.press_key` -> `error: computer_busy … controlled by another session (<agent-a-id>)`, A's agent id. A's call then ended at 30 s with `helper_unavailable` (the long-text timeout bug fixed below), not because of B: a single-caller repro stopped the same way | 90 ms |
| 6 | `app_blocked`, no AX read | direct MCP client | pass | `get_app_state`, `click`, `list_windows` on `com.apple.Passwords` (launched) and `get_app_state`, `type_text` on `com.1password.1password` all `error: app_blocked`; the check runs in the policy guard before the tool (`server/computer-use-mcp/policy/index.ts:83-85`) | 0-2 ms (an AX read takes 120+ ms) |
| 7 | `stale_element` after a UI change | Claude (real helper) | pass | Agent read TextEdit, its own `Command+n` changed the UI, then `type_text element_index 2` -> `error: stale_element … Element '<pid>:0.0.0' changed since the latest snapshot` (02:08:52Z). A direct-client attempt with the oracle CLI's `Cmd+W` hotkey did not change the UI (`window_not_focused`), so it proved nothing | 152 ms |
| 8 | No code-execution tool | direct MCP client over the plugin socket | pass | `tools (13): status, list_apps, list_windows, get_app_state, click, drag, scroll, press_key, type_text, paste_text, set_value, select_text, secondary_action` | - |
| 9 | Daemon restart keeps `status` | Claude | pass | Agent created 01:26Z; daemon group stopped 02:21:29Z and restarted 02:21:41Z; the same agent's `status` returned `enabled: yes … helper: ready` | - |
| 10 | Settings screen | - | not covered | The test daemon serves no web UI (`GET /` 404), the web app is unbuilt, and covering it needs the web UI feature flag, a daemon restart and a browser window while the Mac was in use. Settings read/write was checked through the RPCs `settings.computer-use.read/write` | - |

## Fixes made during QA

| Fix | Problem | Regression test |
| --- | --- | --- |
| Text-only results | Success results carried a partial `structuredContent` (`{app}` or `{app, verification}`). Claude Code shows `structuredContent` instead of the text, so Claude never saw the tree, indexes, or the input-path line. Success results are now text only; screenshots still arrive as an image block (checked: `structuredContent: undefined`, `[image content]`). | `test/mcp-tools.test.ts` "returns read tool results as text only…" (fails on the old code) |
| Private event source | Hardening for "the plugin never shares the user's pointer": every posted event uses a private event source, no mouse-moved event before a click, and the shake detector counts only pointer events with source pid 0. Measured: real trackpad moves carry `srcPid=0` (15 samples); a synthetic HID Escape carries its poster's pid. With 5 ms sampling the pointer did not move during plugin click, scroll, and drag, before or after the fix; a click still toggles TextEdit's "align center" (0 -> 1, oracle). | `EscapeMonitorTests`: hardware-only pointer motion, private event source |
| Long-text timeout | `type_text` used the flat 30 s helper request timeout, but the helper types about one UTF-16 unit per 10 ms, so text over about 3000 units stopped part way with `helper_unavailable`. Repro with one caller: 5000 units, `timed out after 30000ms` at 3048 characters. The timeout is now 30 s plus 30 ms per unit. After the fix the same call ran 49.9 s and all 5000 characters arrived (`unverified` only because TextEdit capitalized the first letter, see Findings). | `test/helper-driver.test.ts` "gives long text enough time to finish typing" (fails on the old code) |
| Codex tool policy | Paseo's codex adapter turns `toolPolicy.preapproved` into an `enabled_tools` allowlist, so Codex saw only the 4 read tools. Codex now gets no tool policy; README documents it. | `test/paseo.test.ts` "injects for codex without a tool policy…" (fails on the old code) |

Gates after the fixes: `npx tsc --noEmit` exit 0; `npm run lint` 0 errors;
`npx vitest run` 11 files, 115 tests passed; `swift test` 80 tests (1 skipped), 0 failures.

## Findings not fixed

- **Earlier "user took control" aborts were real pointer motion.** Someone at the Mac was using
  the trackpad (smooth paths on the second display, `srcPid=0`). The helper's events never moved
  the pointer in any measurement.
- **The oracle CLI's Escape key press does not stop the plugin.** That CLI posts the key to the app,
  so the helper's session event tap never sees it. Scenarios 3 to 5 used an Escape posted at the
  HID tap, which is the path a physical key takes.
- **`type_text` with `element_index` sets `AXFocused` but TextEdit does not take the paste
  until the text area is clicked.** The result is honestly `unverified: field value did not
  change`; agents recovered with a click or `set_value`.
- **Keystroke typing races TextEdit's auto-capitalization.** `type_text` read back `xin chào`
  (`verified`), and TextEdit changed it to `Xin chào` afterwards.
- **Cmd+N to a windowless TextEdit.** The key events do create documents (`Untitled 2/3` in one
  run), but while TextEdit is hidden its windows are off screen, so `list_windows` and
  `get_app_state` show nothing until the app is shown. There is no tool to show an app; agents
  used `open -a TextEdit`. This is a design question, not a key-delivery bug.
- **Whether the oracle CLI itself moves the cursor** was not measured; QA avoided its clicks
  and used it only for AX reads, window lists and key presses.
- **The helper window cache** keeps the last read window; after that window closes, actions return
  `action_failed` ("window … closed") until `get_app_state` runs again.
- **Oh My Pi adds an `i` (intent) field to every tool call.** The plugin's strict schemas reject
  it (`invalid_arguments … Unrecognized key`); the agent retries without it, so each run loses one
  or two calls. Fixed after QA: a string `i` is dropped before parsing; other unknown
  keys still fail (`test/mcp-tools.test.ts` "ignores the intent field Oh My Pi adds…"). Live check
  at 10:15Z under ABC: a real Oh My Pi agent sent `i` on all 8 calls (`status` through `set_value`),
  0 `invalid_arguments`, and the oracle read `Untitled 24` = `xin chào` (NFC).
- **"The window shows in `list_windows` but the snapshot did not include it"** (a Claude agent in
  the follow-up run) is not a plugin bug. From 03:25:16Z to 03:25:23Z the on-screen window list
  and the AX tree both had no TextEdit window (header `window: 0`, no `AXWindow`); at 03:25:28Z
  `list_windows`, which reads the same on-screen list (`AXEngine.swift` `listWindows`), showed it
  again and the next `get_app_state` included it. The agent compared reads from different moments.
- **Claude cannot emit a very long tool argument reliably.** A Claude agent asked to `type_text`
  8000 characters took 10 minutes to stream the argument in one run and in another looped on
  `type_text` with only `{app}`. Scenario 5 therefore uses the first two-agent run.
- **Audit** does not list a call stopped by Escape in some runs (the OMP run at 01:49Z).
- **No provider transcript keeps the result of a stopped call.** Claude discards it, Codex writes
  its own `aborted by user after …` output, and Oh My Pi records no tool result. In the Codex run
  Codex wrote its text 37 ms before the plugin finished the cancel, so the agent never waits for
  the plugin's answer. Only a client that stays connected (the direct client) sees `aborted_by_user`.
- **Scenario 4 retries.** The first Oh My Pi Stop run (05:24Z) ended before `type_text` because
  the prompt said to stop on any error and the `i` key was rejected; the rerun allowed a retry.
  The first fallback run (05:28Z) used `sleep 120`, which Claude Code refuses to run in the
  foreground, so Stop came after typing ended; the rerun used a Python wait.

## Blockers and environment

- **Telex, follow-up run.** With the machine owner's consent, `TISEnableInputSource` on the parent
  `com.apple.inputmethod.VietnameseIM` and `TISSelectInputSource` on Simple Telex ran just before
  the Codex and Oh My Pi runs, and `TISSelectInputSource(ABC)` plus `TISDisableInputSource(parent)`
  ran in an exit trap after them, twice (02:33Z-02:35Z, 05:11Z-05:13Z). The first pair proved
  nothing because TextEdit was hidden and the oracle saw no window; the second pair showed the
  process before the read. Final state, read at 05:13:23Z and again before commit:
  `current=com.apple.keylayout.ABC | com.apple.inputmethod.VietnameseIM enabled=0 selected=0 |
  …VietnameseSimpleTelex enabled=1 selected=0 | com.apple.keylayout.ABC enabled=1 selected=1`,
  equal to the state read at 02:28:35Z before any change.
- **Telex, first QA run.** The Claude Telex pass (01:45Z) ran after QA had enabled the parent Vietnamese input
  method with `TISEnableInputSource`, which the machine owner later ruled out. Later, TIS no
  longer listed `com.apple.inputmethod.VietnameseIM.VietnameseSimpleTelex` as enabled (its parent
  input method reported disabled), and under that rule only selection is allowed. The final
  Codex and Oh My Pi runs therefore ran under ABC. A third-party Vietnamese input app ran on the
  test machine and TextEdit activation switched the source back to ABC in one run.
- Input source changes made during QA are listed in the report. ABC was selected at the end
  (02:23:04Z).

## Cleanup

All 23 test agents archived. Dev daemon process groups stopped; the test port was free; the everyday daemon untouched.
Samplers and probes stopped; no helper process left. TextEdit (launched by a QA AppleScript call)
quit without saving. Passwords quit.
Follow-up run: 9 more test agents archived, TextEdit test documents closed without saving and
TextEdit quit, dev daemon stopped (test port free), input-source watcher stopped; the everyday daemon and
its Paseo home untouched.
Scenario 4 Stop run (05:21Z-05:31Z): 5 test agents archived, TextEdit documents closed without
saving and TextEdit quit, dev daemon stopped (test port free), no helper or poller left. The input
source read ABC at the start, after the Codex run and at the end (05:31:45Z); no system setting was changed and no oracle click was used.
