Computer Use lets your coding agents work in native macOS apps. An agent reads an app's accessibility tree, acts on a named element (click, type, scroll, press a key, set a value), and gets the new state back so it can check the result. The tools are typed. There is no code-execution tool, so agent input is only data for these tools.

A small Swift helper does the macOS work. The plugin compiles it with `swiftc` the first time it starts and caches it in `~/Library/Caches/paseo-computer-use`, so you need macOS 14 or later and the Xcode Command Line Tools.

To set it up, open the Computer Use settings screen, read the warning, and turn on Enable Computer Use. It is off by default, and while it is off no agent gets the tools. Grant two macOS permissions to the app that runs the Paseo daemon (Paseo, or the terminal you started the daemon from): Accessibility to read and control apps, and Screen Recording for screenshots. The settings screen shows each permission and opens the matching System Settings pane. After a grant, quit and reopen that app.

The settings screen also has a switch per provider. Claude, Codex, and Oh My Pi are supported. New agents of an enabled provider get the tools; agents that already run do not. Claude runs the read tools without a prompt and asks before each action in a prompting permission mode. Codex and Oh My Pi follow their own permission mode for every tool. In bypass, auto, or full-access modes nothing prompts. Other settings add extra blocked apps by bundle id and choose when results include a screenshot.

Computer Use acts as you, so it has these controls:

- One agent controls the computer at a time. Another agent gets a busy error. Control is released when the owner's turn ends, its connection closes, or it is idle for 60 seconds.
- A halo marks the window the agent controls, and a virtual pointer with the agent's name shows each click point. Your own cursor does not move. The overlay is left out of screenshots and screen sharing.
- Press Esc, or shake the mouse, to stop the running action. While an agent has control, the helper watches key presses to catch Esc and pointer movement to detect a shake. It swallows Esc, passes every other event through unchanged, and stores nothing. Paseo's Stop button also cancels it and releases control.
- Keychain Access, Passwords, the login window, the system password prompt, and common password managers (1Password, Bitwarden, Dashlane, LastPass, NordPass, Proton Pass) are always blocked and never read.
- Password field values never reach the agent.
- A paste restores your full clipboard afterwards and marks the pasted text as transient. When Telex, VNI, or another input method is active, typing uses a paste, because keystrokes through an input method change the text.

The plugin runs on your Mac and makes no network calls of its own. Tool results do leave your Mac: the accessibility text, typed text, and screenshots that a tool returns go to the agent, and the agent sends them to its model provider. The agent reaches the plugin through a local Unix socket, the helper runs as a local process, and the last 200 tool calls are kept in memory for the settings screen. The plugin writes only these files: the cached helper in `~/Library/Caches/paseo-computer-use`, and under `~/.local/state/paseo-computer-use/<key>/` the MCP launcher script in `bin/`, the socket `mcp.sock` (falling back to `/tmp/paseo-cu-<uid>-<key>.sock` when that path is too long for a socket), and `client-bindings.json`, the map of MCP connections to agents.

Known limits: OpenCode is not tested and not enabled. System Settings is not blocked by default; add `com.apple.systempreferences` to the extra blocked apps if an agent in a bypass mode must not change it. When the plugin cannot tell which agent owns a connection, Stop on any agent cancels that owner's running action.
