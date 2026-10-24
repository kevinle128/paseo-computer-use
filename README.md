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
  - **Screen Recording**: needed for screenshots.

  After you grant a permission, quit and reopen that app. macOS applies the grant only to new
  processes.

## Install

```bash
paseo plugin install github:kevinle128/paseo-computer-use
paseo plugin ls
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
| `list_windows` | Open windows with id, app, title, and bounds |
| `get_app_state` | The app's accessibility tree with element indexes, plus an optional screenshot |

Action tools (each one returns `verified` or `unverified: <reason>` and the new state):

| Tool | What it does |
| --- | --- |
| `click` | Click an element by index, or a point in window coordinates |
| `drag` | Drag between two points in window coordinates |
| `scroll` | Scroll an element or a point by a number of pages |
| `press_key` | Press a key or chord, for example `Return` or `Command+s` |
| `type_text` | Type text into the focused element |
| `paste_text` | Paste text through the clipboard, then restore the clipboard |
| `set_value` | Replace the value of an editable element |
| `select_text` | Select text in an editable element, or place the cursor before or after it |
| `secondary_action` | Perform a named accessibility action, for example `AXShowMenu` |

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
- **Esc listener.** While an agent has control, the helper watches key presses to catch
  Esc and pointer movement to detect a shake. It swallows Esc, passes every other event through
  unchanged, and stores nothing.
- **Paseo Stop.** The Stop button on an agent cancels its running action and releases control.
- **Deny list.** These apps are always blocked and are never read: Keychain Access,
  Passwords, the login window, the system password prompt (SecurityAgent), 1Password
  (including 1Password 7 and its Safari extension), Bitwarden, Dashlane, LastPass, NordPass,
  and Proton Pass. Add more bundle ids under **Extra blocked apps** in settings. A blocked app
  returns `app_blocked`.
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

The Swift helper and the plugin are original code. Orca (MIT license) was a design inspiration
for typed accessibility tools, no per-app approval, and an observe, act, verify loop, and the
public computer-use tool names (`get_app_state`, `click`, `secondary_action`, and so on)
follow its naming.
