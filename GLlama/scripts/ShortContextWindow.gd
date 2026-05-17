## ============================================================
## ShortContextWindow.gd
## ------------------------------------------------------------
## Floating window that holds an editable summary of the chat.
##
## HOW IT WORKS:
##   1. User opens via "Short Context" button on the left panel.
##   2. User clicks "Process" -> this window emits process_requested.
##      Main.gd receives it, checks busy state, then calls
##      generate_summary() if the system is idle.
##   3. The response streams into SummaryInput TextEdit live.
##   4. The user can freely edit the result afterward.
##   5. Main.gd calls get_summary() when building each prompt.
##
## BUSY LOCKING:
##   - set_extern_busy(true)  disables Process while chat is busy.
##   - While processing, emits processing_started -> Main locks all UI.
##   - Pressing Process again while processing aborts the stream.
##
## NODE PATHS (relative to ShortContextWindow root):
##   MarginContainer/VBox/SummaryInput            -> TextEdit
##   MarginContainer/VBox/ButtonRow/ProcessButton  -> Button
##   MarginContainer/VBox/ButtonRow/ClearButton    -> Button
##   MarginContainer/VBox/ButtonRow/AutoButton     -> CheckButton
##   MarginContainer/VBox/StatusLabel              -> Label
## ============================================================

extends Window

# -- Signals -------------------------------------------------------------------
## Emitted when user presses "Process" and we are NOT already processing.
## Main.gd connects this to request_short_ctx_process(), which checks
## _busy == NONE before calling generate_summary(). Keeps busy-mode in Main.
signal process_requested()

## Emitted when streaming starts -- Main.gd sets _busy = SHORT_CTX.
signal processing_started()

## Emitted when streaming ends (done / error / aborted) -- Main clears _busy.
signal processing_finished()

# -- Node references -----------------------------------------------------------
@onready var summary_input: TextEdit    = $MarginContainer/VBox/SummaryInput
@onready var process_btn:   Button      = $MarginContainer/VBox/ButtonRow/ProcessButton
@onready var clear_btn:     Button      = $MarginContainer/VBox/ButtonRow/ClearButton
@onready var auto_btn:      CheckButton = $MarginContainer/VBox/ButtonRow/AutoButton
@onready var status_lbl:    Label       = $MarginContainer/VBox/StatusLabel

# -- Internal state ------------------------------------------------------------
var _ollama: Node          = null   ## OllamaClient -- set by setup()
var _is_processing: bool   = false  ## True while a stream is running
var _streamed_text: String = ""     ## Accumulates response tokens during stream

## temperature:0 keeps the summary factual and grounded.
## num_predict:300 is enough for a dense paragraph; prevents rambling.
const SUMMARY_OPTIONS := {"temperature": 0.0, "num_predict": 300}


# -- Setup ---------------------------------------------------------------------
## Called once by Main.gd._ready() BEFORE any chat signals are connected.
## Subscribes to OllamaClient stream signals (shared by chat + long ctx).
## Every handler below guards with _is_processing to avoid acting on other streams.
func setup(ollama_client: Node) -> void:
	_ollama = ollama_client
	_ollama.stream_chunk.connect(_on_chunk)
	_ollama.stream_done.connect(_on_done)
	_ollama.stream_error.connect(_on_error)


# -- _ready --------------------------------------------------------------------
func _ready() -> void:
	close_requested.connect(func(): hide())
	process_btn.pressed.connect(_on_process_pressed)
	clear_btn.pressed.connect(func(): summary_input.text = "")
	title       = "Short Context"
	min_size    = Vector2(460, 320)
	exclusive   = false
	unresizable = false


# -- Public API ----------------------------------------------------------------

## Returns current summary text. Called by Main._build_prompt_messages()
## to inject after System Context and before trimmed chat history.
func get_summary() -> String:
	return summary_input.text.strip_edges()

## Restores summary text (used by Main._on_load_file).
func set_summary(text: String) -> void:
	summary_input.text = text

## Returns true if auto-update is enabled (Auto toggle is on).
func is_auto_enabled() -> bool:
	return auto_btn.button_pressed

## Restores the auto-update toggle state (used by Main._on_load_file).
func set_auto(enabled: bool) -> void:
	auto_btn.button_pressed = enabled

## Disables/enables Process button when an external operation holds the model.
## Skipped if we're already processing (keeps button as "Abort").
func set_extern_busy(busy: bool) -> void:
	if _is_processing:
		return
	process_btn.disabled = busy


## Starts the summarization stream.
## Called ONLY by Main.gd after busy-mode check passes.
##   history    -- full conversation [{role, content}, ...]
##   model      -- active Ollama model string
##   system_ctx -- raw text from the System Context TextEdit (left panel)
func generate_summary(history: Array, model: String, system_ctx: String) -> void:
	if _is_processing:
		return
	if history.is_empty():
		status_lbl.text = "No conversation to summarize yet."
		return

	_is_processing     = true
	_streamed_text     = ""
	process_btn.text   = "Abort"
	summary_input.text = ""
	status_lbl.text    = "Summarizing..."
	processing_started.emit()

	## Full history for the summary (short ctx summarizes everything)
	var transcript := ""
	for msg in history:
		transcript += "%s: %s\n" % [msg["role"].capitalize(), msg["content"]]

	## Build the system prompt. Prepend the user's system context if set
	## so the summary reflects the assistant's role or domain.
	var sys_note := ""
	if system_ctx.strip_edges() != "":
		sys_note = system_ctx.strip_edges() + "\n\n"

	var messages := [
		{
			"role": "system",
			"content": (
				sys_note
				+ "You are a summarization assistant.\n"
				+ "Write one concise paragraph that captures:\n"
				+ "  - The main topic or task discussed\n"
				+ "  - Any decisions made or conclusions reached\n"
				+ "  - The current state or next step\n"
				+ "Write in third person. Plain prose only — no bullet points, "
				+ "no headers, no preamble. Start directly with the content."
			)
		},
		{
			"role": "user",
			"content": "Summarize this conversation:\n\n" + transcript
		}
	]

	_ollama.send_chat_raw(messages, model, SUMMARY_OPTIONS)


# -- Stream callbacks ----------------------------------------------------------

func _on_chunk(text: String) -> void:
	if not _is_processing:
		return   ## Chunk belongs to chat or long-ctx; ignore
	_streamed_text    += text
	summary_input.text = _streamed_text

func _on_done() -> void:
	if not _is_processing:
		return
	_is_processing   = false
	process_btn.text = "Process"
	status_lbl.text  = "Done. Edit freely before sending messages."
	processing_finished.emit()

func _on_error(error: String) -> void:
	if not _is_processing:
		return
	_is_processing   = false
	process_btn.text = "Process"
	status_lbl.text  = "Error: " + error
	processing_finished.emit()


# -- Button handler ------------------------------------------------------------
## _is_processing == true  -> ABORT: kills the stream, resets state.
## _is_processing == false -> START: emits process_requested so Main
##   enforces the busy gate before calling generate_summary().
func _on_process_pressed() -> void:
	if _is_processing:
		_ollama.abort_stream()
		_is_processing   = false
		process_btn.text = "Process"
		status_lbl.text  = "Aborted."
		processing_finished.emit()
	else:
		process_requested.emit()
