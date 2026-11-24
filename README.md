# Xcode Agent Bridge

Select code in Xcode, press **⌃⌥Space**, and ask **Claude Code** or **Codex** about it, or have them change it, from a small panel that opens next to your selection.

Questions can go to a **session that's already running** in your terminal, with Claude or Codex working there. They can also go to a **new session** that the app starts and that answers only in the panel. Either way it's your own `claude` or `codex`, so your CLAUDE.md / AGENTS.md, MCP servers, plugins, logins and model choices all apply.

## Requirements

- macOS 15 or later, Xcode, and Swift 6.2 or later to build.
- At least one of:
  - [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude`)
  - [Codex CLI](https://github.com/openai/codex) (`codex`)
- Accessibility permission, used to read the selection in Xcode.

## Install

```sh
scripts/build-app.sh --install
```

This builds `Xcode Agent Bridge.app`, copies it to `~/Applications` and launches it. The app appears in the menu bar. The first time it runs, macOS asks for Accessibility access. Allow it under **System Settings ▸ Privacy & Security ▸ Accessibility**.

The build script signs the app with your first *Apple Development* identity, so the permission survives rebuilds. Set `CODESIGN_IDENTITY` to pick a different one. With ad-hoc signing (`-`), macOS asks for the permission again after every build.

## Use

1. Select code in Xcode. Nothing selected means the line under the cursor.
2. Press **⌃⌥Space**. The panel opens under the selection, and Xcode stays the active app. It stays next to that code as you scroll. It hides while the code is out of view or another file is showing, and comes back when the code does. If you drag the panel somewhere else, it keeps that position relative to the code.
3. Type a question and press **⏎**. Press **⏎** with nothing typed to get an explanation.

| Key | Action |
| --- | --- |
| ⏎ | Send |
| ⌘⏎ | Add the text as a pending comment on the selection (while editing a comment: save it) |
| ⌘⇧⏎ | Open the Pending Comments window to review and send them all |
| ⌘E | Explain the selection |
| ⌘1 / ⌘2 | Ask mode / Change mode |
| ⌘⇧A | Switch target (running sessions, New Claude, New Codex) |
| ⌘. | Stop the agent (running sessions: stop following; the agent keeps going) |
| ⌘N | New conversation (forget the agent session) |
| Esc / ⌘W | Close the panel |

- **Ask mode** is read-only. The agent can read and search the project but not edit it.
- **Change mode** lets the agent edit files in the project. If the file has unsaved edits, the app saves it in Xcode first. When the agent finishes, Xcode reloads the changed files, and the panel lists every file the agent touched. Click one to open it.

Each place you open a panel gets its own panel, pinned to that code until you close it with **Esc** or ×, like inline threads on a pull request. Only the panel you're typing in is expanded. The others shrink to their comments and replies, and clicking one expands it. Pressing the shortcut on code that already has a panel brings that panel back. Pressing it while typing in a panel closes that panel. Closing the panel while an agent is working doesn't stop it: press the shortcut to get back to it.

## Collecting comments

To review a change, leave comments as you go and send them all at once instead of one question at a time:

1. Select code, press **⌃⌥Space**, type a comment and press **⌘⏎**. The comment appears under the code in the panel as a pending review comment, like on a GitHub pull request. The panel shows only the comments on its own code. Press **Esc** to go back to Xcode and select the next piece of code, in this file or another.
2. Each comment has a **⋯** menu with **Edit** and **Delete**. Double-clicking a comment also edits it. While editing, **⌘⏎** saves the change and **Esc** cancels it.
3. To see every comment, press **⌘⇧⏎** in the panel, click **Review & send…**, or choose **Pending Comments…** from the menu bar icon. The **Pending Comments** window lists the comments grouped by file, each under its code. Click the code or the file name to jump to it in Xcode. Comments can be edited and deleted here too.
4. In that window, choose where the comments go and **Ask** or **Change**, then press **Send all** (**⌘⏎**). They go as one numbered message. In **Ask** mode the agent answers each comment. In **Change** mode it addresses each one by editing the files and reports per comment. Before a Change, Xcode's **Save All** runs, so the agent sees your latest edits. The reply appears in the window under **Sent**.

Each comment sends the whole lines it covers. A comment on a blank line also sends three lines above and below, so the agent can see where it is.

Comments are kept until you send or delete them, even across restarts of the app. If a send fails, **Put the comments back** returns them to the list.

## Sending to a running session

The menu at the top of the panel lists the Claude and Codex sessions running on your Mac, with the ones in the same project first, and whether each is idle or busy. When one is running in the project, it's chosen automatically. You can turn that off in Settings. Pick **New Claude session** or **New Codex session** to have the app start its own session instead.

A question sent to a running session shows up in that session's terminal as if you'd typed it, even if the session was idle. The answer appears there and in the panel. **⌘.** stops the panel from following along; the agent keeps working in its terminal.

- **Claude Code** sessions need no setup. Claude Code v2.1.224 and later listens for messages from other sessions on a local socket ([cross-session messaging](https://code.claude.com/docs/en/cross-session-messaging)). The app reads `~/.claude/sessions/` to find the sessions and sends the question to the session's socket. It then follows the session's transcript in `~/.claude/projects/` to show the reply.
  - Depending on its permission mode, a session may ask you in the terminal to approve a message from another session. Sessions running with bypass permissions always ask. To skip the prompt, add `"crossSessionInbound": "accept"` to `~/.claude/settings.json`. Only do that if you're comfortable with any process running as your user being able to prompt your sessions.
- **Codex** sessions need Codex's shared background server. Start it from the panel's menu (**Reach running Codex sessions…**) or with `codex app-server daemon start`. Codex sessions you start after that connect to it automatically. The app lists them through the server and starts a turn on the one you pick. Sessions that were already open before the server started can't be reached.

## How it works

- **Selection:** read through the Accessibility API from Xcode's focused source editor:
  - the editor's text and selected range;
  - the document's file URL;
  - the selection's on-screen bounds, used to place the panel.
- **Working directory:** the enclosing git repository, else the nearest Swift package or Xcode project.
- **Prompt:** the selected code with its path and line numbers, plus your question. It is written to the agent's standard input.

The agents are run like this:

| | Claude Code | Codex |
| --- | --- | --- |
| Command | `claude -p --output-format stream-json --verbose --include-partial-messages` | `codex exec --json --skip-git-repo-check` |
| Ask | `--permission-mode default --disallowedTools Edit,Write,MultiEdit,NotebookEdit` | `-c sandbox_mode="read-only"` |
| Change | `--permission-mode acceptEdits` | `-c sandbox_mode="workspace-write"` |
| Follow-up | `--resume <session>` | `exec resume <thread>` |

In Change mode, Claude can edit files, but shell commands are still denied because no one is there to approve them. Codex runs with `approval_policy="never"` inside its sandbox. The list of changed files comes from the agents' own events plus a comparison of `git status` before and after the run, so edits made through shell commands are found too.

## Settings

Open them from the menu bar icon ▸ **Settings…**:

- default agent and shortcut;
- the path to each CLI, if it isn't found automatically. The app checks your login shell's `PATH` and common install locations;
- the model for each agent;
- **Save the file in Xcode before a Change**, on by default;
- **Continue my latest CLI session**: new conversations start from the agent's most recent session in that project. Claude forks it, so a session open in your terminal is left untouched. Codex appends to it.

## Development

```sh
swift test                                              # unit tests
XAB_LIVE=1 swift test --filter LiveAgentTests           # runs the real claude and codex in a scratch repo
swift build && .build/debug/XcodeAgentBridge --probe    # print what the app reads from Xcode
.build/debug/XcodeAgentBridge --ask claude "question"   # ask about the current selection from the terminal
.build/debug/XcodeAgentBridge --render panel.png        # draw a sample panel offscreen
.build/debug/XcodeAgentBridge --agents                  # list running Claude and Codex sessions
.build/debug/XcodeAgentBridge --send NAME "question"    # send a question about the selection to a running session
```

Run from a terminal, the binary uses the terminal's Accessibility permission.

- `Sources/BridgeCore`: selections, prompts, command lines, output parsers and git snapshots. It has no UI and is tested.
- `Sources/XcodeAgentBridge`: the menu bar app, Accessibility capture, hot key, panel and agent process runner.

## Limitations

- It reads Xcode's editor through Accessibility attributes that Apple doesn't document. A future Xcode could change them.
- Only the primary selection is used.
- Agents can't ask you for permission mid-run. Anything that would need approval is denied and shown as a warning in the panel.

## License

MIT. See [LICENSE](LICENSE).
