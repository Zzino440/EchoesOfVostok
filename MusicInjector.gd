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
var _force_tween: Tween           = null
var _cycle_indices_by_zone: Dictionary = {}

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
		_play_now(_force_stream)
		print("[music-expansion] Force: traccia avviata.")
		_force_stream = null
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
	_play_now(stream)
	print("[music-expansion] Zona '%s': avviata %s." % [
		zone_key,
		str(chosen.get("display", "traccia"))
	])

# ── API pubblica ───────────────────────────────────────────────────────────────

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
func force_track(stream: AudioStream) -> void:
	print("[music-expansion] force_track richiesto.")
	_force_stream = stream
	if _music_player == null or not is_instance_valid(_music_player):
		print("[music-expansion] force_track: music player non disponibile (non sei in gameplay?).")
		return
	_cancel_tween()
	_music_player.stop()
	_play_now(stream)
	_force_stream = null

func force_zone_track(zone_key: String, index_zero_based: int) -> void:
	if zone_key == "current":
		zone_key = _get_current_zone_key()
	if zone_key.is_empty():
		push_warning("[music-expansion] Nessuna area valida per il ciclo tracce.")
		return
	var pool: Array = _build_zone_pool(zone_key)
	if pool.is_empty():
		push_warning("[music-expansion] Nessuna traccia disponibile per zona '%s'." % zone_key)
		return
	var safe_index := posmod(index_zero_based, pool.size())
	var entry: Dictionary = pool[safe_index]
	var stream: AudioStream = entry.get("stream", null)
	if stream == null:
		push_warning("[music-expansion] Traccia #%d non valida per zona '%s'." % [safe_index + 1, zone_key])
		return
	print("[music-expansion] Ciclo zona '%s': %s" % [
		zone_key,
		str(entry.get("display", "traccia"))
	])
	force_track(stream)

func clear_force() -> void:
	_force_stream = null

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
						"display": "[Vanilla %s] %d" % [_library.get_zone_label(zone_key), vanilla_index],
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
				"display": "[Mod %s] %s" % [
					_library.get_zone_label(zone_key),
					str(entry.get("file_name", "track"))
				],
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

func _play_now(stream: AudioStream) -> void:
	_cancel_tween()
	_music_player.stream = stream
	_music_player.volume_db = volume_db_offset if _library.is_our_stream(stream) else 0.0
	_music_player.play()

func _cancel_tween() -> void:
	if _force_tween != null and is_instance_valid(_force_tween):
		_force_tween.kill()
	_force_tween = null
