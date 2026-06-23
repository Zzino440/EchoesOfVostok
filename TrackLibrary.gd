extends RefCounted

# Scansiona le sottocartelle Tracks/ e carica le tracce audio a runtime.
#
# In-game: solo .mp3 (Array[AudioStreamMP3] vanilla e' tipizzato).
# Menu: .mp3 e .ogg (stream non tipizzato).
#
# Se tutte le cartelle zona sono vuote attiva il seed di test:
# inietta la traccia vanilla Daybreak in tutte le zone e nel menu,
# cosi' l'iniezione/force/menu sono verificabili senza file esterni.
# Il seed sparisce non appena l'utente droppa almeno un .mp3 reale.

const SEED_TRACK_PATH   := "res://Audio/Music/Road_to_Vostok_OST_Daybreak.mp3"
const MENU_DEFAULT_PATH := "res://Audio/Music/Road_to_Vostok_OST_Far.mp3"
const BASE_DIR          := "res://MusicExpansion/Tracks"

# Mappatura nome-cartella -> chiave proprieta' in Audio.gd
const ZONE_DIRS := {
	"Area05":     "area05",
	"BorderZone": "borderZone",
	"Vostok":     "vostok",
	"Shelter":    "shelter",
}

const ZONE_LABELS := {
	"area05":     "Area 05",
	"borderZone": "Border Zone",
	"vostok":     "Vostok",
	"shelter":    "Shelter",
}

# Dizionario zona_key -> Array (elementi AudioStreamMP3)
var tracks_by_zone: Dictionary = {}
# Dizionario zona_key -> Array[Dictionary] con metadati delle tracce mod.
var track_entries_by_zone: Dictionary = {}
# Tracce per il menu (AudioStreamMP3 o AudioStreamOggVorbis)
var tracks_menu: Array = []
# display_name -> AudioStream (per il dropdown MCM)
var all_tracks: Dictionary = {}
# Ordine stabile dei display name usati dai dropdown MCM.
var display_names: Array = []
# Lista flat di tutti gli stream "nostri" (per identificarli nel MusicInjector)
var our_streams: Array = []

func scan() -> void:
	tracks_by_zone.clear()
	track_entries_by_zone.clear()
	tracks_menu.clear()
	all_tracks.clear()
	display_names.clear()
	our_streams.clear()

	# --- Zone in-game (solo .mp3) ---
	for dir_name in ZONE_DIRS.keys():
		var zone_key: String = ZONE_DIRS[dir_name]
		var entries: Array = _scan_mp3_entries(BASE_DIR + "/" + dir_name, zone_key)
		var mp3s: Array = []
		for entry in entries:
			mp3s.append(entry["stream"])
		tracks_by_zone[zone_key] = mp3s
		track_entries_by_zone[zone_key] = entries
		for s in mp3s:
			our_streams.append(s)

	# Controlla se tutte le zone sono vuote
	var all_empty := true
	for zone_key in tracks_by_zone.keys():
		if (tracks_by_zone[zone_key] as Array).size() > 0:
			all_empty = false
			break

	if all_empty:
		# Seed di test: Daybreak in tutte le zone
		var seed: AudioStreamMP3 = _load_mp3_resource(SEED_TRACK_PATH)
		if seed != null:
			for zone_key in tracks_by_zone.keys():
				(tracks_by_zone[zone_key] as Array).append(seed)
				var display := "[%s] Test Daybreak" % ZONE_LABELS.get(zone_key, zone_key)
				var entry := _make_entry(zone_key, "Road_to_Vostok_OST_Daybreak.mp3", display, seed)
				(track_entries_by_zone[zone_key] as Array).append(entry)
			our_streams.append(seed)
			_register_track("[Test] Daybreak", seed)
			print("[music-expansion] Seed di test attivo: Daybreak aggiunta a tutte le zone.")
	else:
		# Popola all_tracks con le tracce reali trovate
		for zone_key in track_entries_by_zone.keys():
			for entry in track_entries_by_zone[zone_key]:
				_register_track(str(entry["display"]), entry["stream"])

	# --- Menu (.mp3 e .ogg) ---
	tracks_menu = _scan_audio(BASE_DIR + "/Menu")
	for i in range(tracks_menu.size()):
		var s: AudioStream = tracks_menu[i]
		our_streams.append(s)
		var display := "[Menu] %d" % (i + 1)
		_register_track(display, s)

	# Seed menu se vuoto
	if tracks_menu.is_empty():
		var seed: AudioStreamMP3 = _load_mp3_resource(SEED_TRACK_PATH)
		if seed != null:
			tracks_menu.append(seed)
			if not our_streams.has(seed):
				our_streams.append(seed)

	var counts := {}
	for k in tracks_by_zone.keys():
		counts[k] = (tracks_by_zone[k] as Array).size()
	print("[music-expansion] Tracce caricate: in-game=%s, menu=%d" % [
		str(counts),
		tracks_menu.size()
	])

func is_our_stream(stream: AudioStream) -> bool:
	return our_streams.has(stream)

func get_display_names() -> Array:
	return display_names.duplicate()

func get_stream_by_name(display_name: String) -> AudioStream:
	return all_tracks.get(display_name, null)

func get_zone_label(zone_key: String) -> String:
	return ZONE_LABELS.get(zone_key, zone_key)

func get_track_count_for_zone(zone_key: String) -> int:
	return (track_entries_by_zone.get(zone_key, []) as Array).size()

func get_max_zone_track_count() -> int:
	var max_count := 0
	for zone_key in track_entries_by_zone.keys():
		max_count = max(max_count, get_track_count_for_zone(str(zone_key)))
	return max_count

func get_stream_for_zone_index(zone_key: String, index_zero_based: int) -> AudioStream:
	var entries: Array = track_entries_by_zone.get(zone_key, [])
	if index_zero_based < 0 or index_zero_based >= entries.size():
		return null
	return entries[index_zero_based].get("stream", null)

func describe_zone_index(zone_key: String, index_zero_based: int) -> String:
	var entries: Array = track_entries_by_zone.get(zone_key, [])
	if index_zero_based < 0 or index_zero_based >= entries.size():
		return ""
	return str(entries[index_zero_based].get("display", ""))

# ── Caricamento ────────────────────────────────────────────────────────────────

func _register_track(display_name: String, stream: AudioStream) -> void:
	all_tracks[display_name] = stream
	display_names.append(display_name)

func _make_entry(zone_key: String, file_name: String, display: String, stream: AudioStream) -> Dictionary:
	return {
		"zone_key": zone_key,
		"zone_label": get_zone_label(zone_key),
		"file_name": file_name,
		"display": display,
		"stream": stream,
	}

func _scan_mp3_entries(dir_path: String, zone_key: String) -> Array:
	var result: Array = []
	var file_names: Array = _list_audio_files(dir_path, ["mp3"])
	for raw_fname in file_names:
		var fname: String = str(raw_fname)
		var stream := _load_mp3_from_path(dir_path + "/" + fname)
		if stream != null:
			var display := "[%s] %s" % [get_zone_label(zone_key), fname]
			result.append(_make_entry(zone_key, fname, display, stream))
	return result

# Scansiona dir_path cercando file .mp3 e ritorna un Array di AudioStreamMP3.
func _scan_mp3(dir_path: String) -> Array:
	var result: Array = []
	for entry in _scan_mp3_entries(dir_path, ""):
		result.append(entry["stream"])
	return result

func _list_audio_files(dir_path: String, extensions: Array) -> Array:
	var result: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return result
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir():
			var lower := fname.to_lower()
			for ext in extensions:
				if lower.ends_with("." + str(ext).to_lower()):
					result.append(fname)
					break
		fname = dir.get_next()
	dir.list_dir_end()
	result.sort()
	return result

# Scansiona dir_path cercando .mp3 e .ogg (per il menu).
func _scan_audio(dir_path: String) -> Array:
	var result: Array = []
	var file_names: Array = _list_audio_files(dir_path, ["mp3", "ogg"])
	for raw_fname in file_names:
		var fname: String = str(raw_fname)
		var lower: String = fname.to_lower()
		if lower.ends_with(".mp3"):
			var s := _load_mp3_from_path(dir_path + "/" + fname)
			if s != null:
				result.append(s)
		elif lower.ends_with(".ogg"):
			var s := AudioStreamOggVorbis.load_from_file(dir_path + "/" + fname)
			if s != null:
				result.append(s)
	return result

# Carica un .mp3 da path filesystem tramite FileAccess (funziona senza import).
func _load_mp3_from_path(path: String) -> AudioStreamMP3:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("[music-expansion] Impossibile aprire: %s" % path)
		return null
	var stream := AudioStreamMP3.new()
	stream.data = file.get_buffer(file.get_length())
	file.close()
	return stream

# Carica un .mp3 gia' importato come risorsa Godot (res://).
func _load_mp3_resource(res_path: String) -> AudioStreamMP3:
	if ResourceLoader.exists(res_path):
		return load(res_path) as AudioStreamMP3
	push_warning("[music-expansion] Risorsa non trovata: %s" % res_path)
	return null
