extends RefCounted

# Gestisce la selezione delle tracce in gameplay.
# Strategia: invece di iniettare negli array tipizzati di Audio.gd (inaffidabile),
# intercettiamo direttamente il momento in cui la musica smette di suonare.
# Il nostro autoload processa PRIMA dei nodi scena, quindi quando chiamiamo play()
# vanilla vede is_playing()=true e salta la sua logica di selezione.
#
# Pool combinato: tracce vanilla della zona + tracce mod -> selezione casuale equa.

const ZONE_KEY_MAP := {
	"Shelter":     "shelter",
	"Tutorial":    "shelter",
	"Area 05":     "area05",
	"Border Zone": "borderZone",
	"Vostok":      "vostok",
}

const SELECTION_RANDOM := "random"
const SELECTION_CYCLE := "cycle"
const VANILLA_TRACK_COUNTS := {
	"area05": 4,
	"borderZone": 4,
	"vostok": 4,
	"shelter": 2,
}

var enabled: bool = true
var paused: bool = false
var volume_db_offset: float = 0.0
var selection_mode: String = SELECTION_RANDOM

var _library       = null
var _parent_node: Node = null
var _game_data     = preload("res://Resources/GameData.tres")

var _audio_node: Node             = null
var _music_player: AudioStreamPlayer = null

var _force_stream: AudioStream    = null
var _force_display: String        = ""
var _force_source: String         = "mod"
var _force_zone: String           = "forced"
var _force_tween: Tween           = null
var _cycle_indices_by_zone: Dictionary = {}
var _current_track_info: Dictionary = {}

func setup(library, parent_node: Node) -> void:
	_library     = library
	_parent_node = parent_node

# Chiamato ogni physics frame da Main (senza throttle).
func tick() -> void:
	var audio := _find_audio_node()

	if audio == null:
		if _audio_node != null:
			print("[music-expansion] Gameplay terminato.")
			_audio_node    = null
			_music_player  = null
			_current_track_info.clear()
		return

	if audio != _audio_node:
		_audio_node   = audio
		_music_player = audio.get_node_or_null("Music") as AudioStreamPlayer
		print("[music-expansion] Nodo Audio trovato. Music player: %s" % (
			"ok" if _music_player != null else "NON TROVATO"
		))

	if _music_player == null or not is_instance_valid(_music_player):
		return

	# --- Pausa/Riprendi dal mod menu ---
	if paused or not enabled:
		if _music_player.volume_db != -80.0:
			_music_player.volume_db = -80.0
		return

	# --- Ripristina volume se non c'e' tween attivo ---
	var tween_running := _force_tween != null and is_instance_valid(_force_tween) and _force_tween.is_running()
	if not tween_running:
		var is_ours: bool = _music_player.stream != null and _library.is_our_stream(_music_player.stream)
		var target := volume_db_offset if is_ours else 0.0
		if _music_player.volume_db != target:
			_music_player.volume_db = target

	# --- Se la musica sta suonando non c'e' nulla da fare ---
	if _music_player.is_playing():
		return

	# --- Musica ferma: decidiamo noi cosa suonare ---

	# Rispetta preset "musica off"
	if _game_data.musicPreset == 1:
		return

	# Force esplicito da MCM: ha priorita' assoluta
	if _force_stream != null:
		_play_now(_force_stream, _force_display, _force_source, _force_zone)
		print("[music-expansion] Force: traccia avviata.")
		_clear_queued_force()
		return

	var zone_key := _get_active_preset_zone_key()
	if zone_key.is_empty():
		return

	var pool: Array = _build_zone_pool(zone_key)
	if pool.is_empty():
		return

	var chosen: Dictionary = _select_pool_entry(zone_key, pool)
	var stream: AudioStream = chosen.get("stream", null)
	if stream == null:
		return
	_play_now(stream, str(chosen.get("display", "traccia")), str(chosen.get("source", "")), zone_key)
	print("[music-expansion] Zona '%s': avviata %s." % [
		zone_key,
		str(chosen.get("display", "traccia"))
	])

# ── API pubblica ───────────────────────────────────────────────────────────────

func get_current_track_info() -> Dictionary:
	if _music_player != null and is_instance_valid(_music_player) and _music_player.stream != null:
		var stream_id := _music_player.stream.get_instance_id()
		if int(_current_track_info.get("stream_id", -1)) != stream_id:
			_current_track_info = _build_track_info_for_stream(_music_player.stream)
	return _current_track_info.duplicate()

func get_current_zone_key() -> String:
	return _get_current_zone_key()

func get_resolved_zone_key(zone_key: String) -> String:
	if zone_key == "current":
		return _get_current_zone_key()
	return zone_key

func get_zone_pool_count(zone_key: String) -> int:
	var resolved_zone := get_resolved_zone_key(zone_key)
	if resolved_zone.is_empty():
		return _fallback_pool_count(zone_key)
	var pool: Array = _build_zone_pool(resolved_zone)
	if not pool.is_empty():
		return pool.size()
	return _fallback_pool_count(resolved_zone)

func set_enabled(v: bool) -> void:
	enabled = v
	if not v and _music_player != null and is_instance_valid(_music_player):
		_music_player.volume_db = 0.0

func set_paused(v: bool) -> void:
	paused = v
	if not v and _music_player != null and is_instance_valid(_music_player):
		_music_player.volume_db = 0.0

func set_volume(db: float) -> void:
	volume_db_offset = db

func set_selection_mode(mode: String) -> void:
	selection_mode = SELECTION_CYCLE if mode == SELECTION_CYCLE else SELECTION_RANDOM

# Forza la riproduzione di uno stream con fade out ~1s poi play.
func force_track(stream: AudioStream, display_name: String = "", source: String = "mod", zone_key: String = "forced") -> void:
	print("[music-expansion] force_track richiesto.")
	_force_stream = stream
	_force_display = display_name
	_force_source = source
	_force_zone = zone_key
	if _music_player == null or not is_instance_valid(_music_player):
		print("[music-expansion] force_track: music player non disponibile (non sei in gameplay?).")
		return
	_cancel_tween()
	_music_player.stop()
	_play_now(stream, display_name, source, zone_key)
	_clear_queued_force()

func force_zone_track(zone_key: String, index_zero_based: int) -> void:
	var resolved_zone := get_resolved_zone_key(zone_key)
	if resolved_zone.is_empty():
		push_warning("[music-expansion] Nessuna area valida per il ciclo tracce.")
		return
	var pool: Array = _build_zone_pool(resolved_zone)
	if pool.is_empty():
		push_warning("[music-expansion] Nessuna traccia disponibile per zona '%s'." % resolved_zone)
		return
	var safe_index := posmod(index_zero_based, pool.size())
	var entry: Dictionary = pool[safe_index]
	var stream: AudioStream = entry.get("stream", null)
	if stream == null:
		push_warning("[music-expansion] Traccia #%d non valida per zona '%s'." % [safe_index + 1, resolved_zone])
		return
	print("[music-expansion] Ciclo zona '%s': %s" % [
		resolved_zone,
		str(entry.get("display", "traccia"))
	])
	force_track(stream, str(entry.get("display", "traccia")), str(entry.get("source", "")), resolved_zone)

func clear_force() -> void:
	_clear_queued_force()

# ── Interno ────────────────────────────────────────────────────────────────────

func _find_audio_node() -> Node:
	if not is_instance_valid(_parent_node):
		return null
	return _parent_node.get_tree().root.get_node_or_null("Map/Core/Audio")

func _get_current_zone_key() -> String:
	var map := _parent_node.get_tree().root.get_node_or_null("Map")
	if map == null:
		return ""
	var map_type: String = str(map.get("mapType"))
	return ZONE_KEY_MAP.get(map_type, "")

func _get_active_preset_zone_key() -> String:
	match int(_game_data.musicPreset):
		1:
			return ""
		2:
			return _get_current_zone_key()
		3:
			return "shelter"
		4:
			return "area05"
		5:
			return "borderZone"
		6:
			return "vostok"
		_:
			return _get_current_zone_key()

func _build_zone_pool(zone_key: String) -> Array:
	var pool: Array = []
	if _audio_node != null and is_instance_valid(_audio_node):
		var vanilla = _audio_node.get(zone_key)
		if vanilla is Array:
			var vanilla_index := 1
			for stream in vanilla:
				if stream is AudioStream and not _pool_has_stream(pool, stream):
					pool.append({
						"stream": stream,
						"display": _display_for_vanilla_stream(stream, zone_key, vanilla_index),
						"source": "vanilla",
					})
					vanilla_index += 1

	var mod_entries: Array = _library.track_entries_by_zone.get(zone_key, [])
	for raw_entry in mod_entries:
		var entry: Dictionary = raw_entry
		var stream: AudioStream = entry.get("stream", null)
		if stream != null and not _pool_has_stream(pool, stream):
			pool.append({
				"stream": stream,
				"display": str(entry.get("file_name", "track")),
				"source": "mod",
			})
	return pool

func _pool_has_stream(pool: Array, stream: AudioStream) -> bool:
	for entry in pool:
		if entry is Dictionary and entry.get("stream", null) == stream:
			return true
	return false

func _select_pool_entry(zone_key: String, pool: Array) -> Dictionary:
	if selection_mode == SELECTION_CYCLE:
		var index := int(_cycle_indices_by_zone.get(zone_key, 0))
		index = posmod(index, pool.size())
		_cycle_indices_by_zone[zone_key] = index + 1
		return pool[index]
	return pool[randi() % pool.size()]

func _play_now(stream: AudioStream, display_name: String = "", source: String = "", zone_key: String = "") -> void:
	_cancel_tween()
	_music_player.stream = stream
	_music_player.volume_db = volume_db_offset if _library.is_our_stream(stream) else 0.0
	_music_player.play()
	_current_track_info = {
		"display": _fallback_display_name(stream, display_name),
		"source": _fallback_source(stream, source),
		"zone": zone_key,
		"stream_id": stream.get_instance_id(),
	}

func _cancel_tween() -> void:
	if _force_tween != null and is_instance_valid(_force_tween):
		_force_tween.kill()
	_force_tween = null

func _clear_queued_force() -> void:
	_force_stream = null
	_force_display = ""
	_force_source = "mod"
	_force_zone = "forced"

func _fallback_display_name(stream: AudioStream, display_name: String) -> String:
	if not display_name.is_empty():
		return display_name
	var library_name: String = _library.get_display_name_for_stream(stream)
	if not library_name.is_empty():
		return library_name
	var path_name := _display_from_resource_path(stream)
	if not path_name.is_empty():
		return path_name
	return "Unknown track"

func _fallback_source(stream: AudioStream, source: String) -> String:
	if not source.is_empty():
		return source
	return "mod" if _library.is_our_stream(stream) else "vanilla"

func _build_track_info_for_stream(stream: AudioStream) -> Dictionary:
	var zone_key := _get_active_preset_zone_key()
	var pool: Array = []
	if not zone_key.is_empty():
		pool = _build_zone_pool(zone_key)
		for raw_entry in pool:
			var entry: Dictionary = raw_entry
			if entry.get("stream", null) == stream:
				return {
					"display": str(entry.get("display", "Unknown track")),
					"source": str(entry.get("source", _fallback_source(stream, ""))),
					"zone": zone_key,
					"stream_id": stream.get_instance_id(),
				}

	var display := _fallback_display_name(stream, "")
	var source := _fallback_source(stream, "")
	return {
		"display": display,
		"source": source,
		"zone": zone_key,
		"stream_id": stream.get_instance_id(),
	}

func _display_for_vanilla_stream(stream: AudioStream, zone_key: String, index_one_based: int) -> String:
	var path_name := _display_from_resource_path(stream)
	if not path_name.is_empty():
		return path_name
	return "%s vanilla %d" % [_library.get_zone_label(zone_key), index_one_based]

func _display_from_resource_path(stream: AudioStream) -> String:
	if stream == null:
		return ""
	var path := stream.resource_path
	if path.is_empty():
		return ""
	return path.get_file()

func _fallback_pool_count(zone_key: String) -> int:
	if zone_key == "current":
		var current_zone := _get_current_zone_key()
		if current_zone.is_empty():
			return _max_fallback_pool_count()
		zone_key = current_zone
	var vanilla_count := int(VANILLA_TRACK_COUNTS.get(zone_key, 0))
	var mod_count := 0
	if _library != null:
		mod_count = _library.get_track_count_for_zone(zone_key)
	return vanilla_count + mod_count

func _max_fallback_pool_count() -> int:
	var max_count := 0
	for zone_key in VANILLA_TRACK_COUNTS.keys():
		max_count = max(max_count, _fallback_pool_count(str(zone_key)))
	return max_count
