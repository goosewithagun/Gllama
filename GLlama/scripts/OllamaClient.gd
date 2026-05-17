## ============================================================
## OllamaClient.gd
## ------------------------------------------------------------
## Handles all HTTP communication with the Ollama REST API.
## Supports streaming responses via HTTPClient in a background Thread.
##
## PUBLIC API:
##   set_host(url)                  — point at a different Ollama server
##   fetch_models()                 — GET /api/tags → models_loaded signal
##   send_chat(messages, model, system_prompt, options)
##   send_chat_raw(messages, model, options)   ← main entry point
##   abort_stream()                 — signal background thread to stop
##   is_streaming() → bool
##
## OPTIONS DICTIONARY (passed as 3rd arg to send_chat_raw):
##   "temperature"  float   0.0–2.0   model creativity
##   "num_predict"  int     >0         max output tokens (-1 = unlimited)
##   "num_ctx"      int     >0         context window size in tokens
##   Any Ollama /api/chat "options" key is forwarded as-is.
## ============================================================

extends Node

# ── Signals ──────────────────────────────────────────────────────────────────
signal models_loaded(model_names: Array)
signal models_failed(error: String)
signal stream_chunk(text: String)   ## One token fragment received
signal stream_done()                ## Stream completed cleanly
signal stream_error(error: String)  ## Stream failed

# ── State ─────────────────────────────────────────────────────────────────────
var host: String = "http://127.0.0.1:11434"

var _stream_thread: Thread = null
var _stop_stream:   bool   = false
var _streaming:     bool   = false

# ── Public API ────────────────────────────────────────────────────────────────

func set_host(new_host: String) -> void:
	host = new_host.rstrip("/")


## Fetches the list of locally available models from GET /api/tags.
## Emits models_loaded(Array of name strings) on success,
## or models_failed(error string) on failure.
func fetch_models() -> void:
	var http_req := HTTPRequest.new()
	add_child(http_req)
	http_req.request_completed.connect(
		func(result, code, _headers, body):
			http_req.queue_free()
			if result != HTTPRequest.RESULT_SUCCESS or code != 200:
				models_failed.emit("HTTP error %d (result %d)" % [code, result])
				return
			var json = JSON.parse_string(body.get_string_from_utf8())
			if json == null or not json.has("models"):
				models_failed.emit("Unexpected response from /api/tags")
				return
			var names: Array = []
			for m in json["models"]:
				names.append(m["name"])
			models_loaded.emit(names)
	)
	var err := http_req.request(host + "/api/tags")
	if err != OK:
		http_req.queue_free()
		models_failed.emit("Could not reach Ollama at " + host)


## Convenience wrapper: prepends system_prompt as a system role message,
## then delegates to send_chat_raw.
## options: Dictionary — see file header for supported keys.
func send_chat(messages: Array, model: String, system_prompt: String = "", options: Dictionary = {}) -> void:
	var full_messages: Array = []
	if system_prompt.strip_edges() != "":
		full_messages.append({"role": "system", "content": system_prompt.strip_edges()})
	full_messages.append_array(messages)
	send_chat_raw(full_messages, model, options)


## Sends a fully assembled messages array to POST /api/chat with streaming.
## options dictionary is forwarded as the Ollama "options" field:
##   temperature  → controls randomness
##   num_predict  → max tokens to generate
##   num_ctx      → context window size
##
## If a stream is already running it is stopped first (wait_to_finish).
func send_chat_raw(messages: Array, model: String, options: Dictionary = {}) -> void:
	## Stop any existing stream cleanly before starting a new one
	if _stream_thread != null:
		if _stream_thread.is_started():
			_stop_stream = true
			_stream_thread.wait_to_finish()
		_stream_thread = null

	_stop_stream = false
	_streaming   = true

	## Build the Ollama /api/chat payload
	var payload := {
		"model":    model,
		"messages": messages,
		"stream":   true
	}

	## Attach model parameters only if any were provided
	## Ollama accepts: temperature, num_predict, num_ctx, top_p, top_k, etc.
	if not options.is_empty():
		## Build a clean options dict (skip zero/negative num_predict)
		var ollama_options := {}
		for key in options:
			var val = options[key]
			## Skip num_predict of 0 or negative (let model use its default)
			if key == "num_predict" and int(val) <= 0:
				continue
			ollama_options[key] = val
		if not ollama_options.is_empty():
			payload["options"] = ollama_options

	var body_str := JSON.stringify(payload)

	_stream_thread = Thread.new()
	_stream_thread.start(_stream_worker.bind(body_str))


func abort_stream() -> void:
	## Signals the background thread to stop at the next poll cycle
	_stop_stream = true


func is_streaming() -> bool:
	return _streaming


# ── Streaming worker (background thread) ──────────────────────────────────────
## Runs in a separate thread. Uses HTTPClient for fine-grained chunk reading.
## Calls back to the main thread via call_deferred().

func _stream_worker(body_str: String) -> void:
	var parsed        := _parse_host(host)
	var domain: String = parsed[1]
	var port: int      = parsed[2]

	var client := HTTPClient.new()

	var err := client.connect_to_host(domain, port)
	if err != OK:
		call_deferred("_finish_error", "Cannot connect to %s:%d" % [domain, port])
		return

	var waited := 0.0
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		OS.delay_msec(50)
		client.poll()
		waited += 0.05
		if waited >= 5.0:
			client.close()
			call_deferred("_finish_error", "Connection timed out")
			return

	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		client.close()
		call_deferred("_finish_error", "Failed to connect (status %d)" % client.get_status())
		return

	var body_bytes := body_str.to_utf8_buffer()
	var headers := [
		"Content-Type: application/json",
		"Content-Length: " + str(body_bytes.size())
	]

	err = client.request_raw(HTTPClient.METHOD_POST, "/api/chat", headers, body_bytes)
	if err != OK:
		client.close()
		call_deferred("_finish_error", "Request send failed (err %d)" % err)
		return

	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		OS.delay_msec(20)
		client.poll()
		if _stop_stream:
			client.close()
			call_deferred("_finish_done")
			return

	if not client.has_response():
		client.close()
		call_deferred("_finish_error", "No response from server")
		return

	var response_code := client.get_response_code()
	if response_code != 200:
		var err_body := ""
		while client.get_status() == HTTPClient.STATUS_BODY:
			client.poll()
			var chunk := client.read_response_body_chunk()
			if chunk.size() > 0:
				err_body += chunk.get_string_from_utf8()
		client.close()
		var err_json = JSON.parse_string(err_body)
		var err_msg  := ""
		if err_json and err_json.has("error"):
			err_msg = err_json["error"]
		else:
			err_msg = "HTTP %d" % response_code
		call_deferred("_finish_error", err_msg)
		return

	## Read streaming NDJSON response line by line
	var partial := ""
	while client.get_status() == HTTPClient.STATUS_BODY:
		if _stop_stream:
			break
		client.poll()
		var chunk: PackedByteArray = client.read_response_body_chunk()
		if chunk.size() == 0:
			OS.delay_msec(10)
			continue

		partial += chunk.get_string_from_utf8()

		## Process every complete line (separated by \n)
		while "\n" in partial:
			var nl   := partial.find("\n")
			var line := partial.substr(0, nl).strip_edges()
			partial   = partial.substr(nl + 1)
			if line == "":
				continue
			var json = JSON.parse_string(line)
			if json == null:
				continue
			var done: bool = json.get("done", false)
			if json.has("message"):
				var content: String = json["message"].get("content", "")
				if content != "":
					call_deferred("_emit_chunk", content)
			if done:
				break

	client.close()

	## Flush any trailing partial line that arrived without a final newline
	if partial.strip_edges() != "":
		var json = JSON.parse_string(partial.strip_edges())
		if json != null and json.has("message"):
			var content: String = json["message"].get("content", "")
			if content != "":
				call_deferred("_emit_chunk", content)

	call_deferred("_finish_done")


# ── Deferred callbacks (main thread) ──────────────────────────────────────────

func _emit_chunk(text: String) -> void:
	stream_chunk.emit(text)

func _finish_done() -> void:
	_cleanup_thread()
	_streaming = false
	stream_done.emit()

func _finish_error(msg: String) -> void:
	_cleanup_thread()
	_streaming = false
	stream_error.emit(msg)

func _cleanup_thread() -> void:
	if _stream_thread != null:
		if _stream_thread.is_started():
			_stream_thread.wait_to_finish()
		_stream_thread = null


# ── Helpers ───────────────────────────────────────────────────────────────────

func _parse_host(raw: String) -> Array:
	var scheme := "http"
	var domain := raw
	var port   := 11434

	if raw.begins_with("https://"):
		scheme = "https"
		domain = raw.substr(8)
		port   = 443
	elif raw.begins_with("http://"):
		domain = raw.substr(7)
		port   = 80

	if ":" in domain:
		var parts := domain.split(":")
		domain = parts[0]
		port   = int(parts[1])

	return [scheme, domain, port]
