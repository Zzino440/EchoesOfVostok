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

const MENU_DEFAULT_PATH := "res://Audio/Music/Road_to_Vostok_OST_Far.mp3"

var _library = null
var _parent_node: Node = null

# Stato corrente
var _menu_audio: AudioStreamPlayer = null  # nodo Audio del menu
var _vanilla_stream: AudioStream   = null  # stream originale catturato all'ingresso (Far)
var _last_stream: AudioStream      = null  # stream originale dell'ultima traccia avviata
var _started_once: bool            = false # true dopo la prima _play_random() in questa scena
var _loopless_cache: Dictionary    = {}    # instance_id(originale) -> copia con loop=false

func setup(library, parent_node: Node) -> void:
	_library     = library
	_parent_node = parent_node

func tick() -> void:
	var scene: Node = _parent_node.get_tree().current_scene
	if scene == null:
		return

	# Siamo nel gameplay? Usciamo e resettiamo
	if _parent_node.get_tree().root.get_node_or_null("Map/Core") != null:
		if _menu_audio != null:
			_reset_state()
		return

	# Il menu ha un AudioStreamPlayer diretto figlio chiamato "Audio"
	var audio := scene.get_node_or_null("Audio") as AudioStreamPlayer
	if audio == null:
		if _menu_audio != null:
			_reset_state()
		return

	# Nuova scena menu: catturiamo lo stream vanilla e resettiamo il contesto
	if audio != _menu_audio:
		_menu_audio     = audio
		_vanilla_stream = audio.stream
		_started_once   = false
		_last_stream    = null
		print("[echoes-of-vostok] Menu: nodo Audio rilevato su '%s'." % scene.name)

	# Rispettiamo il toggle "Menu Music off" (stream_paused = true -> nessun avvio)
	if audio.stream_paused:
		return

	# Prima traccia o traccia finita -> ne avviamo un'altra
	if not _started_once or not audio.is_playing():
		_play_random(audio)

# ── Internals ─────────────────────────────────────────────────────────────────

func _reset_state() -> void:
	_menu_audio     = null
	_vanilla_stream = null
	_last_stream    = null
	_started_once   = false

func _build_pool() -> Array:
	var pool: Array = []

	# 1. Tracce dalla cartella Tracks/Menu/
	for s in _library.tracks_menu:
		pool.append(s)

	# 2. Vanilla "Far" -- sempre nel pool
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

	# Selezione random con no-repeat consecutivo
	var idx: int = randi() % pool.size()
	if pool.size() > 1 and pool[idx] == _last_stream:
		idx = (idx + 1) % pool.size()

	var chosen: AudioStream  = pool[idx]
	var prepared: AudioStream = _prepare_loopless(chosen)

	audio.stop()
	audio.stream = prepared
	audio.play()

	_last_stream  = chosen  # tracciamo l'originale, non la copia
	_started_once = true

	print("[echoes-of-vostok] Menu: traccia %d/%d avviata." % [idx + 1, pool.size()])

func _prepare_loopless(stream: AudioStream) -> AudioStream:
	# Ritorna lo stream invariato se non ha loop attivo
	if stream == null:
		return stream

	var has_loop := false
	if stream is AudioStreamMP3:
		has_loop = (stream as AudioStreamMP3).loop
	elif stream is AudioStreamOggVorbis:
		has_loop = (stream as AudioStreamOggVorbis).loop

	if not has_loop:
		return stream

	# Usiamo la cache per non riallocare a ogni rotazione
	var cache_key: int = stream.get_instance_id()
	if _loopless_cache.has(cache_key):
		return _loopless_cache[cache_key]

	# Copia superficiale della risorsa: PackedByteArray e OggPacketSequence
	# sono copiati per valore da duplicate(), non per riferimento.
	var copy: AudioStream = stream.duplicate() as AudioStream
	if copy is AudioStreamMP3:
		(copy as AudioStreamMP3).loop = false
	elif copy is AudioStreamOggVorbis:
		(copy as AudioStreamOggVorbis).loop = false

	_loopless_cache[cache_key] = copy
	return copy
