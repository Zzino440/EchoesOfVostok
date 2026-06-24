extends RefCounted

# Randomises the main menu track by choosing from:
#  - Tracks in Tracks/Menu/ (mp3/ogg)
#  - Vanilla track "Far" (always included in the pool so it is never excluded)
#
# The logic fires once per entry into the menu scene
# and respects the user's "Menu Music" off preference (stream_paused).

const MENU_DEFAULT_PATH := "res://Audio/Music/Road_to_Vostok_OST_Far.mp3"

var _library = null
var _parent_node: Node = null
var _handled_scene: Node = null  # menu scene already randomised in this session

func setup(library, parent_node: Node) -> void:
	_library = library
	_parent_node = parent_node

func tick() -> void:
	var scene: Node = _parent_node.get_tree().current_scene
	if scene == null:
		return

	# Reset if the scene has changed
	if scene != _handled_scene and _handled_scene != null:
		print("[echoes-of-vostok] Menu: scene changed (%s), reset." % scene.name)
		_handled_scene = null

	# Already handled for this scene
	if _handled_scene != null:
		return

	# Look for the Audio node as a direct child of the root (must be AudioStreamPlayer)
	var audio := scene.get_node_or_null("Audio") as AudioStreamPlayer
	if audio == null:
		# No AudioStreamPlayer named "Audio" in this scene (we are in gameplay)
		return

	# Make sure we are not in gameplay (gameplay has /root/Map/Core)
	if _parent_node.get_tree().root.get_node_or_null("Map/Core") != null:
		return

	print("[echoes-of-vostok] Menu: Audio node found on scene '%s', stream_paused=%s" % [
		scene.name, str(audio.stream_paused)
	])

	# --- We are in the menu: randomise the stream ---
	var pool: Array = []

	# First choice: tracks from Tracks/Menu/ (if any)
	for s in _library.tracks_menu:
		pool.append(s)

	# If there are no mod tracks, also add Far as a fallback
	# (so with the Daybreak test seed it is always chosen)
	if pool.is_empty() and ResourceLoader.exists(MENU_DEFAULT_PATH):
		pool.append(load(MENU_DEFAULT_PATH))

	print("[echoes-of-vostok] Menu: pool = %d mod tracks" % pool.size())

	if pool.is_empty():
		return

	var idx := randi() % pool.size()
	var chosen: AudioStream = pool[idx]
	audio.stop()
	audio.stream = chosen

	# Respect the menuMusic off preference (stream_paused = true means OFF)
	if not audio.stream_paused:
		audio.play()

	_handled_scene = scene
	print("[echoes-of-vostok] Menu: track #%d selected and started." % idx)
