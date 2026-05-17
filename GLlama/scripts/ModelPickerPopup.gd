## ModelPickerPopup.gd
## A modal popup that lets the user:
##   • See all locally installed models
##   • Select one to use for chat
##   • Type a model name and pull it from the Ollama registry
##
## Attach to a Window node. Call show_popup() to open it.

extends Window

# ── Signals ───────────────────────────────────────────────────────────────────
signal model_selected(model_name: String)

# ── Node refs ─────────────────────────────────────────────────────────────────
@onready var model_list: ItemList     = $MarginContainer/VBox/ModelList
@onready var pull_input: LineEdit     = $MarginContainer/VBox/PullRow/PullInput
@onready var pull_btn: Button         = $MarginContainer/VBox/PullRow/PullButton
@onready var select_btn: Button       = $MarginContainer/VBox/BottomRow/SelectButton
@onready var cancel_btn: Button       = $MarginContainer/VBox/BottomRow/CancelButton
@onready var status_lbl: Label        = $MarginContainer/VBox/StatusLabel
@onready var progress_bar: ProgressBar = $MarginContainer/VBox/PullProgress

var _manager: Node = null   # OllamaManager reference
var _selected_name: String = ""

# ── Setup ─────────────────────────────────────────────────────────────────────

func setup(manager: Node) -> void:
	_manager = manager
	_manager.models_listed.connect(_on_models_listed)
	_manager.pull_progress.connect(_on_pull_progress)
	_manager.pull_done.connect(_on_pull_done)
	_manager.pull_failed.connect(_on_pull_failed)


func show_popup() -> void:
	_selected_name = ""
	select_btn.disabled = true
	status_lbl.text = "Loading installed models…"
	progress_bar.visible = false
	pull_input.text = ""
	pull_btn.disabled = false
	model_list.clear()
	popup_centered()
	_manager.list_models()


# ── Model list ────────────────────────────────────────────────────────────────

func _on_models_listed(names: Array) -> void:
	model_list.clear()
	if names.is_empty():
		status_lbl.text = "No models installed. Pull one below."
		return
	for n in names:
		model_list.add_item(n)
	status_lbl.text = "Select a model, or pull a new one."


func _on_item_selected(index: int) -> void:
	_selected_name = model_list.get_item_text(index)
	select_btn.disabled = false


func _on_item_activated(index: int) -> void:
	_selected_name = model_list.get_item_text(index)
	_confirm_selection()


# ── Pull ──────────────────────────────────────────────────────────────────────

func _on_pull_pressed() -> void:
	var name := pull_input.text.strip_edges()
	if name == "":
		status_lbl.text = "Enter a model name first  (e.g.  llama3  or  mistral)"
		return
	status_lbl.text = "Pulling  %s …" % name
	progress_bar.value = 0
	progress_bar.visible = true
	pull_btn.disabled = true
	select_btn.disabled = true
	_manager.pull_model(name)


func _on_pull_progress(_model: String, _status_text: String, percent: float) -> void:
	progress_bar.value = percent
	status_lbl.text = _status_text


func _on_pull_done(model_name: String) -> void:
	progress_bar.visible = false
	pull_btn.disabled = false
	status_lbl.text = "Pull complete: " + model_name
	pull_input.text = ""
	_manager.list_models()


func _on_pull_failed(model_name: String, error: String) -> void:
	progress_bar.visible = false
	pull_btn.disabled = false
	status_lbl.text = "Pull failed for %s: %s" % [model_name, error]


# ── Buttons ───────────────────────────────────────────────────────────────────

func _on_select_pressed() -> void:
	_confirm_selection()


func _on_cancel_pressed() -> void:
	hide()


func _confirm_selection() -> void:
	if _selected_name == "":
		return
	model_selected.emit(_selected_name)
	hide()


# ── Ready ─────────────────────────────────────────────────────────────────────

func _ready() -> void:
	close_requested.connect(func(): hide())
	model_list.item_selected.connect(_on_item_selected)
	model_list.item_activated.connect(_on_item_activated)
	pull_btn.pressed.connect(_on_pull_pressed)
	select_btn.pressed.connect(_on_select_pressed)
	cancel_btn.pressed.connect(_on_cancel_pressed)

	title = "Choose Model"
	min_size = Vector2(480, 420)
	exclusive = true
	unresizable = false
