## ============================================================
## LongContextWindow.gd
## ULTRA ROBUST MEMORY EXTRACTION VERSION
## ------------------------------------------------------------
## Features:
##   - Extracts MANY atomic facts
##   - Handles malformed JSON
##   - Handles streamed responses
##   - Handles multiple JSON objects
##   - Handles key:value fallback
##   - Handles markdown + think tags
##   - Sanitizes keys/values
##   - Prevents parser crashes
##   - Prevents giant hallucinated summaries
## ============================================================

extends Window

# -- Signals -------------------------------------------------------------------
signal process_requested()
signal processing_started()
signal processing_finished()

# -- Node references -----------------------------------------------------------
@onready var process_btn:     Button        = $MarginContainer/VBox/TopRow/ProcessButton
@onready var add_row_btn:     Button        = $MarginContainer/VBox/TopRow/AddRowButton
@onready var clear_btn:       Button        = $MarginContainer/VBox/TopRow/ClearButton
@onready var auto_btn:        CheckButton   = $MarginContainer/VBox/TopRow/AutoButton
@onready var status_lbl:      Label         = $MarginContainer/VBox/StatusLabel
@onready var cells_container: VBoxContainer = $MarginContainer/VBox/ScrollContainer/CellsContainer

# -- Internal state ------------------------------------------------------------
var _ollama: Node         = null
var _is_processing: bool  = false
var _raw_response: String = ""

# -- Extraction options --------------------------------------------------------
const EXTRACT_OPTIONS := {
	"temperature": 0.0,
	"top_p": 0.8,
	"num_predict": 400
}

# -- Setup ---------------------------------------------------------------------
func setup(ollama_client: Node) -> void:
	_ollama = ollama_client

	_ollama.stream_chunk.connect(_on_chunk)
	_ollama.stream_done.connect(_on_done)
	_ollama.stream_error.connect(_on_error)

# -- Ready ---------------------------------------------------------------------
func _ready() -> void:
	close_requested.connect(func(): hide())

	process_btn.pressed.connect(_on_process_pressed)
	add_row_btn.pressed.connect(func(): _add_cell("", ""))
	clear_btn.pressed.connect(_clear_cells)

	title       = "Long Context"
	min_size    = Vector2(540, 420)
	exclusive   = false
	unresizable = false

	for _i in range(5):
		_add_cell("", "")

# -- Public API ----------------------------------------------------------------
func set_extern_busy(busy: bool) -> void:
	if _is_processing:
		return

	process_btn.disabled = busy

func is_auto_enabled() -> bool:
	return auto_btn.button_pressed

func set_auto(enabled: bool) -> void:
	auto_btn.button_pressed = enabled

func get_memory() -> Dictionary:
	var result := {}

	for row in cells_container.get_children():
		var kn = row.get_node_or_null("Key")
		var vn = row.get_node_or_null("Value")

		if kn == null or vn == null:
			continue

		var k := String(kn.text.strip_edges().to_lower())
		var v := String(vn.text.strip_edges())

		if k != "" and v != "":
			result[k] = v

	return result

func set_memory(data: Dictionary) -> void:
	_clear_cells()

	for key in data.keys():
		_add_cell(str(key), str(data[key]))

func inject_into_message(text: String) -> String:
	var memory := get_memory()

	if memory.is_empty():
		return text

	var words := text.split(" ")

	var out := PackedStringArray()

	for word in words:
		out.append(word)

		var clean := word.to_lower() \
			.trim_suffix(".") \
			.trim_suffix(",") \
			.trim_suffix("?") \
			.trim_suffix("!") \
			.trim_suffix(":") \
			.trim_suffix(";") \
			.trim_prefix("(") \
			.trim_suffix(")")

		if memory.has(clean):
			out.append("{" + memory[clean] + "}")

	return " ".join(out)

# -- Main extraction -----------------------------------------------------------
func generate_memory(history: Array, model: String, _system_ctx: String) -> void:
	if _is_processing:
		return

	if history.is_empty():
		status_lbl.text = "No conversation to process yet."
		return

	_is_processing = true
	_raw_response = ""

	process_btn.text = "Abort"

	status_lbl.text = "Extracting facts..."

	processing_started.emit()

	var recent := history.slice(max(0, history.size() - 20), history.size())

	var transcript := ""

	for msg in recent:
		transcript += "%s: %s\n" % [
			msg["role"].capitalize(),
			msg["content"]
		]

	var messages := [
		{
			"role": "system",
			"content":
				"You extract atomic facts from text.\n"
				+ "\n"
				+ "Return ONLY:\n"
				+ "- valid JSON\n"
				+ "- OR key:value lines\n"
				+ "\n"
				+ "Extract MANY atomic facts.\n"
				+ "\n"
				+ "Rules:\n"
				+ "- lowercase snake_case keys\n"
				+ "- short values\n"
				+ "- never summarize\n"
				+ "- never explain\n"
				+ "- never add commentary\n"
				+ "- never write prose\n"
				+ "- preserve exact wording\n"
				+ "- no markdown\n"
				+ "- no code fences\n"
				+ "- no extra text\n"
				+ "\n"
				+ "GOOD:\n"
				+ "{\"name\":\"Alice\",\"age\":\"33\"}\n"
				+ "\n"
				+ "ALSO GOOD:\n"
				+ "name: Alice\n"
				+ "age: 33\n"
				+ "\n"
				+ "BAD:\n"
				+ "Here are the facts:\n"
				+ "{\"summary\":\"Alice is 33\"}"
		},
		{
			"role": "user",
			"content": transcript
		}
	]

	_ollama.send_chat_raw(messages, model, EXTRACT_OPTIONS)

# -- Stream callbacks ----------------------------------------------------------
func _on_chunk(text: String) -> void:
	if not _is_processing:
		return

	_raw_response += text

	status_lbl.text = "Receiving... (%d chars)" % _raw_response.length()

func _on_done() -> void:
	if not _is_processing:
		return

	_is_processing = false

	process_btn.text = "Process"

	print("========= RAW MODEL RESPONSE =========")
	print(_raw_response)

	_parse_and_populate()

	processing_finished.emit()

func _on_error(error: String) -> void:
	if not _is_processing:
		return

	_is_processing = false

	process_btn.text = "Process"

	status_lbl.text = "Error: " + error

	processing_finished.emit()

# -- Buttons -------------------------------------------------------------------
func _on_process_pressed() -> void:
	if _is_processing:
		_ollama.abort_stream()

		_is_processing = false

		process_btn.text = "Process"

		status_lbl.text = "Aborted."

		processing_finished.emit()

	else:
		process_requested.emit()

# -- Parsing -------------------------------------------------------------------
func _parse_and_populate() -> void:
	var raw := _raw_response.strip_edges()

	print("========= RAW RESPONSE =========")
	print(raw)

	# ---------------------------------------------------------
	# CLEANUP
	# ---------------------------------------------------------

	raw = _strip_think_tags(raw)
	raw = _strip_markdown(raw)
	raw = raw.replace("\r", "")

	# ---------------------------------------------------------
	# EXTRACT FACTS
	# ---------------------------------------------------------

	var facts := {}

	# 1. Extract ALL json objects
	var json_objects := _extract_all_json_objects(raw)

	for obj_text in json_objects:
		obj_text = _repair_json(obj_text)

		var parsed = JSON.parse_string(obj_text)

		if parsed == null:
			continue

		if typeof(parsed) != TYPE_DICTIONARY:
			continue

		for k in parsed.keys():
			facts[k] = parsed[k]

	# 2. Fallback line parser
	var line_facts := _parse_key_value_lines(raw)

	for k in line_facts.keys():
		if not facts.has(k):
			facts[k] = line_facts[k]

	# ---------------------------------------------------------
	# VALIDATE
	# ---------------------------------------------------------

	if facts.is_empty():
		status_lbl.text = "No usable facts found."
		return

	var existing := {}

	for row in cells_container.get_children():
		var kn := row.get_node_or_null("Key")

		if kn == null:
			continue

		var k := String(kn.text.strip_edges().to_lower())

		if k != "":
			existing[k] = true

	var added := 0

	for raw_key in facts.keys():
		var raw_val = facts[raw_key]

		if typeof(raw_val) == TYPE_ARRAY:
			continue

		if typeof(raw_val) == TYPE_DICTIONARY:
			continue

		var k := str(raw_key).strip_edges().to_lower()
		var v := str(raw_val).strip_edges()

		k = _sanitize_key(k)
		v = _sanitize_value(v)

		if not _is_valid_memory_key(k):
			continue

		if not _is_valid_memory_value(v):
			continue

		if existing.has(k):
			continue

		existing[k] = true

		_add_cell(k, v)

		added += 1

	print("========= FINAL FACTS =========")
	print(facts)

	if added == 0:
		status_lbl.text = "No new facts."
	else:
		status_lbl.text = "+%d new facts" % added

# -- Cleanup helpers ------------------------------------------------------------
func _strip_think_tags(text: String) -> String:
	var regex := RegEx.new()
	regex.compile("<think>[\\s\\S]*?</think>")
	return regex.sub(text, "", true)

func _strip_markdown(text: String) -> String:
	text = text.replace("```json", "")
	text = text.replace("```", "")
	return text

# -- JSON extraction ------------------------------------------------------------
func _extract_all_json_objects(text: String) -> Array:
	var results := []

	var depth := 0
	var start := -1

	var in_string := false
	var escape := false

	for i in range(text.length()):
		var c := text[i]

		if escape:
			escape = false
			continue

		if c == "\\":
			escape = true
			continue

		if c == "\"":
			in_string = not in_string
			continue

		if in_string:
			continue

		if c == "{":
			if depth == 0:
				start = i

			depth += 1

		elif c == "}":
			depth -= 1

			if depth == 0 and start != -1:
				results.append(
					text.substr(start, i - start + 1)
				)

	return results

# -- Key:value fallback ---------------------------------------------------------
func _parse_key_value_lines(text: String) -> Dictionary:
	var result := {}

	var lines := text.split("\n")

	for line in lines:
		line = line.strip_edges()

		if line == "":
			continue

		if ":" not in line:
			continue

		var idx := line.find(":")

		if idx == -1:
			continue

		var k := line.substr(0, idx).strip_edges().to_lower()
		var v := line.substr(idx + 1).strip_edges()

		k = _sanitize_key(k)
		v = _sanitize_value(v)

		if _is_valid_memory_key(k) and _is_valid_memory_value(v):
			result[k] = v

	return result

# -- JSON repair ---------------------------------------------------------------
func _repair_json(text: String) -> String:
	text = text.strip_edges()

	text = text.replace("'", "\"")

	var regex := RegEx.new()

	regex.compile(",\\s*}")
	text = regex.sub(text, "}", true)

	regex.compile(",\\s*]")
	text = regex.sub(text, "]", true)

	text = text.replace("\n", " ")

	return text

# -- Sanitizers ----------------------------------------------------------------
func _sanitize_key(k: String) -> String:
	k = k.to_lower()

	var regex := RegEx.new()
	regex.compile("[^a-z0-9_]+")

	k = regex.sub(k, "_", true)

	while "__" in k:
		k = k.replace("__", "_")

	k = k.trim_prefix("_")
	k = k.trim_suffix("_")

	return k

func _sanitize_value(v: String) -> String:
	v = v.strip_edges()

	v = v.replace("\n", " ")
	v = v.replace("\r", " ")
	v = v.replace("\"", "")

	while "  " in v:
		v = v.replace("  ", " ")

	return v

# -- Validation ----------------------------------------------------------------
func _is_valid_memory_key(k: String) -> bool:
	if k.length() < 1:
		return false

	if k.length() > 40:
		return false

	var regex := RegEx.new()
	regex.compile("^[a-z0-9_]+$")

	if regex.search(k) == null:
		return false

	var banned := {
		"summary": true,
		"context": true,
		"memory": true,
		"conversation": true,
		"assistant": true,
		"user": true,
		"response": true
	}

	if banned.has(k):
		return false

	return true

func _is_valid_memory_value(v: String) -> bool:
	if v.length() < 1:
		return false

	if v.length() > 120:
		return false

	if "\n" in v:
		return false

	if "```" in v:
		return false

	if v.count(".") >= 5:
		return false

	if v.count(",") >= 10:
		return false

	var lower := v.to_lower()

	var bad_phrases := [
		"this conversation",
		"the user",
		"assistant",
		"summary",
		"discussed",
		"mentioned",
		"talked about"
	]

	for phrase in bad_phrases:
		if phrase in lower:
			return false

	return true

# -- Cell management -----------------------------------------------------------
func _add_cell(key: String, value: String) -> void:
	var row := HBoxContainer.new()

	row.size_flags_horizontal = Control.SIZE_FILL

	row.add_theme_constant_override("separation", 6)

	var key_edit := LineEdit.new()

	key_edit.name = "Key"
	key_edit.placeholder_text = "key"
	key_edit.text = key
	key_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	key_edit.custom_minimum_size = Vector2(0, 32)

	row.add_child(key_edit)

	var val_edit := LineEdit.new()

	val_edit.name = "Value"
	val_edit.placeholder_text = "value"
	val_edit.text = value
	val_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	val_edit.custom_minimum_size = Vector2(0, 32)

	row.add_child(val_edit)

	var del_btn := Button.new()

	del_btn.text = "X"
	del_btn.flat = true
	del_btn.custom_minimum_size = Vector2(30, 32)

	del_btn.pressed.connect(func(): row.queue_free())

	row.add_child(del_btn)

	cells_container.add_child(row)

func _clear_cells() -> void:
	for child in cells_container.get_children():
		child.queue_free()
