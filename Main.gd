extends Node

# Bootstrap della mod Music Expansion.
#
# Aggiunge nuove tracce musicali (.mp3/.ogg droppate in Tracks/<Zona>/) al
# sistema di musica dinamico in-game e alla musica del menu iniziale,
# senza modificare alcun file vanilla.
#
# Struttura:
#   TrackLibrary  -- scansiona e carica le tracce a runtime
#   MusicInjector -- inietta le tracce negli array zona di Audio.gd
#   MenuMusic     -- randomizza la traccia del menu
#   DebugOverlay  -- mostra a schermo il brano corrente quando abilitato
#   Config        -- MCM (toggle, force brano, volume)

const MOD_ID := "music-expansion"

const _TrackLibraryScript  := preload("res://MusicExpansion/TrackLibrary.gd")
const _MusicInjectorScript := preload("res://MusicExpansion/MusicInjector.gd")
const _MenuMusicScript     := preload("res://MusicExpansion/MenuMusic.gd")
const _DebugOverlayScript  := preload("res://MusicExpansion/DebugOverlay.gd")
const _ConfigScript        := preload("res://MusicExpansion/Config.gd")

var _lib          = null
var _library      = null
var _injector     = null
var _menu_music   = null
var _debug_overlay = null
var _config       = null

# ── Bootstrap ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	call_deferred("_initialize")

func _initialize() -> void:
	while not Engine.has_meta("RTVModLib"):
		await get_tree().process_frame
	_lib = Engine.get_meta("RTVModLib")
	if not _lib._is_ready:
		await _lib.frameworks_ready

	# 1. Scansiona le tracce una volta all'avvio
	_library = _TrackLibraryScript.new()
	_library.scan()

	# 2. Inizializza i componenti
	_injector = _MusicInjectorScript.new()
	_injector.setup(_library, self)

	_menu_music = _MenuMusicScript.new()
	_menu_music.setup(_library, self)

	_debug_overlay = _DebugOverlayScript.new()
	add_child(_debug_overlay)
	_debug_overlay.setup(_injector)

	# 3. Registra MCM e carica la config (deve avvenire dopo _injector, per force_track)
	_config = _ConfigScript.new()
	_config.setup(_library, _injector, _on_config_updated)

	# 4. Applica lo stato iniziale dalla config
	_injector.set_enabled(_config.enabled)
	_injector.set_paused(_config.paused)
	_injector.set_volume(_config.volume_db)
	_injector.set_selection_mode(_config.selection_mode)
	_debug_overlay.set_enabled(_config.debug_overlay_enabled)
	_debug_overlay.set_position(_config.debug_overlay_position)

	print("[%s] caricata. enabled=%s, tracce totali=%d" % [
		MOD_ID, _config.enabled, _library.all_tracks.size()
	])

func _exit_tree() -> void:
	# Ripristina gli array vanilla quando la mod viene scaricata
	if _injector != null:
		_injector.set_enabled(false)

# ── Loop principale (throttled ogni 10 frame fisici) ──────────────────────────

func _physics_process(_delta: float) -> void:
	if _injector == null or _config == null:
		return

	# Injector: ogni frame (per intercettare il momento esatto in cui la musica si ferma)
	_injector.tick()

	# Menu: throttled, non critico
	if Engine.get_physics_frames() % 20 == 0:
		_config.refresh_current_area_range()
		_menu_music.tick()
		_debug_overlay.tick()

# ── Callback cambio config (MCM) ──────────────────────────────────────────────

func _on_config_updated() -> void:
	if _injector == null or _config == null:
		return
	_injector.set_enabled(_config.enabled)
	_injector.set_paused(_config.paused)
	_injector.set_volume(_config.volume_db)
	_injector.set_selection_mode(_config.selection_mode)
	if _debug_overlay != null:
		_debug_overlay.set_enabled(_config.debug_overlay_enabled)
		_debug_overlay.set_position(_config.debug_overlay_position)
