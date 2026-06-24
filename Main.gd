extends Node

# Bootstrap for the Music Expansion mod.
#
# Adds new music tracks (.mp3/.ogg dropped in Tracks/<Zone>/) to the
# dynamic in-game music system and to the main menu music,
# without modifying any vanilla files.
#
# Structure:
#   TrackLibrary  -- scans and loads tracks at runtime
#   MusicInjector -- injects tracks into Audio.gd zone arrays
#   MenuMusic     -- randomises the menu track
#   DebugOverlay  -- shows the current track on screen when enabled
#   Config        -- MCM (toggle, force track, volume)

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

# ── Bootstrap ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	call_deferred("_initialize")

func _initialize() -> void:
	while not Engine.has_meta("RTVModLib"):
		await get_tree().process_frame
	_lib = Engine.get_meta("RTVModLib")
	if not _lib._is_ready:
		await _lib.frameworks_ready

	# 1. Scan tracks once at startup
	_library = _TrackLibraryScript.new()
	_library.scan()

	# 2. Initialise components
	_injector = _MusicInjectorScript.new()
	_injector.setup(_library, self)

	_menu_music = _MenuMusicScript.new()
	_menu_music.setup(_library, self)

	_debug_overlay = _DebugOverlayScript.new()
	add_child(_debug_overlay)
	_debug_overlay.setup(_injector)

	# 3. Register MCM and load config (must happen after _injector, for force_track)
	_config = _ConfigScript.new()
	_config.setup(_library, _injector, _on_config_updated)

	# 4. Apply initial state from config
	_injector.set_enabled(_config.enabled)
	_injector.set_paused(_config.paused)
	_injector.set_volume(_config.volume_db)
	_injector.set_selection_mode(_config.selection_mode)
	_debug_overlay.set_enabled(_config.debug_overlay_enabled)
	_debug_overlay.set_position(_config.debug_overlay_position)

	print("[%s] loaded. enabled=%s, total tracks=%d" % [
		MOD_ID, _config.enabled, _library.all_tracks.size()
	])

func _exit_tree() -> void:
	# Restore vanilla arrays when the mod is unloaded
	if _injector != null:
		_injector.set_enabled(false)

# ── Main loop (throttled every 10 physics frames) ─────────────────────────────

func _physics_process(_delta: float) -> void:
	if _injector == null or _config == null:
		return

	# Injector: every frame (to catch the exact moment music stops)
	_injector.tick()

	# Menu: throttled, not time-critical
	if Engine.get_physics_frames() % 20 == 0:
		_config.refresh_current_area_range()
		_menu_music.tick()
		_debug_overlay.tick()

# ── Config change callback (MCM) ──────────────────────────────────────────────

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
