## OllamaManager.gd
## Responsible for:
##   1. Copying ollama.exe out of res:// into a writable user:// folder on first run
##   2. Launching ollama.exe as a background process  (ollama serve)
##   3. Pulling a model via  ollama pull <model>  and streaming pull progress
##   4. Listing locally available models
##   5. Gracefully killing the process on app exit
##
## HOW TO BUNDLE ollama.exe
## ─────────────────────────
## In your Godot project root create:
##   bin/ollama.exe          ← the real Ollama Windows binary
##
## Then add this to project.godot  (or via Project → Export → Resources):
##   [editor]
##   export/convert_text_resources_to_binary=false
##
## And in Project Settings → Export → Resources add the filter:
##   bin/ollama.exe
##
## The manager will copy it to  user://ollama/ollama.exe  on first launch.

extends Node

# ── Signals ──────────────────────────────────────────────────────────────────
signal status_changed(message: String, color: Color)
signal ollama_ready()                          # serve is up and answering
signal pull_progress(model: String, status: String, percent: float)
signal pull_done(model: String)
signal pull_failed(model: String, error: String)
signal models_listed(names: Array)

# ── Constants ─────────────────────────────────────────────────────────────────
const BUNDLED_EXE   := "res://bin/ollama.exe"
const INSTALL_DIR   := "user://ollama"
const INSTALLED_EXE := "user://ollama/ollama.exe"
const SERVE_PORT    := 11434
const HEALTH_URL    := "http://127.0.0.1:11434/api/tags"
const READY_TIMEOUT := 30.0   # seconds to wait for serve to become responsive

# ── State ─────────────────────────────────────────────────────────────────────
var _serve_pid: int  = -1
var _exe_path: String = ""     # absolute OS path to ollama.exe
var _ready: bool = false
var _health_timer: float = 0.0
var _health_elapsed: float = 0.0
var _checking_health: bool = false

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready_node() -> void:
	pass   # called manually from Main.gd after tree is ready


func start() -> void:
	_emit_status("Preparing Ollama…", Color(1, 0.75, 0))
	_exe_path = ProjectSettings.globalize_path(INSTALLED_EXE)

	if not _ensure_installed():
		_emit_status("Failed to install Ollama", Color(0.9, 0.2, 0.2))
		return

	_launch_serve()


func _exit_tree() -> void:
	_kill_serve()


# ── Installation ──────────────────────────────────────────────────────────────

func _ensure_installed() -> bool:
	# Make sure the destination directory exists
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(INSTALL_DIR))

	var dest := ProjectSettings.globalize_path(INSTALLED_EXE)

	if FileAccess.file_exists(dest):
		return true   # already installed

	_emit_status("Extracting ollama.exe…", Color(1, 0.75, 0))

	# Check the bundled file actually exists in res://
	if not FileAccess.file_exists(BUNDLED_EXE):
		push_error("OllamaManager: bundled exe not found at " + BUNDLED_EXE)
		_emit_status("ollama.exe not bundled – see README", Color(0.9, 0.2, 0.2))
		return false

	# Read from res:// and write to user://
	var src := FileAccess.open(BUNDLED_EXE, FileAccess.READ)
	if src == null:
		push_error("OllamaManager: cannot open bundled exe")
		return false
	var data := src.get_buffer(src.get_length())
	src.close()

	var dst := FileAccess.open(dest, FileAccess.WRITE)
	if dst == null:
		push_error("OllamaManager: cannot write to " + dest)
		return false
	dst.store_buffer(data)
	dst.close()

	_emit_status("Extracted ollama.exe", Color(0.3, 0.9, 0.4))
	return true


# ── Launching serve ───────────────────────────────────────────────────────────

func _launch_serve() -> void:
	_emit_status("Starting Ollama server…", Color(1, 0.75, 0))

	# Kill any stale instance we launched previously
	_kill_serve()

	var args := ["serve"]
	_serve_pid = OS.create_process(_exe_path, args, false)

	if _serve_pid <= 0:
		_emit_status("Failed to launch ollama serve", Color(0.9, 0.2, 0.2))
		return

	# Poll health endpoint until responsive
	_checking_health = true
	_health_elapsed  = 0.0
	_health_timer    = 0.0


func _process(delta: float) -> void:
	if not _checking_health:
		return
	_health_timer   += delta
	_health_elapsed += delta

	if _health_elapsed > READY_TIMEOUT:
		_checking_health = false
		_emit_status("Ollama timed out starting", Color(0.9, 0.2, 0.2))
		return

	# Poll every 0.8 s
	if _health_timer < 0.8:
		return
	_health_timer = 0.0

	_ping_health()


func _ping_health() -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.timeout = 2.0
	req.request_completed.connect(
		func(result, code, _h, _b):
			req.queue_free()
			if result == HTTPRequest.RESULT_SUCCESS and code == 200:
				_checking_health = false
				_ready = true
				_emit_status("Ollama ready", Color(0.3, 0.9, 0.4))
				ollama_ready.emit()
	)
	req.request(HEALTH_URL)


# ── Model listing ─────────────────────────────────────────────────────────────

func list_models() -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(
		func(result, code, _h, body):
			req.queue_free()
			if result != HTTPRequest.RESULT_SUCCESS or code != 200:
				models_listed.emit([])
				return
			var json = JSON.parse_string(body.get_string_from_utf8())
			if json == null:
				models_listed.emit([])
				return
			var names: Array = []
			for m in json.get("models", []):
				names.append(m["name"])
			models_listed.emit(names)
	)
	req.request("http://127.0.0.1:11434/api/tags")


# ── Model pull ────────────────────────────────────────────────────────────────
## Pulls a model by running  ollama pull <model>  as a separate process and
## reading its stdout line-by-line in a thread.

var _pull_thread: Thread = null
var _pull_stop: bool = false

func pull_model(model_name: String) -> void:
	if _pull_thread != null and _pull_thread.is_started():
		return
	_pull_stop = false
	_pull_thread = Thread.new()
	_pull_thread.start(_pull_worker.bind(model_name))


func _pull_worker(model_name: String) -> void:
	# Use --no-progress-bar so we get parseable JSON lines on stdout
	var output := []
	var exit_code := OS.execute(_exe_path, ["pull", model_name], output, true, false)

	if exit_code != 0:
		call_deferred("_on_pull_failed", model_name,
			"exit code %d" % exit_code)
		return

	call_deferred("_on_pull_done", model_name)


func _on_pull_done(model_name: String) -> void:
	if _pull_thread and _pull_thread.is_started():
		_pull_thread.wait_to_finish()
	_pull_thread = null
	pull_done.emit(model_name)


func _on_pull_failed(model_name: String, error: String) -> void:
	if _pull_thread and _pull_thread.is_started():
		_pull_thread.wait_to_finish()
	_pull_thread = null
	pull_failed.emit(model_name, error)


# ── Shutdown ──────────────────────────────────────────────────────────────────

func _kill_serve() -> void:
	if _serve_pid > 0:
		OS.kill(_serve_pid)
		_serve_pid = -1
		_ready = false


func is_ready() -> bool:
	return _ready


# ── Helpers ───────────────────────────────────────────────────────────────────

func _emit_status(msg: String, color: Color) -> void:
	status_changed.emit(msg, color)
