# Changelog

## 0.2.0 - 2026-10-28

### Added

- `wait_for` tool. It waits until the app reaches one of up to 4 conditions: an element
  appears, disappears, or changes state or value; a window opens or closes; the tree settles;
  or the window image settles or changes (`visual_stable`, `visual_changed`). It checks every
  300 ms, waits 5 seconds by default and 30 seconds at most, and takes no control lock. The
  visual conditions compare small grayscale signatures on your Mac; no image reaches the agent.
- Screenshot for sparse windows. In Auto and Always modes, a window with fewer than 3 indexed
  controls (a canvas, a game, a remote desktop, some Electron views) comes back with a
  screenshot, so the agent can act with window coordinates. In a browser tab only the web area
  counts.
- One window per read. `get_app_state` reads the app's focused window, or the window you pass
  with `window_id`, and lists the app's other windows on one `Other windows:` line with their
  ids. Every action tool takes `window_id` too.
- Actions stay on the window the agent read last, even when the app focuses another window.
  The result then says `focused window is now [id] "title"`. When that window is closed, the
  tool returns `window_gone` and does nothing. When the app moves to another window during a
  long `type_text`, typing stops with `user_active` and says how many characters were typed;
  the agent waits, reads the app again, and types the rest.
- Collapsed menus. A closed menu shows only its title and item count, which keeps results
  small. `query` searches the window and the menus; `include_menus` prints all menu items.
- Menu items show their check mark state as `checked` or `mixed`.
- `changed:` lines. For actions the helper cannot check (click, drag, scroll, key press,
  secondary action), the result says what the plugin saw change: a window that opened or
  closed, a title or focus move, or other content. It is evidence that something happened, not
  proof of the intended effect.
- Command+w closes with the close button. `press_key` with Command+w alone presses the close
  button of the target window, or of its selected tab, without sending a key or bringing the
  app forward.
- Focus guard. The helper checks which app is in front before and after each action. When it
  changed, the result starts with `user_focus_changed`. For 2 seconds after an action, if the
  target app takes the front from you, the helper brings your app and window back once, and
  holds screen updates for at most 250 ms to hide the switch. When only the keyboard
  focus moved to the target, it gives the keys back to your window. It does not restore when it
  looks like you switched apps yourself.
- Pause while you use the target app. If you pressed a key in the agent's app, or clicked or
  scrolled over one of its windows, in the last 3 seconds, an action there does nothing and
  returns `user_active`. The agent waits, reads the app again, and retries; acting before that
  read returns `stale_state`. Input to other apps never pauses the agent. The helper reads the
  macOS system idle clocks (seconds since the last key press, mouse button press, and scroll)
  and keeps a short click and scroll log: for each mouse button press and scroll, its time,
  position, and the frame and owning process id of each window under the pointer, plus the
  times at which apps came to the front. The log is in memory only for 4 seconds, never records
  key presses or content, and runs only while an agent has control, which starts only when
  Computer Use is on. For
  the first 3 seconds of control, a click or scroll counts only when the agent's app is in
  front.
- Web browsers are refused by default. Chrome, Safari, Edge, Arc, Brave, Firefox, other
  browsers, and browser web apps return `use_browser_tools`, so agents use Paseo's browser tools
  for web pages. `list_apps` and `list_windows` still list them.
- New setting: **Allow Computer Use in web browsers** (off by default) lets agents use your
  browsers like any other app.

### Changed

- Key presses, `type_text`, and `paste_text` first make the target window the app's key
  window without raising it. They send nothing, and say why, when the app does not accept that
  window within about 300 ms or does not answer within 1.5 seconds.
- Screenshot mode labels in settings now say when Auto sends a screenshot and that "AX tree
  only" sends no screenshot to the agent.
- `secondary_action` refuses `AXRaise`.

## 0.1.0 - 2026-10-24

First public release.
