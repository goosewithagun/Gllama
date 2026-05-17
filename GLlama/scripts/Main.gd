## ============================================================
## Main.gd
## ------------------------------------------------------------
## Top-level scene controller. Owns and wires together:
##
##   OllamaManager      — extracts + launches ollama.exe
##   OllamaClient       — HTTP streaming to Ollama API
##   ModelPickerPopup   — window to select / pull models
##   ShortContextWindow — chat summariser + prompt injection
##   LongContextWindow  — key/value memory + inline injection
##
## PROMPT ASSEMBLY ORDER (sent on every chat message):
##   1. System Context   (left panel TextEdit)
##   2. Short Context    (ShortContextWindow summary, appended to system block)
##   3. Last N tokens   (trimmed history — controlled by token_limit_spin;
##                        value is tokens; internally multiplied × 4 → chars)
##      └ Long Context keys in user messages expand inline: word {value}
##
## BUBBLE TRACKING:
##   _bubble_nodes mirrors _history index-for-index.
##   Each bubble has Edit (✎) and Delete (✕) buttons in its header.
##   Editing swaps the RichTextLabel for a TextEdit and updates history on save.
##   The Redo (↺) button removes the last assistant reply and re-generates it.
##
## BUSY MODES:
##   NONE       — idle, all UI active
##   CHAT       — streaming a reply; Send→Stop, other ops locked
##   SHORT_CTX  — ShortContextWindow processing; chat locked
##   LONG_CTX   — LongContextWindow processing; chat locked
## ============================================================

extends Control

# ── Busy mode enum ──────────────────────────────────────────────────────────────
enum BusyMode { NONE, CHAT, SHORT_CTX, LONG_CTX }

# ── Node references ─────────────────────────────────────────────────────────────
@onready var manager:       Node   = $OllamaManager
@onready var ollama:        Node   = $OllamaClient
@onready var picker:        Window = $ModelPickerPopup
@onready var short_ctx_win: Window = $ShortContextWindow
@onready var long_ctx_win:  Window = $LongContextWindow

@onready var active_model_lbl: Label  = $MC/HSplit/Left/ModelSection/ModelRow/ActiveModelLabel
@onready var pick_model_btn:   Button = $MC/HSplit/Left/ModelSection/ModelRow/PickModelButton

@onready var context_input: TextEdit = $MC/HSplit/Left/ContextSection/ContextInput
@onready var clear_ctx_btn: Button   = $MC/HSplit/Left/ContextSection/CtxHeader/ClearContextBtn

@onready var token_limit_spin: SpinBox = $MC/HSplit/Left/ContextSection/TokenRow/TokenLimitSpin

const DEFAULT_TEMPERATURE : float = 0.7

@onready var max_output_spin: SpinBox = $MC/HSplit/Left/MaxOutputSection/MaxOutputSpin
@onready var ctx_size_spin:   SpinBox = $MC/HSplit/Left/CtxSizeSection/CtxSizeSpin

@onready var short_ctx_btn: Button = $MC/HSplit/Left/ShortCtxButton
@onready var long_ctx_btn:  Button = $MC/HSplit/Left/LongCtxButton

@onready var status_dot: ColorRect = $MC/HSplit/Left/StatusRow/StatusDot
@onready var status_lbl: Label     = $MC/HSplit/Left/StatusRow/StatusLabel

@onready var new_chat_btn: Button = $MC/HSplit/Left/NewChatButton
@onready var save_btn:     Button = $MC/HSplit/Left/SaveLoadRow/SaveButton
@onready var load_btn:     Button = $MC/HSplit/Left/SaveLoadRow/LoadButton

@onready var ctx_meter: PanelContainer = $MC/HSplit/Left/ContextMeterPanel

@onready var chat_scroll:    ScrollContainer = $MC/HSplit/Right/ChatScroll
@onready var chat_container: VBoxContainer   = $MC/HSplit/Right/ChatScroll/ChatContainer
@onready var user_input:     TextEdit        = $MC/HSplit/Right/InputRow/UserInput
@onready var send_btn:       Button          = $MC/HSplit/Right/InputRow/SendButton

@onready var file_save: FileDialog = $FileDialogSave
@onready var file_load: FileDialog = $FileDialogLoad

# ── State variables ─────────────────────────────────────────────────────────────
var _history:      Array    = []
var _bubble_nodes: Array    = []   ## Parallel to _history — outer HBoxContainer per entry
var _current_model: String  = ""
var _busy: BusyMode         = BusyMode.NONE
var _bot_label              = null   ## RichTextLabel currently receiving stream

var _typing_indicator: Label = null
var _typing_timer:     float = 0.0
var _typing_dots:      int   = 0

var _memory_indicator: Label = null

var _tokens_since_last_update: int  = 0
var _auto_update_queue: Array = []

## Redo button — created programmatically in _ready()
var _redo_btn: Button = null


# ── _ready ──────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_apply_theme()

	manager.status_changed.connect(_on_manager_status)
	manager.ollama_ready.connect(_on_ollama_ready)

	picker.setup(manager)
	picker.model_selected.connect(_on_model_selected)

	short_ctx_win.setup(ollama)
	short_ctx_win.process_requested.connect(request_short_ctx_process)
	short_ctx_win.processing_started.connect(_on_short_ctx_started)
	short_ctx_win.processing_finished.connect(_on_short_ctx_finished)

	long_ctx_win.setup(ollama)
	long_ctx_win.process_requested.connect(request_long_ctx_process)
	long_ctx_win.processing_started.connect(_on_long_ctx_started)
	long_ctx_win.processing_finished.connect(_on_long_ctx_finished)

	ollama.stream_chunk.connect(_on_stream_chunk)
	ollama.stream_done.connect(_on_stream_done)
	ollama.stream_error.connect(_on_stream_error)

	pick_model_btn.pressed.connect(_on_pick_model_pressed)
	clear_ctx_btn.pressed.connect(func(): context_input.text = "")
	short_ctx_btn.pressed.connect(_on_short_ctx_btn_pressed)
	long_ctx_btn.pressed.connect(_on_long_ctx_btn_pressed)
	new_chat_btn.pressed.connect(_on_new_chat)
	save_btn.pressed.connect(func(): file_save.popup_centered())
	load_btn.pressed.connect(func(): file_load.popup_centered())

	## Refresh meter when any context-shaping parameter changes
	token_limit_spin.value_changed.connect(func(_v): _refresh_ctx_meter())
	max_output_spin.value_changed.connect(func(_v): _refresh_ctx_meter())
	ctx_size_spin.value_changed.connect(func(_v): _refresh_ctx_meter())

	## Godot 4 SpinBox doesn't always fire value_changed when the user types a
	## value and clicks away without pressing Enter.  Connect focus_exited on the
	## internal LineEdit so the meter refreshes and the value is committed no
	## matter how the field is left.
	var _tls_le := token_limit_spin.get_line_edit()
	_tls_le.focus_exited.connect(func():
		## Give Godot one frame to commit the typed value before reading it.
		await get_tree().process_frame
		_refresh_ctx_meter()
	)

	file_save.file_selected.connect(_on_save_file)
	file_load.file_selected.connect(_on_load_file)

	send_btn.pressed.connect(_on_send)
	user_input.gui_input.connect(_on_input_key)
	context_input.text_changed.connect(_refresh_ctx_meter)

	## ── Redo button (re-generate last assistant reply) ──────────────
	_redo_btn = Button.new()
	_redo_btn.name         = "RedoButton"
	_redo_btn.text         = "↺"
	_redo_btn.tooltip_text = "Re-generate last response"
	_redo_btn.custom_minimum_size = Vector2(38, 0)
	_redo_btn.disabled = true
	send_btn.get_parent().add_child(_redo_btn)
	_redo_btn.pressed.connect(_on_redo)

	_set_chat_enabled(false)
	pick_model_btn.disabled = true
	_set_status("Starting Ollama…", Color(1.0, 0.75, 0.0))

	manager.start()
	_add_system_msg("Starting bundled Ollama, please wait…")


# ── _process ── typing / memory indicator animation ─────────────────────────────
func _process(delta: float) -> void:
	if _typing_indicator == null and _memory_indicator == null:
		return
	_typing_timer += delta
	if _typing_timer >= 0.35:
		_typing_timer = 0.0
		_typing_dots  = (_typing_dots + 1) % 4
		if _typing_indicator != null:
			match _typing_dots:
				0: _typing_indicator.text = "●"
				1: _typing_indicator.text = "● ●"
				2: _typing_indicator.text = "● ● ●"
				3: _typing_indicator.text = "● ●"
		if _memory_indicator != null:
			match _typing_dots:
				0: _memory_indicator.text = "updating memory."
				1: _memory_indicator.text = "updating memory.."
				2: _memory_indicator.text = "updating memory..."
				3: _memory_indicator.text = "updating memory.."


# ── OllamaManager callbacks ─────────────────────────────────────────────────────

func _on_manager_status(msg: String, color: Color) -> void:
	_set_status(msg, color)

func _on_ollama_ready() -> void:
	_add_system_msg("Ollama is running.  Click  Choose…  to pick a model.")
	pick_model_btn.disabled = false


# ── Model selection ─────────────────────────────────────────────────────────────

func _on_pick_model_pressed() -> void:
	picker.show_popup()

func _on_model_selected(model_name: String) -> void:
	_current_model = model_name
	active_model_lbl.text = model_name
	ollama.set_host("http://127.0.0.1:11434")
	_set_chat_enabled(true)
	_set_status("Ready  ·  " + model_name, Color(0.3, 0.9, 0.4))
	_add_system_msg("Model set to  %s.  Start chatting!" % model_name)


# ── Parameter readers ────────────────────────────────────────────────────────────

func _get_temperature() -> float:
	return DEFAULT_TEMPERATURE

func _get_max_output() -> int:
	return int(max_output_spin.value)

func _get_ctx_size() -> int:
	return int(ctx_size_spin.value)


# ── Context window toggles ──────────────────────────────────────────────────────

func _on_short_ctx_btn_pressed() -> void:
	if not short_ctx_win.visible:
		short_ctx_win.popup_centered()
	else:
		short_ctx_win.hide()

func _on_long_ctx_btn_pressed() -> void:
	if not long_ctx_win.visible:
		long_ctx_win.popup_centered()
	else:
		long_ctx_win.hide()

func request_short_ctx_process() -> void:
	if _busy != BusyMode.NONE:
		return
	short_ctx_win.generate_summary(_history, _current_model, context_input.text)

func request_long_ctx_process() -> void:
	if _busy != BusyMode.NONE:
		return
	long_ctx_win.generate_memory(_history, _current_model, context_input.text)

func _on_short_ctx_started() -> void:
	_busy = BusyMode.SHORT_CTX
	_update_busy_ui()
	_show_memory_indicator()

func _on_short_ctx_finished() -> void:
	_busy = BusyMode.NONE
	_update_busy_ui()
	_process_auto_update_queue()
	_refresh_ctx_meter()

func _on_long_ctx_started() -> void:
	_busy = BusyMode.LONG_CTX
	_update_busy_ui()
	_show_memory_indicator()

func _on_long_ctx_finished() -> void:
	_busy = BusyMode.NONE
	_update_busy_ui()
	_process_auto_update_queue()


# ── New chat ────────────────────────────────────────────────────────────────────

func _on_new_chat() -> void:
	if _busy != BusyMode.NONE:
		return
	_history.clear()
	_bubble_nodes.clear()
	_tokens_since_last_update = 0
	_auto_update_queue.clear()
	for c in chat_container.get_children():
		c.queue_free()
	_add_system_msg("New chat started.")
	_update_redo_btn()
	_refresh_ctx_meter()


# ── Send / Stop ─────────────────────────────────────────────────────────────────

func _on_input_key(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ENTER and not event.shift_pressed:
			get_viewport().set_input_as_handled()
			_on_send()

func _on_send() -> void:
	if _busy == BusyMode.CHAT:
		ollama.abort_stream()
		return
	if _busy != BusyMode.NONE:
		return

	var text := user_input.text.strip_edges()
	if text == "":
		return
	if _current_model == "":
		_add_system_msg("⚠  Please choose a model first.")
		return

	user_input.text = ""
	user_input.grab_focus()

	var enriched: String = long_ctx_win.inject_into_message(text)
	_history.append({"role": "user", "content": enriched})
	_tokens_since_last_update += enriched.length()  ## count user input toward auto-update threshold

	var user_res = _add_bubble("user", text)
	_bubble_nodes.append(user_res[0])

	var bot_res = _add_bubble("assistant", "")
	_bubble_nodes.append(bot_res[0])
	_bot_label = bot_res[1]

	_typing_dots  = 0
	_typing_timer = 0.0
	_typing_indicator = _add_typing_indicator()

	_busy = BusyMode.CHAT
	_update_busy_ui()

	var messages := _build_prompt_messages()
	_send_request(messages)
	_refresh_ctx_meter()


## Assembles the full message array sent to Ollama.
func _build_prompt_messages() -> Array:
	var messages: Array = []

	var sys := context_input.text.strip_edges()

	var summary: String = short_ctx_win.get_summary()
	if summary != "":
		sys = (sys + "\n\n" + summary).strip_edges() if sys != "" else summary

	if sys != "":
		messages.append({"role": "system", "content": sys})

	var limit: int = int(token_limit_spin.value) * 4  # tokens → chars (4 chars ≈ 1 token)
	var trimmed    := _trim_history(limit)
	messages.append_array(trimmed)

	return messages


func _send_request(messages: Array) -> void:
	var options := {
		"temperature": _get_temperature(),
		"num_predict": _get_max_output(),
		"num_ctx":     _get_ctx_size()
	}
	ollama.send_chat_raw(messages, _current_model, options)


func _trim_history(limit: int) -> Array:
	if limit == 0 or _history.is_empty():
		return _history.duplicate()

	var result: Array = []
	var total_chars   := 0

	for i in range(_history.size() - 1, -1, -1):
		var msg     = _history[i]
		var msg_len = (msg["content"] as String).length()
		if total_chars + msg_len > limit and result.size() > 0:
			break
		result.insert(0, msg)
		total_chars += msg_len

	return result


# ── Redo (re-generate last assistant reply) ─────────────────────────────────────

func _on_redo() -> void:
	if _busy != BusyMode.NONE:
		return
	if _history.is_empty():
		return
	if _history.back()["role"] != "assistant":
		return

	## Remove last assistant entry from history and its bubble from UI
	_history.pop_back()
	var old_bubble = _bubble_nodes.pop_back()
	if is_instance_valid(old_bubble):
		old_bubble.queue_free()

	## Create a fresh assistant bubble and start streaming
	var bot_res = _add_bubble("assistant", "")
	_bubble_nodes.append(bot_res[0])
	_bot_label = bot_res[1]

	_typing_dots  = 0
	_typing_timer = 0.0
	_typing_indicator = _add_typing_indicator()

	_busy = BusyMode.CHAT
	_update_busy_ui()

	var messages := _build_prompt_messages()
	_send_request(messages)


func _update_redo_btn() -> void:
	if _redo_btn == null:
		return
	_redo_btn.disabled = _history.is_empty() or \
		_history.back()["role"] != "assistant" or \
		_busy != BusyMode.NONE


# ── Stream callbacks (chat only) ────────────────────────────────────────────────

func _on_stream_chunk(text: String) -> void:
	if _busy != BusyMode.CHAT:
		return
	if _typing_indicator != null:
		_typing_indicator.queue_free()
		_typing_indicator = null
	if _bot_label == null:
		return
	_bot_label.text += text
	## Keep raw text in metadata for editing
	_bot_label.set_meta("raw_text", _bot_label.text)
	_tokens_since_last_update += text.length()
	_scroll_bottom()

func _on_stream_done() -> void:
	if _busy != BusyMode.CHAT:
		return
	_remove_typing_indicator()
	if _bot_label != null:
		_history.append({"role": "assistant", "content": _bot_label.text})
		_bot_label = null
	_busy = BusyMode.NONE
	_update_busy_ui()
	_update_redo_btn()
	_check_auto_update()
	_refresh_ctx_meter()

func _on_stream_error(error: String) -> void:
	if _busy != BusyMode.CHAT:
		return
	_remove_typing_indicator()
	if _bot_label != null:
		_bot_label.text = "[Error: %s]" % error
		_bot_label = null
	_busy = BusyMode.NONE
	_update_busy_ui()
	_set_status("Error: " + error, Color(0.9, 0.3, 0.3))


# ── Auto-update logic ───────────────────────────────────────────────────────────

func _check_auto_update() -> void:
	_auto_update_queue.clear()

	## Trigger fires when combined user+bot text since last trigger exceeds N tokens
	## (the same N set in the trim-limit spinbox, converted to chars: N * 4).
	## When limit=0 fall back to a 2000-char default so auto-update still works.
	## Counter resets to 0 each time a trigger fires; history window just slides.
	var limit_tok: int   = int(token_limit_spin.value)
	var auto_thresh: int = limit_tok * 4 if limit_tok > 0 else 2000
	if _tokens_since_last_update < auto_thresh:
		_process_auto_update_queue()
		return

	_tokens_since_last_update = 0
	if short_ctx_win.is_auto_enabled():
		_auto_update_queue.append("short")
	if long_ctx_win.is_auto_enabled():
		_auto_update_queue.append("long")

	_process_auto_update_queue()


func _process_auto_update_queue() -> void:
	if _auto_update_queue.is_empty():
		_hide_memory_indicator()
		return
	if _busy != BusyMode.NONE:
		return
	var next: String = _auto_update_queue.pop_front()
	if next == "short":
		short_ctx_win.generate_summary(_history, _current_model, context_input.text)
	elif next == "long":
		long_ctx_win.generate_memory(_history, _current_model, context_input.text)


func _show_memory_indicator() -> void:
	if _memory_indicator != null:
		return
	_memory_indicator = Label.new()
	_memory_indicator.name = "MemoryIndicator"
	_memory_indicator.add_theme_font_size_override("font_size", 13)
	_memory_indicator.add_theme_color_override("font_color", Color(0.6, 0.75, 1.0, 0.85))
	_memory_indicator.text = "updating memory."
	_typing_dots  = 0
	_typing_timer = 0.0
	chat_container.add_child(_memory_indicator)
	_scroll_bottom()


func _hide_memory_indicator() -> void:
	if _memory_indicator != null:
		_memory_indicator.queue_free()
		_memory_indicator = null


# ── Busy UI update ──────────────────────────────────────────────────────────────

func _update_busy_ui() -> void:
	var is_idle := _busy == BusyMode.NONE
	var is_chat := _busy == BusyMode.CHAT

	send_btn.text     = "Stop" if is_chat else "Send"
	send_btn.disabled = (not is_idle and not is_chat)

	user_input.editable     = is_idle
	new_chat_btn.disabled   = not is_idle
	pick_model_btn.disabled = not is_idle
	save_btn.disabled       = not is_idle
	load_btn.disabled       = not is_idle

	short_ctx_win.set_extern_busy(not is_idle and _busy != BusyMode.SHORT_CTX)
	long_ctx_win.set_extern_busy(not is_idle and _busy != BusyMode.LONG_CTX)

	## Redo only available when idle and there's an assistant reply to redo
	_update_redo_btn()


# ── Save / Load ─────────────────────────────────────────────────────────────────

func _on_save_file(path: String) -> void:
	var data := {
		"model":              _current_model,
		"system_context":     context_input.text,
		"token_limit":        int(token_limit_spin.value),
		"temperature":        _get_temperature(),
		"max_output":         _get_max_output(),
		"ctx_size":           _get_ctx_size(),
		"short_ctx_summary":  short_ctx_win.get_summary(),
		"short_ctx_auto":     short_ctx_win.is_auto_enabled(),
		"long_ctx_memory":    long_ctx_win.get_memory(),
		"long_ctx_auto":      long_ctx_win.is_auto_enabled(),
		"history":            _history
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "\t"))
		f.close()
		_add_system_msg("Chat saved → " + path.get_file())

func _on_load_file(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var raw  := f.get_as_text()
	f.close()
	var data = JSON.parse_string(raw)
	if data == null:
		_add_system_msg("⚠  Could not parse save file.")
		return

	_history = data.get("history", [])
	_bubble_nodes.clear()
	context_input.text      = data.get("system_context", "")
	token_limit_spin.value  = float(data.get("token_limit", 2000))
	max_output_spin.value   = float(data.get("max_output",  512))
	ctx_size_spin.value     = float(data.get("ctx_size",   4096))
	short_ctx_win.set_summary(data.get("short_ctx_summary", ""))
	short_ctx_win.set_auto(data.get("short_ctx_auto", false))
	long_ctx_win.set_memory(data.get("long_ctx_memory", {}))
	long_ctx_win.set_auto(data.get("long_ctx_auto", false))

	for c in chat_container.get_children():
		c.queue_free()
	_add_system_msg("Chat loaded  (" + data.get("model", "unknown model") + ")")
	for msg in _history:
		var res = _add_bubble(msg["role"], msg["content"])
		_bubble_nodes.append(res[0])
	_update_redo_btn()
	_refresh_ctx_meter()


# ── Typing indicator ─────────────────────────────────────────────────────────────

func _add_typing_indicator() -> Label:
	var lbl := Label.new()
	lbl.name = "TypingIndicator"
	lbl.add_theme_font_size_override("font_size", 20)
	lbl.add_theme_color_override("font_color", Color(0.5, 0.9, 0.55, 0.9))
	lbl.text = "●"
	chat_container.add_child(lbl)
	_scroll_bottom()
	return lbl

func _remove_typing_indicator() -> void:
	if _typing_indicator != null:
		_typing_indicator.queue_free()
		_typing_indicator = null


# ── Chat bubbles ─────────────────────────────────────────────────────────────────
## Creates a styled chat bubble.
## Returns [outer: HBoxContainer, lbl: RichTextLabel].
## The outer node is stored in _bubble_nodes (parallel to _history).

func _add_bubble(role: String, text: String) -> Array:
	var is_user := (role == "user")

	var outer := HBoxContainer.new()
	outer.size_flags_horizontal = Control.SIZE_FILL

	if is_user:
		var sp := Control.new()
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		outer.add_child(sp)

	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var sb := StyleBoxFlat.new()
	sb.corner_radius_top_left     = 12
	sb.corner_radius_top_right    = 12
	sb.corner_radius_bottom_left  = 12
	sb.corner_radius_bottom_right = 12
	sb.content_margin_left        = 14
	sb.content_margin_right       = 14
	sb.content_margin_top         = 10
	sb.content_margin_bottom      = 10
	sb.bg_color = Color(0.22, 0.38, 0.60) if is_user else Color(0.18, 0.18, 0.23)
	panel.add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	## ── Header row: role label + action buttons ──────────────────────────────
	var role_row := HBoxContainer.new()
	vbox.add_child(role_row)

	var role_lbl := Label.new()
	role_lbl.text                  = "User:" if is_user else "Bot:"
	role_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	role_lbl.add_theme_font_size_override("font_size", 11)
	role_lbl.add_theme_color_override("font_color",
		Color(0.7, 0.85, 1.0, 0.9) if is_user else Color(0.5, 0.9, 0.55, 0.9))
	role_row.add_child(role_lbl)

	## Copy button
	var copy_btn := Button.new()
	copy_btn.text                = "⎘"
	copy_btn.flat                = true
	copy_btn.tooltip_text        = "Copy to clipboard"
	copy_btn.custom_minimum_size = Vector2(24, 20)
	copy_btn.add_theme_font_size_override("font_size", 13)
	role_row.add_child(copy_btn)

	## Edit button
	var edit_btn := Button.new()
	edit_btn.text                = "*"
	edit_btn.flat                = true
	edit_btn.tooltip_text        = "Edit message"
	edit_btn.custom_minimum_size = Vector2(24, 20)
	edit_btn.add_theme_font_size_override("font_size", 13)
	role_row.add_child(edit_btn)

	## Delete button
	var del_btn := Button.new()
	del_btn.text                = "✕"
	del_btn.flat                = true
	del_btn.tooltip_text        = "Remove message"
	del_btn.custom_minimum_size = Vector2(24, 20)
	del_btn.add_theme_font_size_override("font_size", 13)
	role_row.add_child(del_btn)

	## ── Content label ────────────────────────────────────────────────────────
	var lbl := RichTextLabel.new()
	lbl.bbcode_enabled        = true
	lbl.fit_content           = true
	lbl.size_flags_horizontal = Control.SIZE_FILL
	lbl.autowrap_mode         = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_font_size_override("normal_font_size", 14)
	lbl.add_theme_color_override("default_color", Color(0.92, 0.92, 0.95))
	lbl.text = _md_to_bbcode(text)
	lbl.set_meta("raw_text", text)   ## Store original for editing
	vbox.add_child(lbl)

	## ── Button logic ─────────────────────────────────────────────────────────

	copy_btn.pressed.connect(func():
		DisplayServer.clipboard_set(lbl.get_meta("raw_text", lbl.text))
		copy_btn.text = "✓"
		await get_tree().create_timer(1.2).timeout
		if is_instance_valid(copy_btn):
			copy_btn.text = "⎘"
	)

	## Edit: swap RichTextLabel ↔ TextEdit in-place
	edit_btn.pressed.connect(func():
		if _busy != BusyMode.NONE:
			return
		if vbox.has_node("EditArea"):
			return  ## Already editing

		lbl.visible = false
		edit_btn.disabled = true

		var edit_area := TextEdit.new()
		edit_area.name             = "EditArea"
		edit_area.text             = lbl.get_meta("raw_text", lbl.text)
		edit_area.autowrap_mode    = TextServer.AUTOWRAP_WORD_SMART
		edit_area.custom_minimum_size = Vector2(0, 80)
		edit_area.size_flags_horizontal = Control.SIZE_FILL
		vbox.add_child(edit_area)

		var btn_row := HBoxContainer.new()
		btn_row.name = "EditButtons"
		vbox.add_child(btn_row)

		var save_edit_btn := Button.new()
		save_edit_btn.text = "Save"
		btn_row.add_child(save_edit_btn)

		var cancel_edit_btn := Button.new()
		cancel_edit_btn.text = "Cancel"
		btn_row.add_child(cancel_edit_btn)

		save_edit_btn.pressed.connect(func():
			var new_text := edit_area.text
			lbl.set_meta("raw_text", new_text)
			lbl.text = _md_to_bbcode(new_text)
			## Update the corresponding history entry
			var idx := _find_bubble_index(outer)
			if idx >= 0 and idx < _history.size():
				_history[idx]["content"] = new_text
			edit_area.queue_free()
			btn_row.queue_free()
			lbl.visible = true
			edit_btn.disabled = false
		)

		cancel_edit_btn.pressed.connect(func():
			edit_area.queue_free()
			btn_row.queue_free()
			lbl.visible = true
			edit_btn.disabled = false
		)
	)

	## Delete: remove from UI and history
	del_btn.pressed.connect(func():
		if _busy != BusyMode.NONE:
			return
		var idx := _find_bubble_index(outer)
		if idx >= 0:
			_history.remove_at(idx)
			_bubble_nodes.remove_at(idx)
		outer.queue_free()
		_update_redo_btn()
	)

	outer.add_child(panel)

	if not is_user:
		var sp2 := Control.new()
		sp2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		outer.add_child(sp2)

	chat_container.add_child(outer)
	_scroll_bottom()
	return [outer, lbl]


## Finds the index of a bubble's outer node in _bubble_nodes.
## Returns -1 if not found.
func _find_bubble_index(outer: Node) -> int:
	for i in range(_bubble_nodes.size()):
		if _bubble_nodes[i] == outer:
			return i
	return -1


## Minimal Markdown → BBCode converter.
func _md_to_bbcode(text: String) -> String:
	if text == "":
		return text

	var lines   := text.split("\n")
	var out     := PackedStringArray()
	var in_code := false

	for line in lines:
		if line.strip_edges().begins_with("```"):
			in_code = not in_code
			out.append("[code]" if in_code else "[/code]")
			continue

		if in_code:
			out.append(line)
			continue

		if   line.begins_with("### "): line = "[b]" + line.substr(4) + "[/b]"
		elif line.begins_with("## "):  line = "[b]" + line.substr(3) + "[/b]"
		elif line.begins_with("# "):   line = "[b]" + line.substr(2) + "[/b]"

		var re_bold := RegEx.new()
		re_bold.compile("\\*\\*(.+?)\\*\\*")
		line = re_bold.sub(line, "[b]$1[/b]", true)

		var re_ital := RegEx.new()
		re_ital.compile("(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)")
		line = re_ital.sub(line, "[i]$1[/i]", true)

		var re_code := RegEx.new()
		re_code.compile("`(.+?)`")
		line = re_code.sub(line, "[code]$1[/code]", true)

		if line.strip_edges().begins_with("- ") or line.strip_edges().begins_with("* "):
			line = "  • " + line.strip_edges().substr(2)

		out.append(line)

	return "\n".join(out)


## Centred informational message — not stored in history or _bubble_nodes.
func _add_system_msg(text: String) -> void:
	var lbl := Label.new()
	lbl.text                 = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode        = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	chat_container.add_child(lbl)
	_scroll_bottom()


func _scroll_bottom() -> void:
	await get_tree().process_frame
	chat_scroll.scroll_vertical = chat_scroll.get_v_scroll_bar().max_value


# ── UI helpers ──────────────────────────────────────────────────────────────────

func _set_status(msg: String, color: Color) -> void:
	status_lbl.text  = msg
	status_dot.color = color

func _set_chat_enabled(on: bool) -> void:
	user_input.editable = on
	send_btn.disabled   = not on


# ── Context meter ────────────────────────────────────────────────────────────────

## Gathers all context-usage data and pushes it to the meter panel.
## Called after any action that changes static context, history, or settings.
func _refresh_ctx_meter() -> void:
	if ctx_meter == null or not ctx_meter.has_method("refresh"):
		return

	## Static context = system context TextEdit + short context summary
	var static_text: String = context_input.text.strip_edges()
	var short_text:  String = short_ctx_win.get_summary()
	## Combine as they both go into the system block
	var static_chars: int = static_text.length() + (short_text.length() + 2 if short_text != "" else 0)
	var short_chars:  int = short_text.length()

	## Chat history chars after trimming
	var limit_chars: int = int(token_limit_spin.value) * 4  # tokens → chars (4 chars ≈ 1 token)
	var trimmed := _trim_history(limit_chars)
	var hist_chars := 0
	for msg in trimmed:
		hist_chars += (msg["content"] as String).length()

	ctx_meter.refresh(
		static_chars,
		short_chars,
		hist_chars,
		_get_max_output(),
		_get_ctx_size()
	)


# ── Theme ────────────────────────────────────────────────────────────────────────

func _apply_theme() -> void:
	var t := Theme.new()
	t.default_font_size = 14

	var _mk := func(bg: Color, radius: int = 6, border: Color = Color.TRANSPARENT) -> StyleBoxFlat:
		var s := StyleBoxFlat.new()
		s.bg_color    = bg
		s.border_color = border
		for side in [SIDE_LEFT, SIDE_RIGHT, SIDE_TOP, SIDE_BOTTOM]:
			s.set_border_width(side, 1 if border != Color.TRANSPARENT else 0)
		s.corner_radius_top_left     = radius
		s.corner_radius_top_right    = radius
		s.corner_radius_bottom_left  = radius
		s.corner_radius_bottom_right = radius
		s.content_margin_left        = 10
		s.content_margin_right       = 10
		s.content_margin_top         = 6
		s.content_margin_bottom      = 6
		return s

	var btn_n: StyleBoxFlat = _mk.call(Color(0.22, 0.22, 0.28))
	var btn_h: StyleBoxFlat = _mk.call(Color(0.28, 0.28, 0.36))
	var btn_p: StyleBoxFlat = _mk.call(Color(0.18, 0.42, 0.78))
	for cls in ["Button", "OptionButton"]:
		t.set_stylebox("normal",  cls, btn_n)
		t.set_stylebox("hover",   cls, btn_h)
		t.set_stylebox("pressed", cls, btn_p)
		t.set_color("font_color", cls, Color(0.9, 0.9, 0.95))

	var field: StyleBoxFlat = _mk.call(Color(0.15, 0.15, 0.19), 6, Color(0.32, 0.32, 0.42))
	for cls in ["LineEdit", "TextEdit"]:
		t.set_stylebox("normal", cls, field)
		t.set_color("font_color", cls, Color(0.9, 0.9, 0.95))

	t.set_color("font_color", "Label", Color(0.88, 0.88, 0.92))

	var il: StyleBoxFlat = _mk.call(Color(0.15, 0.15, 0.19), 6, Color(0.32, 0.32, 0.42))
	t.set_stylebox("panel", "ItemList", il)
	t.set_color("font_color", "ItemList", Color(0.88, 0.88, 0.92))

	theme               = t
	picker.theme        = t
	short_ctx_win.theme = t
	long_ctx_win.theme  = t
	if ctx_meter != null:
		ctx_meter.theme = t
