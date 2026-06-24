extends RefCounted

# Gestisce la musica del menu principale con rotazione random continua.
#
# Pool: tracce in Tracks/Menu/ (mp3/ogg) + vanilla "Far" (sempre inclusa).
# Quando una traccia finisce ne parte automaticamente un'altra diversa (no-repeat).
# Rispetta il toggle "Menu Music off" del gioco (stream_paused).
#
# La risorsa vanilla (loop=true nell'import) non viene mai modificata:
# ne creiamo una copia con loop=false, memorizzata in _loopless_cache
# per evitare riallocazioni a ogni rotazione.

const _DEBUG := false
const FADE_DURATION := 1.0
const MENU_DEFAULT_PATH := "res://Audio/Music/Road_to_Vostok_OST_Far.mp3"

var _library = null
var _parent_node: Node = null

var _menu_audio: AudioStreamPlayer = null
var _vanilla_stream: AudioStream   = null
var _last_stream: AudioStream      = null
var _started_once: bool            = false
var _loopless_cache: Dictionary    = {}
var _tween: Tween                  = null

func setup(library, parent_node: Node) -> void:
	_library     = library
	_parent_node = parent_node

func tick() -> void:
	var scene: Node = _parent_node.get_tree().current_scene
	if scene == null:
		return

	if _parent_node.get_tree().root.get_node_or_null("Map/Core") != null:
		if _menu_audio != null:
			_reset_state()
		return

	var audio := scene.get_node_or_null("Audio") as AudioStreamPlayer
	if audio == null:
		if _menu_audio != null:
			_reset_state()
		return

	if audio != _menu_audio:
		_menu_audio     = audio
		_vanilla_stream = audio.stream
		_started_once   = false
		_last_stream    = null
		if _DEBUG: print("[echoes-of-vostok] Menu: nodo Audio rilevato su '%s'." % scene.name)

	if audio.stream_paused:
		return

	if not _started_once or not audio.is_playing():
		_play_random(audio)

# ── Internals ─────────────────────────────────────────────────────────────────

func _reset_state() -> void:
	if _tween != null and is_instance_valid(_tween):
		_tween.kill()
	_tween          = null
	_menu_audio     = null
	_vanilla_stream = null
	_last_stream    = null
	_started_once   = false

func _build_pool() -> Array:
	var pool: Array = []

	for s in _library.tracks_menu:
		pool.append(s)

	var vanilla: AudioStream = _vanilla_stream
	if vanilla == null and ResourceLoader.exists(MENU_DEFAULT_PATH):
		vanilla = load(MENU_DEFAULT_PATH)
	if vanilla != null and not pool.has(vanilla):
		pool.append(vanilla)

	return pool

func _play_random(audio: AudioStreamPlayer) -> void:
	var pool: Array = _build_pool()
	if pool.is_empty():
		return

	var idx: int = randi() % pool.size()
	if pool.size() > 1 and pool[idx] == _last_stream:
		idx = (idx + 1) % pool.size()

	var chosen: AudioStream  = pool[idx]
	var prepared: AudioStream = _prepare_loopless(chosen)

	if _tween != null and is_instance_valid(_tween):
		_tween.kill()
	_tween = null

	audio.stop()
	audio.stream = prepared
	audio.volume_db = -80.0
	audio.play()
	_tween = _parent_node.create_tween()
	_tween.tween_property(audio, "volume_db", 0.0, FADE_DURATION)

	_last_stream  = chosen
	_started_once = true

	if _DEBUG: print("[echoes-of-vostok] Menu: traccia %d/%d avviata." % [idx + 1, pool.size()])

func _prepare_loopless(stream: AudioStream) -> AudioStream:
	if stream == null:
		return stream

	var has_loop := false
	if stream is AudioStreamMP3:
		has_loop = (stream as AudioStreamMP3).loop
	elif stream is AudioStreamOggVorbis:
		has_loop = (stream as AudioStreamOggVorbis).loop

	if not has_loop:
		return stream

	var cache_key: int = stream.get_instance_id()
	if _loopless_cache.has(cache_key):
		return _loopless_cache[cache_key]

	var copy: AudioStream = stream.duplicate() as AudioStream
	if copy is AudioStreamMP3:
		(copy as AudioStreamMP3).loop = false
	elif copy is AudioStreamOggVorbis:
		(copy as AudioStreamOggVorbis).loop = false

	_loopless_cache[cache_key] = copy
	return copy
