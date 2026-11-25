# Let Claude control MotionAI

You can ask Claude to edit your videos in MotionAI for you: "open my
Delhi project, add a title at the start, put a slow zoom on every photo and
export it in 1080p". Claude works inside the MotionAI app on your PC. You
see every change happen live, and you can undo anything with **Undo**
(Ctrl+Z).

This works with:

- **Claude Desktop** (the Claude app for Windows), including Claude sessions
  that are connected to your PC,
- **Claude Code**,
- any other app that supports MCP (Model Context Protocol) servers.

It needs the **Windows** version of MotionAI.

---

## 1. Turn it on in MotionAI (once)

1. Open MotionAI.
2. On the home screen, click the **robot icon** at the top right
   (or open a project → **AI** tab → **settings** gear).
3. Under **Claude control**, switch on
   **Allow Claude to control MotionAI**.

It stays on (MotionAI remembers it) until you switch it off. When it is
off, nothing can connect.

## 2. Connect Claude Desktop (once)

**Easy way:**

1. In the same **Claude control** section, click **Add to Claude Desktop**.
2. **Fully quit Claude Desktop**: right-click the Claude icon in the
   taskbar tray (next to the clock) → **Quit**. Closing the window is not
   enough.
3. Open Claude Desktop again.

**By hand** (if the button shows an error):

1. Click **Copy config for Claude** in MotionAI. It copies something like:

   ```json
   {
     "mcpServers": {
       "motionai": {
         "command": "C:\\Users\\<you>\\AppData\\Local\\Programs\\MotionAI\\motionai-mcp.exe",
         "args": []
       }
     }
   }
   ```

   (MotionAI fills in the real path on your PC.)
2. In Claude Desktop: **Settings → Developer → Edit Config**. This opens
   `claude_desktop_config.json` (in `%APPDATA%\Claude\`).
3. If the file is empty or only has `{}`, replace everything with what you
   copied. If it already has `"mcpServers"`, add the `"motionai": { … }`
   part inside it (keep the other servers, mind the commas).
4. Save, then fully quit and reopen Claude Desktop (see above).

To check: in Claude Desktop, the tools/connectors menu in the chat box
should list **motionai**.

## 3. Ask Claude

Just type what you want, in English, Hindi or Hinglish. Examples:

- "MotionAI mein mera latest project kholo aur uska ek frame dikhao."
- "Make a new YouTube project called Fort Story, import
  `C:\Users\me\Videos\fort.mp4` and put it on the timeline."
- "Add a 3D title 'THE FORGOTTEN FORT' at the start with a slow push-in, then
  show me how it looks."
- "Add karaoke captions in Hinglish."
- "Export it in 1080p to my Desktop."

While Claude is working, MotionAI shows an orange **Claude connected**
pill at the top. Click it to see everything Claude did. Every edit is one
normal undo step.

If MotionAI is closed when Claude needs it, Claude starts it automatically
(Claude control must already be switched on).

---

## Claude Code

In MotionAI click **Copy Claude Code command** and paste it into a terminal.
It looks like:

```
claude mcp add --scope user motionai -- "C:\Users\<you>\AppData\Local\Programs\MotionAI\motionai-mcp.exe"
```

Then start `claude` and ask it to edit your video. `/mcp` shows whether
it is connected.

## Apps that connect by URL (remote HTTP MCP)

MotionAI also listens directly at

```
http://127.0.0.1:7820/mcp
```

(MCP "Streamable HTTP", JSON responses). Every request needs the header

```
Authorization: Bearer <token>
```

The token is shown (and can be copied) under **Claude control**. **Copy URL +
token (HTTP)** copies a ready config:

```json
{
  "mcpServers": {
    "motionai": {
      "type": "http",
      "url": "http://127.0.0.1:7820/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

For Claude Code over HTTP:

```
claude mcp add --scope user --transport http motionai http://127.0.0.1:7820/mcp --header "Authorization: Bearer <token>"
```

The address only works on the same PC (127.0.0.1). The port can be changed
under **Claude control → Port** if 7820 is busy.

Debugging with curl:

```
curl -H "Authorization: Bearer <token>" http://127.0.0.1:7820/api/state
curl -H "Authorization: Bearer <token>" -X POST -d "{\"time\": 2}" http://127.0.0.1:7820/api/tools/seek
```

---

## What Claude can do (tools)

| Tool | What it does |
| --- | --- |
| `get_state` | The open project: size, fps, playhead, selection, media, every layer with timing, position/scale/opacity, effects. |
| `get_command_spec` | The full list of edit commands (same ones MotionAI's own AI uses). |
| `run_commands` | Applies a batch of edit commands as one undo step (all or nothing). |
| `get_layer` | One layer in full (keyframes, effects, text style). |
| `undo` / `redo` | Like Ctrl+Z / Ctrl+Y. |
| `list_projects`, `open_project`, `new_project`, `save_project`, `rename_project`, `close_project` | Projects. |
| `import_media`, `list_media` | Bring in photos, videos and audio from files on your PC. |
| `render_frame` | A picture of any moment of the video, rendered like the export, so Claude can check its work. |
| `seek`, `play`, `pause`, `select`, `open_comp` | Playhead, playback, selection, nested compositions. |
| `export_video`, `export_status` | Export an MP4 (720p–4K) and follow its progress. |
| `director_run`, `job_status`, `cancel_job` | Run MotionAI's Director (automatic documentary edit). This uses **MotionAI's own AI connection** (ChatGPT plan or API key in the AI tab). |
| `captions_generate` | Automatic captions from speech (Whisper on your PC), in any caption style. |
| `list_templates`, `apply_template` | Insert ready-made scenes (intros, lower thirds, maps, 3D…). |
| `library_search`, `library_insert` | Use photos, cut-outs and music from your asset library. |
| `list_effects`, `list_components` | Everything available for effects and motion-graphics components. |

Resources: `motionai://spec` (command reference) and `motionai://project`
(the open project as JSON).

## Safety

- **Off by default.** Nothing listens until you switch it on, and switching
  it off stops it immediately.
- **This PC only.** The server listens on `127.0.0.1`, so other computers on
  your network cannot reach it.
- **Secret token.** Every request needs a random 256-bit token, kept in
  Windows' encrypted storage. Websites in your browser cannot use it:
  requests from web pages (a foreign `Origin`) or with a different host name
  are refused. Click the **refresh** icon next to the token to make a new
  one at any time.
- **For the Claude Desktop helper**, MotionAI writes the port and token to
  `%APPDATA%\MotionAI\mcp.json` (only readable by your Windows account),
  and removes the token from it when you switch control off.
- **Everything is visible and undoable.** Claude edits through the same
  editor you use; the activity list shows every action.
- Claude can read files you point it to (to import them) and write exported
  videos where you ask. It cannot delete your projects.

## Troubleshooting

- **Claude says MotionAI's control is turned off**: switch on *Allow Claude to
  control MotionAI* (step 1).
- **"Port 7820 is in use"**: change the port under Claude control. The
  Claude Desktop helper picks up the new port by itself; for URL clients
  update the URL.
- **Claude Desktop doesn't show motionai**: make sure you fully quit it
  from the tray, and that the path in the config points to
  `motionai-mcp.exe` in the MotionAI folder. Reinstalling MotionAI keeps the
  same path.
- **render_frame says the window is minimised**: restore the MotionAI
  window; Windows doesn't draw minimised apps.
- **Director fails with "not set up"**: the Director uses MotionAI's own AI
  (AI tab → settings). Claude can also build the edit itself with
  `run_commands`.
