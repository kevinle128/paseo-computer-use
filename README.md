# Computer Use for Paseo

A Paseo plugin that lets coding agents use native macOS apps. Agents get typed MCP tools:
they read an app's accessibility tree, act on a named element (click, type, scroll, press a
key), and get the new state back to check the result. A small Swift helper does the macOS
work; the plugin decides who may act, on which app, and when to stop.

## Requirements

- macOS 14 or later.
- Xcode Command Line Tools (`xcode-select --install`). The plugin compiles its Swift helper
  with `swiftc` on first start and caches it in `~/Library/Caches/paseo-computer-use`.
- Paseo 0.12 or later.
- Two macOS permissions, granted to the app that started the Paseo daemon. That is Paseo.app
  when the desktop app runs the daemon, or the terminal app you started the daemon from:
  - **Accessibility**: needed to read and control apps.
  - **Screen Recording**: needed for screenshots and for the visual conditions of `wait_for`.

  After you grant a permission, quit and reopen that app. macOS applies the grant only to new
  processes.

## Install

```bash
paseo plugin install github:kevinle128/paseo-computer-use
paseo plugin ls
```

To update to a newer release:

```bash
paseo plugin update computer-use
```

Once the plugin is listed in the Paseo plugin registry, you can also add it from there.

Then open Paseo's settings, go to **Computer Use**, read the warning, and turn on
**Enable Computer Use**. The same screen shows whether each permission is granted, with an
**Open System Settings** button for each one.

## Supported providers

Claude, Codex, and Oh My Pi (`omp`). The settings screen has a switch per provider. New agents
of an enabled provider get the `paseo-computer` MCP server; agents that already run do not.

## Tools

Read tools (they cannot change the screen):

| Tool | What it does |
| --- | --- |
| `status` | Permissions, helper state, input source, and which agent has control |
| `list_apps` | Desktop apps with bundle ids and whether they run |
| `list_windows` | Open windows with id, app, title, and bounds. Only normal windows count: layer 0, not transparent, at least 16x16 points. Menus, tooltips, and overlays are left out, and `get_app_state` picks its default window from the same list |
| `get_app_state` | One window of the app (its focused window, or the `window_id` you pass) with element indexes, the menu bar, and any sheet or popup over the window. The app's other windows appear on one `Other windows:` line with ids and titles, so the result stays small with many windows. A closed menu shows only its title and item count; `query` searches the window and the menus, and `include_menus` prints all. A screenshot comes on request, or on its own when the window has fewer than 3 indexed controls (the window, menu bar, and title-bar buttons do not count) |
| `wait_for` | Wait until the app reaches one of up to 4 named conditions (an element appears, disappears, or changes state or value; a window opens or closes; the tree or the window image settles or changes). Polls every 300 ms, 5 s by default, 30 s at most. It watches the window you last read (or `window_id`) and takes no control lock |

Action tools (each one returns `verified`, `changed: <what>`, or `unverified: <reason>`, and the new state). `changed:` is for the actions the helper cannot check (click, drag, scroll, key press, secondary action): the plugin saw a top-level window open or close (the line names its id, for example `changed: window closed [38229] "New Tab"`; a sheet or popover is a content change, not a window), a title or focus move, or the content differ (`menu items` when only the items of a closed menu differ). Progress indicators are ignored, but a clock or live output can still change the content. It is evidence, not proof of the intended effect:

| Tool | What it does |
| --- | --- |
| `click` | Click an element by index, or a point in window coordinates |
| `drag` | Drag between two points in window coordinates |
| `scroll` | Scroll an element or a point by a number of pages |
| `press_key` | Press a key or chord, for example `Return` or `Command+s` |
| `type_text` | Type text into the focused element |
| `paste_text` | Paste text through the clipboard into the focused element, or into `element_index`, then restore the clipboard. It inserts at the insertion point and keeps the text the field holds; to replace it, use `set_value`, or `select_text` first |
| `set_value` | Replace the value of an editable element |
| `select_text` | Select text in an editable element, or place the cursor before or after it |
| `secondary_action` | Perform a named accessibility action, for example `AXShowMenu` |

Every action tool takes an optional `window_id`. Without it, an action goes to the window of the agent's last `get_app_state` of that app, even when the app focuses another window afterwards (a closed window makes the app focus another one, often a window of the user's). Such a move adds the line `focused window is now [id] "title"` to the result and never changes the target. When the window is gone, the tool returns `window_gone` and does nothing; the agent reads the app again to choose a window. Key presses, `type_text`, and `paste_text` first make the target window the app's key window without raising it, and send nothing (`unverified: could not focus window [id] (the app reports [other id] as focused)`, or `(the app reports no focused window)`) when the app does not make that window its key window within about 300 ms, and `(the app did not answer in time)` when a slow or hung app does not answer within 1.5 s; the line also says to act on the window's elements (`click`, `secondary_action`, `set_value`) or ask the user. Command+w alone is the exception: it presses, with `AXPress` (no event, no activation), the close button that closes what Command+w would close. A window with no tab bar or with one tab uses its own close button and reports `changed: window closed [id] "title" (closed with its close button)`. A window with more tabs (Chrome, Safari, Terminal, Finder, VS Code) uses the selected tab's close button and reports `unverified: closed the selected tab of window [id] with its close button`; when there is no single such button, nothing is pressed and the refusal above is returned. A press the app does not answer in time reports `unverified: close button pressed, window state unknown`. An app that is not in front (the restore gave the front back) may report no focused window, or a stale one; the target window's own `AXFocused` and `AXMain` then decide, unless a panel or sheet of another window holds the keys. `type_text` and `paste_text` with an `element_index` also send nothing (`unverified: could not focus element [index]`) unless the app reports that element, or one inside it, as its focused element. An app that does not report its focused window at all (Java, Qt, some Electron builds) gets the keys when the target is its only window. Floating, utility, and modal panels that do not cover the window appear on the `Other windows:` line, so `window_id` reaches them. An untitled window under the window's toolbar that holds only a list of rows (a browser's address suggestions) is not listed and does not count as a window that opened or closed. Every other untitled window is read and listed like any window, so a permission or save-password bubble stays visible and is reported when it opens. When an action changes several things, the result has one `changed:` line for each, up to four. A window the action opened can be focused before the app lists it; the read after the action then reads again, up to 3 times in 300 ms, so the result says `window opened` and `Other windows:` names it. During a long `type_text`, if the app moves to another window, typing stops with `user_active` and says how many characters were typed: the user is probably using the app, so the agent waits, reads the app again, and types the rest.

Computer Use is built not to take the user's focus: it never raises a target window, never activates, hides, or deactivates the target app, and does not move the real pointer. Clicks, drags, and key presses do post private window server records that make the target window look active to the app itself; live tests show the frontmost app staying put, and the check below is how a failure shows. The helper reads which app is in front before each action and after it. When that changed, the result starts with `user_focus_changed: <old> -> <new>` and the audit entry records the same text, also for an action that failed; a change that came after the action finished is reported at the next action. It can also be your own switch of apps. When no regular app is in front (a launcher such as Alfred, or a system panel such as Spotlight or Control Center, is open), the helper treats your app as unknown: it prints no line, starts no watch, and gives nothing back, and the audit entry records the change as `front_app_unknown: <old> -> <new>`; the next action compares with the last app that was known. For 2 seconds after each action the helper keeps watching the frontmost app (it asks the window server every 20 ms, and also looks on each app activation), and when an app other than the one that was in front takes the focus (some apps activate themselves a moment after a key such as `Command+n`), it brings the previous app back, once. Only macOS's own frontmost app (AppKit's answer, regular apps only) decides: the window server's answer only makes the helper look sooner, and a change that AppKit does not confirm is neither undone nor reported. The restore reads your current window, holds screen updates (250 ms cap), posts the action's own window records to the target again so it keeps acting as the active app for the agent, asks the window server to bring your window back to the front and make it your key window (or asks your app to activate when that request is not available), and then lets the screen update. A watchdog on its own queue ends the hold after 250 ms, also when the helper's main thread is stalled; it waits at most for one window server call in flight, because every private window server call of the helper goes through one lock. The audit records the measured hold. When the hold is not available the same steps run without it. When in doubt it does not restore. It restores only when the app that took the focus is the app the action was aimed at, or a process launched after the action started. Any other app taking the focus is probably your choice and is only reported: `(not restored: another app took focus)`. It also does not restore when, after the action started, you pressed a key while Command, Control, or Option was held or released one of those keys (the end of a Command+Tab), or when you pressed or released a mouse button from just before the app came to the front until the restore (for a process the action launched, any key or click from one second before the action started); the line then says `(user switched apps)`. Typing without those modifiers does not count: when you type in the app you were using and the target takes the focus, your app gets it back. The same rules apply to the keyboard alone: when your app stays in front but a window of the target takes the keys because of the action, the helper gives the keys back to your window with the key window records only, without activating the target or bringing your app forward, so a menu or popover you have open there is not closed by a front request, and the line says `user_focus_changed: key focus <old> -> <new> (returned after N ms)`. After `press_key`, `type_text`, or `paste_text`, which post those records to the target themselves, it does this only when macOS also says your app lost the front; a click in that window keeps the keys there (`(user moved the keyboard focus)`). Moving the pointer and scrolling do not count, so reading on the Mac while the agent works does not keep the app in front; a trackpad gesture that switches apps is not seen. macOS may refuse to let a background helper bring an app to the front; the line then says `(could not restore)`, so do not count on the restore working. A restore that finishes during the action's own settle wait (60 ms) is shown in that action's result; a later one is shown at the next action of the same agent, for example `user_focus_changed: <old> -> <new> (restored after N ms)`. The watch ends when the next action starts (it first waits a moment for a restore already asked for), on Escape, when the Escape key is released at the end of a turn, and at the end of the turn; an action that began before such a stop never starts one, and a stop after the restore was asked for may not undo it (`(stopped; the restore may still apply)`). Limits: the other app is in front for a few polls before the restore, so a brief flash can still be seen when the screen hold is not available or does not cover other apps' windows, and a line for a restore that happened after the last action of a turn is shown at the next action. The window server calls for the front process, the window request, and the screen hold are private and may change with macOS; when one is missing the helper uses the public path. `secondary_action` refuses `AXRaise`.

In Auto and Always screenshot modes, a window whose tree has fewer than 3 indexed controls
(the window itself, the menu bar, and the title-bar buttons do not count; a canvas, a game, a
remote desktop, some Electron views) comes back with a screenshot, in `get_app_state` and
after every action. When the window has a web area (a browser tab), only its largest web
area is counted, so a canvas page in a browser with many toolbar buttons counts as sparse. The agent then acts with `x` and `y` window coordinates. Without the
Screen Recording permission the result keeps the tree and adds one line that names the
permission.

Never mode sends no screenshot to the agent. The `visual_stable` and `visual_changed`
conditions of `wait_for` still capture the window in every mode: the helper reduces each
capture to a 64x40 grayscale signature, compares it on your Mac, and discards it. Neither the
image nor the signature reaches the agent.

There is no code-execution tool. Agent input is data for these tools only.

## Safety model

Computer Use acts as you. Read this before you turn it on.

- **Opt-in.** The setting is off by default. When it is off, no agent gets the tools.
- **Provider prompts.** Action tools are not preapproved, so a provider in a prompting
  permission mode asks you before each action. For Claude, read tools are preapproved and do
  not prompt. Codex and Oh My Pi follow their own permission mode for every tool, read tools
  included (see Limitations for why Codex gets no preapproval).
- **Bypass and auto modes.** When a provider runs with bypass, auto, or full-access
  permissions, nothing prompts. Then the controls are only the setting, the one-owner lock,
  Esc, Paseo's Stop button, and the deny list below.
- **One owner.** One agent controls the computer at a time. Another agent's action gets
  `computer_busy`. Control is released when the owner's turn ends, its connection closes, or it
  is idle for 60 seconds.
- **Overlay.** While an agent acts, a halo marks the window it controls and a soft virtual
  pointer, labelled with the agent's name, glides to each click point; your own cursor never
  moves. The pointer fades
  about 1.5 seconds after an action. The overlay goes away when the agent gives control back,
  and on its own after 5 seconds with no action. It is left out of screenshots and screen
  sharing.
- **Esc and takeover.** Press Esc, or shake the mouse, to stop the running action at once. The
  agent gets `aborted_by_user` and must stop for that turn.
- **Pause while you work in the same app.** An agent does not act in an app while you use that
  app. When, in the last 3 seconds, you pressed a key while that app was in front, or pressed a
  mouse button or scrolled over one of its windows, an action there is not sent (a long `type_text`
  you interrupt stops part way and says how many characters it typed) and the agent gets
  `user_active`: it waits a few seconds, reads the app again, and retries. Input to any
  other app, Paseo included, never pauses it, so you can keep working while the agent works in
  a background app. Moving the pointer does not count. Read tools and `wait_for` keep working.
  After such a refusal the agent must call `get_app_state` for that app before it acts there
  again, or it gets `stale_state`. The audit log records each refusal. To know when you last
  acted, the helper reads macOS's system idle clocks: the seconds since the last key press,
  mouse button press, and scroll. These are times only, with no key or content.
- **Click and scroll log.** To tell which app a click or scroll went to, the helper keeps a
  short log. For each mouse button press and scroll it keeps the time, the screen position, and
  the frame and owning process id of each on-screen window under the pointer. It also keeps the
  times at which apps came to the front. The log is in memory only. Entries older than 4 seconds
  are never used; they are removed at the next click or scroll, and the whole log is cleared
  when control ends. It never records key presses or any content (no text, no window titles, no
  images), and it never changes or delays an event. It runs only while an agent has control:
  it starts when Computer Use is on and an agent takes control for its first action, and stops,
  dropping what it holds, when control is released (turn end, Stop, a closed connection, or 60
  seconds idle) or when you press Esc or shake the mouse. A status check or the settings screen
  never starts it. Turning Computer Use off refuses the agent's next action; control, and the
  log with it, ends at the turn end or after 60 seconds idle.
- **Esc listener.** While an agent has control, the helper watches key presses to catch
  Esc and pointer movement to detect a shake. It swallows Esc, passes every other event through
  unchanged, and stores nothing.
- **Paseo Stop.** The Stop button on an agent cancels its running action and releases control.
- **Deny list.** These apps are always blocked and are never read: Keychain Access,
  Passwords, the login window, the system password prompt (SecurityAgent), 1Password
  (including 1Password 7 and its Safari extension), Bitwarden, Dashlane, LastPass, NordPass,
  and Proton Pass. Add more bundle ids under **Extra blocked apps** in settings. A blocked app
  returns `app_blocked`.
- **Web browsers.** Agents use Paseo's browser tools for web pages. Those tools work in Paseo's
  own browser in the background, while a browser in the background can bring itself to the
  front for a key press such as Command+n and interrupt you. So Chrome, Safari, Edge, Arc,
  Brave, Firefox, and the other browsers in `server/computer-use-mcp/policy/browsers.ts` return
  `use_browser_tools` from every tool that reads or acts in an app; `list_apps` and
  `list_windows` still list them. Chrome and Safari web apps count as browsers. If a site needs a
  login, the agent asks you to sign in in Paseo's browser. If Paseo's browser tools are off, the
  agent asks you to turn them on in Paseo settings, or to allow web browsers in Computer Use
  settings. Turn on **Allow Computer Use in web browsers** in settings to let agents use your
  browsers like any other app. A browser you add to **Extra blocked apps** stays blocked
  (`app_blocked`) either way.
- **Secure fields.** Password fields are shown as `••••••••`; their values never reach the
  agent.
- **Clipboard restore.** A paste puts every item and type of your clipboard back afterwards. A
  copy you make during the paste is kept. The pasted text is marked transient, so clipboard
  managers that honor the marker do not record it.
- **Input methods.** When Telex, VNI, or another input method is active, `type_text` pastes the
  text instead of sending keystrokes, because keystrokes through an input method change the
  text. The result says which path it used.

## Limitations

- OpenCode is not tested and not enabled.
- Codex gets no preapproved tools. Paseo's Codex adapter treats a preapproved list as the
  only tools Codex may see, so preapproving the read tools would hide every action tool.
  In a prompting mode, Codex therefore asks before read tools too.
- Paseo's Stop button targets the right agent only when the plugin knows which agent owns the
  MCP connection. When it cannot tell, Stop on any agent cancels that unknown owner's running
  action, so Stop on an unrelated agent can interrupt it. This fails toward stopping.
- System Settings is not on the deny list. An agent in a bypass mode could change settings
  there; add `com.apple.systempreferences` to the extra blocked apps if you need that.
- The pause knows only your latest key press, and gives it to the app in front at that moment.
  If you type in the agent's app and then press a key in another app, the earlier keys no
  longer pause it. A panel that takes keys without coming to the front counts for the app in
  front. The log has nothing from before the agent took control, so for the first 3 seconds of
  each control period, and after macOS paused its event tap, the helper does not know where a
  click or scroll went, and counts it only when the agent's app is in front. A key pressed
  before the agent took control counts only when the agent's app is in front. A
  click on the app's Dock icon goes to the Dock, so it does not pause the app. The 3 second
  window is a first value, to be tuned in live use.
- A paste waits up to 1.5 seconds for the app to read the clipboard before it restores it. If
  the app never reads it, Esc during that wait returns after the wait ends.

## Development

The dev dependencies point at a Paseo checkout next to this one (`../paseo`), so clone
Paseo beside this repository first.

```bash
npm install
npm run embed:helper   # after any change under native/macos
npm run typecheck
npm run lint
npm test
npm run test:swift
```

See [docs/architecture.md](docs/architecture.md) for how the parts fit together.

## Data flow

The plugin and its helper run on your Mac, and the plugin has no network access of its own.
The tools return app accessibility text, any text an agent typed, and screenshots to the agent,
and those results go to the agent's model provider like any other tool output.

## Credits

The Swift helper and the plugin are written for this project.
The window server event record layout follows yabai (MIT).
Orca (MIT license) was a design inspiration for typed accessibility tools, no per-app approval,
and an observe, act, verify loop, and the public computer-use tool names (`get_app_state`,
`click`, `secondary_action`, and so on) follow its naming.
