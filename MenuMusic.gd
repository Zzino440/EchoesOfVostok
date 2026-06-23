extends RefCounted

# Randomizza la traccia del menu iniziale scegliendo tra:
#  - Tracce in Tracks/Menu/ (mp3/ogg)
#  - Traccia vanilla "Far" (sempre inclusa nel pool per non escluderla mai)
#
# La logica si attiva una sola volta per ogni ingresso nella scena menu
# e rispetta la preferenza "Menu Music" off dell'utente (stream_paused).

const MENU_DEFAULT_PATH := "res://Audio/Music/Road_to_Vostok_OST_Far.mp3"

var _library = null
var _parent_node: Node = null
var _handled_scene: Node = null  # scena menu gia' randomizzata in questa sessione

func setup(library, parent_node: Node) -> void:
	_library = library
	_parent_node = parent_node

func tick() -> void:
	var scene: Node = _parent_node.get_tree().current_scene
	if scene == null:
		return

	# Resetta se la scena e' cambiata
	if scene != _handled_scene and _handled_scene != null:
		print("[music-expansion] Menu: scena cambiata (%s), reset." % scene.name)
		_handled_scene = null

	# Gia' gestita per questa scena
	if _handled_scene != null:
		return

	# Cerca il nodo Audio come figlio diretto del root (serve che sia AudioStreamPlayer)
	var audio := scene.get_node_or_null("Audio") as AudioStreamPlayer
	if audio == null:
		# Niente AudioStreamPlayer di nome "Audio" in questa scena (siamo in gameplay)
		return

	# Assicurati di non essere in gameplay (gameplay ha /root/Map/Core)
	if _parent_node.get_tree().root.get_node_or_null("Map/Core") != null:
		return

	print("[music-expansion] Menu: nodo Audio trovato su scena '%s', stream_paused=%s" % [
		scene.name, str(audio.stream_paused)
	])

	# --- Siamo nel menu: randomizza lo stream ---
	var pool: Array = []

	# Prima scelta: tracce Tracks/Menu/ (se presenti)
	for s in _library.tracks_menu:
		pool.append(s)

	# Se non ci sono tracce mod, aggiungi anche Far come fallback
	# (cosi' con il seed di test Daybreak viene scelta sempre)
	if pool.is_empty() and ResourceLoader.exists(MENU_DEFAULT_PATH):
		pool.append(load(MENU_DEFAULT_PATH))

	print("[music-expansion] Menu: pool = %d tracce mod" % pool.size())

	if pool.is_empty():
		return

	var idx := randi() % pool.size()
	var chosen: AudioStream = pool[idx]
	audio.stop()
	audio.stream = chosen

	# Rispetta la preferenza menuMusic off (stream_paused = true significa OFF)
	if not audio.stream_paused:
		audio.play()

	_handled_scene = scene
	print("[music-expansion] Menu: traccia #%d scelta e avviata." % idx)
