# Ollama Chat — Godot 4  (self-contained Windows app)

A Godot 4 chatbot frontend that **bundles and manages Ollama internally**.
No separate Ollama installation required on the end-user's machine.

---

## How it works

```
App launches
  └─ OllamaManager extracts  bin/ollama.exe  →  %APPDATA%/Godot/app_userdata/.../ollama/ollama.exe
       └─ Spawns  ollama serve  as a background process  (port 11434)
            └─ Polls  /api/tags  until responsive
                 └─ Emits  ollama_ready  signal
                      └─ User clicks "Choose…" → ModelPickerPopup
                           └─ Select installed model  OR  pull a new one
                                └─ Chat with streaming
App closes  →  OS.kill(serve_pid)
```

---

## Setup (developers)

### 1. Get `ollama.exe`

Download the **Windows portable binary** (not the installer) from:
https://github.com/ollama/ollama/releases

Look for `ollama-windows-amd64.exe`, rename it to `ollama.exe`.

### 2. Place it in the project

```
godot_ollama_chat/
└── bin/
    └── ollama.exe          ← put it here
```

### 3. Tell Godot to include it in the export

Open **Project → Export → Windows Desktop → Resources tab** and add:

```
bin/ollama.exe
```

Or add this to `project.godot` under `[export_presets]` manually.

> **In the editor**, Godot's `res://` can access the file directly.  
> After export, it is packed into the PCK and extracted to `user://` on first run.

### 4. Open the project in Godot 4.3+

```
File → Import → navigate to project.godot → Open
```

Press **F5** to run.

---

## Exporting to Windows `.exe`

1. **Project → Export → Add → Windows Desktop**
2. Under **Resources**, add filter:  `bin/ollama.exe`
3. Set output path, e.g. `build/OllamaChat.exe`
4. Click **Export Project** (embed PCK for single-file distribution)

The resulting `.exe` is fully self-contained — ollama.exe is embedded in the PCK and
extracted to `%APPDATA%\Godot\app_userdata\Ollama Chat\ollama\` on first launch.

---

## File structure

```
godot_ollama_chat/
├── project.godot
├── icon.svg
├── bin/
│   └── ollama.exe              ← YOU must add this (see Setup)
├── scenes/
│   └── Main.tscn               ← full UI + popup layout
└── scripts/
    ├── Main.gd                 ← UI controller
    ├── OllamaManager.gd        ← process lifecycle (extract, serve, pull)
    ├── OllamaClient.gd         ← HTTP streaming client
    └── ModelPickerPopup.gd     ← model picker/puller popup
```

---

## Features

| Feature | Details |
|---|---|
| Bundled Ollama | `ollama.exe` shipped inside the app, extracted on first run |
| Auto-start server | `ollama serve` launched at startup, killed on exit |
| Model picker popup | Click **Choose…** → see installed models, select or pull new ones |
| Pull new models | Type a model name (e.g. `llama3`) and click Pull inside the popup |
| Streaming | Word-by-word streaming via `HTTPClient` in a `Thread` |
| System context | Editable system prompt injected before every conversation |
| Conversation memory | Full multi-turn history per session |
| New Chat | Clears history and chat display |
| Stop button | Abort mid-stream generation |
| Configurable host | Defaults to `127.0.0.1:11434`; change in `OllamaClient.gd` |

---

## Customisation tips

- **Temperature / top_p**: in `OllamaClient.gd` `send_chat()`, add to the payload:
  ```gdscript
  "options": {"temperature": 0.8, "top_p": 0.9}
  ```
- **Default system prompt**: set `context_input.text = "..."` at the bottom of `Main.gd _ready()`.
- **Markdown rendering**: set `lbl.bbcode_enabled = true` in `_add_bubble()` and convert
  Markdown → BBCode in `_on_stream_chunk`.
- **Multiple Ollama instances / remote**: change `SERVE_PORT` and `HEALTH_URL` in `OllamaManager.gd`.

---

## Notes

- First run extracts `ollama.exe` to the Godot user data folder — this is instant.
- Model pulls can take minutes depending on model size and internet speed.
- `ollama serve` is killed automatically when the Godot window closes via `_exit_tree()`.
- If the port 11434 is already in use (another Ollama instance), the health check will
  still pass and the app will work — it just won't own that process.
