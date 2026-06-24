extends RefCounted

# Scans the Tracks/ subdirectories and loads audio tracks at runtime.
#
# In-game: .mp3 only (vanilla Array[AudioStreamMP3] is typed).
# Menu: .mp3 and .ogg (untyped stream).
#
# If all zone folders are empty the test seed is activated:
# it injects the vanilla Daybreak track into all zones and the menu,
# so injection/force/menu can be verified without external files.
# The seed disappears as soon as the user drops at least one real .mp3.

const SEED_TRACK_PATH   := "res://Audio/Music/Road_to_Vostok_OST_Daybreak.mp3"
const MENU_DEFAULT_PATH := "res://Audio/Music/Road_to_Vostok_OST_Far.mp3"
const BASE_DIR          := "res://EchoesOfVostok/Tracks"

# Folder name -> Audio.gd property key mapping
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

# zone_key -> Array (AudioStreamMP3 elements)
var tracks_by_zone: Dictionary = {}
# zone_key -> Array[Dictionary] with mod track metadata.
var track_entries_by_zone: Dictionary = {}
# Menu tracks (AudioStreamMP3 or AudioStreamOggVorbis)
var tracks_menu: Array = []
# display_name -> AudioStream (for the MCM dropdown)
var all_tracks: Dictionary = {}
# Stream instance ID -> display_name, for overlay/debug.
var display_by_stream_id: Dictionary = {}
# Stable display name order used by MCM dropdowns.
var display_names: Array = []
# Flat list of all "our" streams (to identify them in MusicInjector)
var our_streams: Array = []

func scan() -> void:
	tracks_by_zone.clear()
	track_entries_by_zone.clear()
	tracks_menu.clear()
	all_tracks.clear()
	display_by_stream_id.clear()
	display_names.clear()
	our_streams.clear()

	# --- In-game zones (.mp3 only) ---
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

	# Check whether all zones are empty
	var all_empty := true
	for zone_key in tracks_by_zone.keys():
		if (tracks_by_zone[zone_key] as Array).size() > 0:
			all_empty = false
			break

	if all_empty:
		# Test seed: Daybreak in all zones
		var seed: AudioStreamMP3 = _load_mp3_resource(SEED_TRACK_PATH)
		if seed != null:
			for zone_key in tracks_by_zone.keys():
				(tracks_by_zone[zone_key] as Array).append(seed)
				var display := "[%s] Test Daybreak" % ZONE_LABELS.get(zone_key, zone_key)
				var entry := _make_entry(zone_key, "Road_to_Vostok_OST_Daybreak.mp3", display, seed)
				(track_entries_by_zone[zone_key] as Array).append(entry)
			our_streams.append(seed)
			_register_track("[Test] Daybreak", seed)
			print("[echoes-of-vostok] Test seed active: Daybreak added to all zones.")
	else:
		# Populate all_tracks with the real tracks found
		for zone_key in track_entries_by_zone.keys():
			for entry in track_entries_by_zone[zone_key]:
				_register_track(str(entry["display"]), entry["stream"])

	# --- Menu (.mp3 and .ogg) ---
	tracks_menu = _scan_audio(BASE_DIR + "/Menu")
	for i in range(tracks_menu.size()):
		var s: AudioStream = tracks_menu[i]
		our_streams.append(s)
		var display := "[Menu] %d" % (i + 1)
		_register_track(display, s)

	# Menu seed if empty
	if tracks_menu.is_empty():
		var seed: AudioStreamMP3 = _load_mp3_resource(SEED_TRACK_PATH)
		if seed != null:
			tracks_menu.append(seed)
			if not our_streams.has(seed):
				our_streams.append(seed)

	var counts := {}
	for k in tracks_by_zone.keys():
		counts[k] = (tracks_by_zone[k] as Array).size()
	print("[echoes-of-vostok] Tracks loaded: in-game=%s, menu=%d" % [
		str(counts),
		tracks_menu.size()
	])

func is_our_stream(stream: AudioStream) -> bool:
	return our_streams.has(stream)

func get_display_names() -> Array:
	return display_names.duplicate()

func get_stream_by_name(display_name: String) -> AudioStream:
	return all_tracks.get(display_name, null)

func get_display_name_for_stream(stream: AudioStream) -> String:
	if stream == null:
		return ""
	return str(display_by_stream_id.get(stream.get_instance_id(), ""))

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

# ── Loading ───────────────────────────────────────────────────────────────────

func _register_track(display_name: String, stream: AudioStream) -> void:
	all_tracks[display_name] = stream
	display_by_stream_id[stream.get_instance_id()] = display_name
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

# Scans dir_path for .mp3 and .ogg files (for the menu).
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

# Loads a .mp3 from a filesystem path via FileAccess (works without import).
func _load_mp3_from_path(path: String) -> AudioStreamMP3:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("[echoes-of-vostok] Cannot open: %s" % path)
		return null
	var stream := AudioStreamMP3.new()
	stream.data = file.get_buffer(file.get_length())
	file.close()
	return stream

# Loads a .mp3 already imported as a Godot resource (res://).
func _load_mp3_resource(res_path: String) -> AudioStreamMP3:
	if ResourceLoader.exists(res_path):
		return load(res_path) as AudioStreamMP3
	push_warning("[echoes-of-vostok] Resource not found: %s" % res_path)
	return null
