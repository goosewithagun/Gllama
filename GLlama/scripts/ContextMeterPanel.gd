## ============================================================
## ContextMeterPanel.gd
## ------------------------------------------------------------
## Compact sidebar panel showing context + system usage.
##
## CONTEXT BAR SEGMENTS (left → right):
##   ■ Static ctx   — System Context TextEdit chars (≈ tokens)
##   ■ Short ctx    — Short Context summary chars (≈ tokens)
##   ■ Chat history — trimmed history chars (≈ tokens)
##   □ Free         — remainder up to Context Limit
##   (Max Output is NOT counted — it is a generation cap, not
##    pre-consumed context.)
##
## SYSTEM ROWS:
##   RAM  — total system RAM used (MB/GB), polled via PowerShell every 2.5 s
##   CPU  — average CPU load % across all cores, polled via PowerShell
##
## TOKEN APPROXIMATION:  4 chars ≈ 1 token  (labeled ≈)
## ============================================================

extends PanelContainer

# ── Layout constants ────────────────────────────────────────
const CHARS_PER_TOKEN : float = 4.0
const BAR_HEIGHT      : int   = 12
const ROW_FS          : int   = 11

# ── Colours ─────────────────────────────────────────────────
const COL_STATIC  := Color(0.30, 0.55, 0.90, 1.0)
const COL_SHORT   := Color(0.35, 0.80, 0.60, 1.0)
const COL_HISTORY := Color(0.75, 0.60, 0.25, 1.0)
const COL_FREE    := Color(0.18, 0.18, 0.23, 1.0)
const COL_OVER    := Color(0.90, 0.25, 0.25, 1.0)
const COL_RAM     := Color(0.40, 0.72, 0.95, 1.0)
const COL_CPU     := Color(0.95, 0.65, 0.30, 1.0)

# ── Context state ───────────────────────────────────────────
var _static_chars:  int = 0
var _short_chars:   int = 0
var _history_chars: int = 0
var _ctx_limit:     int = 4096

# ── System stats polling (real OS values via PowerShell) ────
var _sys_ram_mb:    float  = 0.0
var _sys_cpu_pct:   float  = 0.0
var _sys_timer:     float  = 0.0
var _sys_pending:   bool   = false
var _sys_thread:    Thread = null
var _sys_mutex:     Mutex  = Mutex.new()
const SYS_INTERVAL: float  = 2.5

# ── Node refs ───────────────────────────────────────────────
var _bar:        Control
var _lbl_limit:  Label
var _lbl_used:   Label
var _lbl_free:   Label
var _lbl_static: Label
var _lbl_short:  Label
var _lbl_hist:   Label
var _warn_lbl:   Label
var _lbl_ram:    Label
var _lbl_cpu:    Label


func _ready() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.13, 0.17, 1)
	sb.corner_radius_top_left     = 6
	sb.corner_radius_top_right    = 6
	sb.corner_radius_bottom_left  = 6
	sb.corner_radius_bottom_right = 6
	sb.content_margin_left   = 8
	sb.content_margin_right  = 8
	sb.content_margin_top    = 6
	sb.content_margin_bottom = 6
	add_theme_stylebox_override("panel", sb)

	## Shrink to content — do NOT expand and push siblings out
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	add_child(vbox)

	## Title + limit
	var title_row := HBoxContainer.new()
	vbox.add_child(title_row)

	var title_lbl := Label.new()
	title_lbl.text = "CONTEXT USAGE"
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.add_theme_font_size_override("font_size", 10)
	title_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	title_row.add_child(title_lbl)

	_lbl_limit = Label.new()
	_lbl_limit.text = "/ 4096 tok"
	_lbl_limit.add_theme_font_size_override("font_size", 10)
	_lbl_limit.add_theme_color_override("font_color", Color(0.4, 0.4, 0.5))
	title_row.add_child(_lbl_limit)

	## Stacked bar
	_bar = Control.new()
	_bar.custom_minimum_size = Vector2(0, BAR_HEIGHT)
	_bar.size_flags_horizontal = Control.SIZE_FILL
	_bar.draw.connect(_draw_bar)
	vbox.add_child(_bar)

	## Used / free summary row
	var sum_row := HBoxContainer.new()
	vbox.add_child(sum_row)

	_lbl_used = Label.new()
	_lbl_used.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lbl_used.add_theme_font_size_override("font_size", ROW_FS)
	_lbl_used.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
	_lbl_used.text = "≈ 0 tok used"
	sum_row.add_child(_lbl_used)

	_lbl_free = Label.new()
	_lbl_free.add_theme_font_size_override("font_size", ROW_FS)
	_lbl_free.add_theme_color_override("font_color", Color(0.4, 0.65, 0.4))
	_lbl_free.text = "free: 4096"
	sum_row.add_child(_lbl_free)

	## Context legend rows
	_lbl_static = _make_legend_row(vbox, COL_STATIC,  "Static ctx")
	_lbl_short  = _make_legend_row(vbox, COL_SHORT,   "Short ctx")
	_lbl_hist   = _make_legend_row(vbox, COL_HISTORY, "History")

	## Overflow warning
	_warn_lbl = Label.new()
	_warn_lbl.add_theme_font_size_override("font_size", ROW_FS)
	_warn_lbl.add_theme_color_override("font_color", COL_OVER)
	_warn_lbl.text = "⚠ Over context limit!"
	_warn_lbl.visible = false
	vbox.add_child(_warn_lbl)

	## Divider
	vbox.add_child(HSeparator.new())

	## System section title
	var sys_title := Label.new()
	sys_title.text = "SYSTEM"
	sys_title.add_theme_font_size_override("font_size", 10)
	sys_title.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	vbox.add_child(sys_title)

	## System stats row: RAM and CPU side by side
	var sys_row := HBoxContainer.new()
	sys_row.add_theme_constant_override("separation", 10)
	vbox.add_child(sys_row)

	## RAM half
	var ram_half := HBoxContainer.new()
	ram_half.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ram_half.add_theme_constant_override("separation", 5)
	sys_row.add_child(ram_half)

	var ram_dot := ColorRect.new()
	ram_dot.color = COL_RAM
	ram_dot.custom_minimum_size = Vector2(8, 8)
	ram_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ram_half.add_child(ram_dot)

	var ram_cap := Label.new()
	ram_cap.text = "RAM"
	ram_cap.add_theme_font_size_override("font_size", ROW_FS)
	ram_cap.add_theme_color_override("font_color", Color(0.55, 0.55, 0.62))
	ram_half.add_child(ram_cap)

	_lbl_ram = Label.new()
	_lbl_ram.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lbl_ram.add_theme_font_size_override("font_size", ROW_FS)
	_lbl_ram.add_theme_color_override("font_color", Color(0.82, 0.82, 0.88))
	_lbl_ram.text = "—"
	ram_half.add_child(_lbl_ram)

	## CPU half
	var cpu_half := HBoxContainer.new()
	cpu_half.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cpu_half.add_theme_constant_override("separation", 5)
	sys_row.add_child(cpu_half)

	var cpu_dot := ColorRect.new()
	cpu_dot.color = COL_CPU
	cpu_dot.custom_minimum_size = Vector2(8, 8)
	cpu_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	cpu_half.add_child(cpu_dot)

	var cpu_cap := Label.new()
	cpu_cap.text = "CPU"
	cpu_cap.add_theme_font_size_override("font_size", ROW_FS)
	cpu_cap.add_theme_color_override("font_color", Color(0.55, 0.55, 0.62))
	cpu_half.add_child(cpu_cap)

	_lbl_cpu = Label.new()
	_lbl_cpu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lbl_cpu.add_theme_font_size_override("font_size", ROW_FS)
	_lbl_cpu.add_theme_color_override("font_color", Color(0.82, 0.82, 0.88))
	_lbl_cpu.text = "—"
	cpu_half.add_child(_lbl_cpu)

	_refresh_display()
	_start_sys_poll()   ## first real OS stats fetch


func _process(delta: float) -> void:
	_sys_timer += delta
	if _sys_timer >= SYS_INTERVAL and not _sys_pending:
		_sys_timer = 0.0
		_start_sys_poll()


## Called by Main.gd whenever context parameters change.
## _max_output_toks is accepted but intentionally ignored in the bar.
func refresh(static_chars: int, short_chars: int, history_chars: int,
			 _max_output_toks: int, ctx_limit_toks: int) -> void:
	_static_chars  = static_chars
	_short_chars   = short_chars
	_history_chars = history_chars
	_ctx_limit     = ctx_limit_toks
	_refresh_display()


func _refresh_display() -> void:
	if not is_node_ready():
		return

	var static_tok : int  = int(ceil(_static_chars  / CHARS_PER_TOKEN))
	var short_tok  : int  = int(ceil(_short_chars   / CHARS_PER_TOKEN))
	var hist_tok   : int  = int(ceil(_history_chars / CHARS_PER_TOKEN))
	var total_used : int  = static_tok + short_tok + hist_tok
	var limit      : int  = max(_ctx_limit, 1)
	var free_tok   : int  = limit - total_used
	var over       : bool = total_used > limit

	_lbl_limit.text = "/ %d tok" % limit
	_lbl_used.text  = "≈ %d tok used" % total_used

	if over:
		_lbl_free.text = "over: %d" % (total_used - limit)
		_lbl_free.add_theme_color_override("font_color", COL_OVER)
	else:
		_lbl_free.text = "free: %d" % free_tok
		_lbl_free.add_theme_color_override("font_color", Color(0.4, 0.65, 0.4))

	_lbl_static.text = "%d tok  (%d ch)" % [static_tok, _static_chars]
	_lbl_short.text  = "%d tok  (%d ch)" % [short_tok,  _short_chars]
	_lbl_hist.text   = "%d tok  (%d ch)" % [hist_tok,   _history_chars]
	_warn_lbl.visible = over

	_update_system_labels()

	if _bar != null:
		_bar.queue_redraw()


func _update_system_labels() -> void:
	if _lbl_ram == null or _lbl_cpu == null:
		return
	_sys_mutex.lock()
	var ram: float = _sys_ram_mb
	var cpu: float = _sys_cpu_pct
	_sys_mutex.unlock()

	if ram <= 0.0:
		_lbl_ram.text = "—"
	elif ram >= 1024.0:
		_lbl_ram.text = "%.2f GB" % (ram / 1024.0)
	else:
		_lbl_ram.text = "%.0f MB" % ram

	if cpu <= 0.0:
		_lbl_cpu.text = "—"
	else:
		_lbl_cpu.text = "%.0f %%" % cpu


## Launches a background thread to query real RAM + CPU from the OS.
func _start_sys_poll() -> void:
	if _sys_pending:
		return
	_sys_pending = true
	_sys_thread  = Thread.new()
	_sys_thread.start(_fetch_sys_stats)


## Runs on a background thread — do NOT touch nodes here.
## Two simple PowerShell expressions; no complex quoting, no wmic dependency.
## call_deferred fires _on_stats_fetched on the main thread once done.
func _fetch_sys_stats() -> void:
	if OS.get_name() == "Windows":
		## ── RAM: used system memory in MB ──────────────────────────
		var ram_out: Array = []
		OS.execute("powershell", [
			"-NoProfile", "-NonInteractive", "-Command",
			"$o=Get-CimInstance Win32_OperatingSystem;" +
			"[math]::Round(($o.TotalVisibleMemorySize-$o.FreePhysicalMemory)/1024)"
		], ram_out)
		var ram_str: String = "".join(ram_out).strip_edges()
		## Strip any stray CR, LF or extra digits beyond the first line
		ram_str = ram_str.split("\n")[0].strip_edges()
		if ram_str.is_valid_int():
			_sys_mutex.lock()
			_sys_ram_mb = float(ram_str.to_int())
			_sys_mutex.unlock()

		## ── CPU: average load % across all logical cores ───────────
		var cpu_out: Array = []
		OS.execute("powershell", [
			"-NoProfile", "-NonInteractive", "-Command",
			"[math]::Round((Get-CimInstance Win32_Processor" +
			"|Measure-Object -Property LoadPercentage -Average).Average)"
		], cpu_out)
		var cpu_str: String = "".join(cpu_out).strip_edges()
		cpu_str = cpu_str.split("\n")[0].strip_edges()
		if cpu_str.is_valid_float() or cpu_str.is_valid_int():
			_sys_mutex.lock()
			_sys_cpu_pct = cpu_str.to_float()
			_sys_mutex.unlock()

	## Signal the main thread that new data is ready.
	## call_deferred is safe from threads and runs after this func returns.
	call_deferred("_on_stats_fetched")


## Called on the main thread (via call_deferred) once the poll thread finishes.
func _on_stats_fetched() -> void:
	if _sys_thread != null:
		_sys_thread.wait_to_finish()
		_sys_thread = null
	_sys_pending = false
	_update_system_labels()


## Clean up thread on node removal to avoid crashes.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _sys_thread != null:
		_sys_thread.wait_to_finish()


func _draw_bar() -> void:
	var w : float = _bar.size.x
	var h : float = float(BAR_HEIGHT)

	var static_tok : int   = int(ceil(_static_chars  / CHARS_PER_TOKEN))
	var short_tok  : int   = int(ceil(_short_chars   / CHARS_PER_TOKEN))
	var hist_tok   : int   = int(ceil(_history_chars / CHARS_PER_TOKEN))
	var total_used : int   = static_tok + short_tok + hist_tok
	var limit      : float = float(max(_ctx_limit, 1))

	var bg_col : Color = COL_OVER if total_used > int(limit) else COL_FREE
	_bar.draw_rect(Rect2(0.0, 0.0, w, h), bg_col)

	var segments : Array = [
		[static_tok, COL_STATIC],
		[short_tok,  COL_SHORT],
		[hist_tok,   COL_HISTORY],
	]

	var x : float = 0.0
	for seg in segments:
		var toks : int   = seg[0]
		var col  : Color = seg[1]
		if toks <= 0:
			continue
		var seg_w : float = clampf(float(toks) / limit * w, 0.0, w - x)
		if seg_w < 1.0:
			seg_w = 1.0
		_bar.draw_rect(Rect2(x, 0.0, seg_w, h), col)
		x += seg_w
		if x >= w:
			break

	_bar.draw_rect(Rect2(0.0, 0.0, w, h), Color(0.0, 0.0, 0.0, 0.35), false, 1.0)


func _make_legend_row(parent: VBoxContainer, col: Color, caption: String) -> Label:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	parent.add_child(row)

	var dot := ColorRect.new()
	dot.color = col
	dot.custom_minimum_size = Vector2(8, 8)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(dot)

	var cap := Label.new()
	cap.text = caption
	cap.custom_minimum_size = Vector2(68, 0)
	cap.add_theme_font_size_override("font_size", ROW_FS)
	cap.add_theme_color_override("font_color", Color(0.55, 0.55, 0.62))
	row.add_child(cap)

	var val := Label.new()
	val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	val.add_theme_font_size_override("font_size", ROW_FS)
	val.add_theme_color_override("font_color", Color(0.82, 0.82, 0.88))
	val.text = "—"
	row.add_child(val)

	return val
