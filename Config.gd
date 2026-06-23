extends RefCounted

# Gestisce MCM e il file di configurazione ini.
# Degrada pulitamente se MCM non e' installato (usa i valori di default).
#
# Opzioni MCM:
#  - Bool  "enabled"        -- toggle generale mod
#  - Dropdown "selection_mode" -- random o ciclo sul pool vanilla+mod
#  - Dropdown "force_track" -- forza un brano specifico (debug)
#  - Dropdown "test_area"   -- area da usare per il ciclo manuale
#  - Int "cycle_area_track" -- indice 1-based del pool vanilla+mod dell'area
#  - Bool "debug_overlay_enabled" -- mostra traccia corrente su schermo
#  - Dropdown "debug_overlay_position" -- posizione overlay debug
#  - Float "track_volume_db" -- offset volume tracce mod

const MOD_ID         := "music-expansion"
const MCM_MOD_ID     := "MusicExpansion"
const MCM_FILE_PATH  := "user://MCM/MusicExpansion"
const MCM_HELPERS_PATH := "res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres"

const DEFAULT_ENABLED   := true
const DEFAULT_PAUSED    := false
const DEFAULT_VOLUME_DB := 0.0
const FORCE_OFF_LABEL   := "(Off)"
const SELECTION_RANDOM := "random"
const SELECTION_CYCLE := "cycle"
const SELECTION_OPTIONS := {
	SELECTION_RANDOM: "Random",
	SELECTION_CYCLE: "Cycle",
}
const OVERLAY_TOP_LEFT := "top_left"
const OVERLAY_TOP_RIGHT := "top_right"
const OVERLAY_POSITION_OPTIONS := {
	OVERLAY_TOP_LEFT: "Alto sinistra",
	OVERLAY_TOP_RIGHT: "Alto destra",
}
const AREA_CURRENT      := "current"
const AREA_LABEL_CURRENT := "Current Area"
const AREA_OPTIONS := [
	AREA_LABEL_CURRENT,
	"Area 05",
	"Border Zone",
	"Vostok",
	"Shelter",
]
const AREA_KEYS_BY_LABEL := {
	AREA_LABEL_CURRENT: AREA_CURRENT,
	"Area 05": "area05",
	"Border Zone": "borderZone",
	"Vostok": "vostok",
	"Shelter": "shelter",
}

var enabled: bool    = DEFAULT_ENABLED
var paused: bool     = DEFAULT_PAUSED
var volume_db: float = DEFAULT_VOLUME_DB
var selection_mode: String = SELECTION_RANDOM
var test_area_key: String = AREA_CURRENT
var cycle_area_key: String = AREA_CURRENT
var cycle_track_number: int = 1
var debug_overlay_enabled: bool = false
var debug_overlay_position: String = OVERLAY_TOP_RIGHT

var _mcm_helpers = null
var _on_update: Callable
var _injector = null  # MusicInjector (per force_track live via on_value_changed)
var _library  = null  # TrackLibrary (per le options del dropdown)
var _last_cycle_signature := ""
var _last_cycle_menu = null
var _last_resolved_cycle_zone := ""
var _syncing_cycle_control: bool = false

## Inizializza: carica/crea config ini e registra MCM se disponibile.
## on_update: Callable senza argomenti, chiamata dopo ogni cambio di config.
func setup(library, injector, on_update: Callable) -> void:
	_library  = library
	_injector = injector
	_on_update = on_update

	if ResourceLoader.exists(MCM_HELPERS_PATH):
		_mcm_helpers = load(MCM_HELPERS_PATH)

	var config := _build_default_config()
	var ini_path := MCM_FILE_PATH + "/config.ini"

	if not FileAccess.file_exists(ini_path):
		DirAccess.make_dir_recursive_absolute(MCM_FILE_PATH)
		config.save(ini_path)
	else:
		if _mcm_helpers != null:
			_mcm_helpers.CheckConfigurationHasUpdated(MCM_MOD_ID, config, ini_path)
		config.load(ini_path)
		if _refresh_dynamic_config(config):
			config.save(ini_path)

	_apply_config(config)
	_last_cycle_signature = _cycle_signature()

	if _mcm_helpers == null:
		print("[%s] MCM non trovato, uso valori di default." % MOD_ID)
		return

	_mcm_helpers.RegisterConfiguration(
		MCM_MOD_ID,
		"Music Expansion",
		MCM_FILE_PATH,
		"Aggiunge nuove tracce musicali alle zone di gioco e al menu. Inserisci file .mp3 in MusicExpansion/Tracks/<Zona>/.",
		{"config.ini": _on_mcm_save},
		self
	)

# Callback MCM: viene chiamata al salvataggio della config dall'UI MCM.
func _on_mcm_save(config: ConfigFile) -> void:
	var config_changed := _refresh_dynamic_config(config)
	if config_changed:
		config.save(MCM_FILE_PATH + "/config.ini")
	_apply_config(config)
	if _on_update.is_valid():
		_on_update.call()
	print("[%s] config aggiornata: enabled=%s, volume_db=%.1f dB" % [MOD_ID, enabled, volume_db])

# Callback live Dropdown: chiamata mentre l'utente seleziona nel pannello MCM.
# Firma richiesta da MCM: func(value_id, new_value, menu).
func _on_force_track_changed(value_id: String, new_value, _menu) -> void:
	print("[music-expansion] MCM dropdown cambiato: '%s'" % str(new_value))
	if _injector == null:
		return
	if _is_force_off(new_value):
		_injector.clear_force()
	else:
		var stream: AudioStream = _resolve_track_stream(new_value)
		print("[music-expansion] Stream trovato in library: %s" % ("si" if stream != null else "NO"))
		if stream != null:
			_injector.force_track(stream)

func _on_selection_mode_changed(_value_id: String, new_value, _menu) -> void:
	selection_mode = _resolve_selection_mode(new_value)
	if _injector != null:
		_injector.set_selection_mode(selection_mode)

func _on_test_area_changed(_value_id: String, new_value, menu) -> void:
	test_area_key = _resolve_area_key(new_value)
	_update_cycle_area_from_selection()
	_sync_cycle_range_in_menu(menu)

func _on_cycle_area_track_changed(_value_id: String, new_value, _menu) -> void:
	cycle_track_number = _clamp_cycle_track_number(int(new_value), cycle_area_key)
	var signature: String = _cycle_signature()
	if _syncing_cycle_control or signature == _last_cycle_signature:
		_last_cycle_signature = signature
		return
	_apply_cycle_now()

func _on_debug_overlay_enabled_changed(_value_id: String, new_value, _menu) -> void:
	debug_overlay_enabled = bool(new_value)
	if _on_update.is_valid():
		_on_update.call()

func _on_debug_overlay_position_changed(_value_id: String, new_value, _menu) -> void:
	debug_overlay_position = _resolve_debug_overlay_position(new_value)
	if _on_update.is_valid():
		_on_update.call()

func refresh_current_area_range(menu = null) -> void:
	if _injector == null or test_area_key != AREA_CURRENT:
		return
	var previous_signature: String = _cycle_signature()
	var has_current_track: bool = _sync_cycle_from_current_track()
	var changed: bool = _cycle_signature() != previous_signature
	if not has_current_track:
		var resolved_zone: String = _resolved_cycle_zone_for(AREA_CURRENT)
		if resolved_zone.is_empty():
			return
		if resolved_zone != cycle_area_key:
			cycle_area_key = resolved_zone
			_last_resolved_cycle_zone = cycle_area_key
			cycle_track_number = _clamp_cycle_track_number(cycle_track_number, cycle_area_key)
			changed = true
	if changed:
		print("[music-expansion] Current Area aggiornata: zona=%s pool=%d track=%d" % [
			cycle_area_key,
			_cycle_range_for_area(cycle_area_key),
			cycle_track_number,
		])
		_save_cycle_range_to_disk()
		_sync_cycle_range_in_menu(_cycle_menu_or_stored(menu))

func _apply_config(config: ConfigFile) -> void:
	enabled   = bool(_cfg(config, "Bool",  "enabled",         DEFAULT_ENABLED))
	paused    = bool(_cfg(config, "Bool",  "paused",          DEFAULT_PAUSED))
	volume_db = float(_cfg(config, "Float", "track_volume_db", DEFAULT_VOLUME_DB))
	selection_mode = _resolve_selection_mode(_cfg(config, "Dropdown", "selection_mode", SELECTION_RANDOM))
	test_area_key = _resolve_area_key(_cfg(config, "Dropdown", "test_area", AREA_LABEL_CURRENT))
	_update_cycle_area_from_selection()
	cycle_track_number = _clamp_cycle_track_number(int(_cfg(config, "Int", "cycle_area_track", 1)), cycle_area_key)
	debug_overlay_enabled = bool(_cfg(config, "Bool", "debug_overlay_enabled", false))
	debug_overlay_position = _resolve_debug_overlay_position(_cfg(config, "Dropdown", "debug_overlay_position", OVERLAY_TOP_RIGHT))

	# Applica forza brano se salvata
	if _injector != null:
		var force_val = _cfg(config, "Dropdown", "force_track", FORCE_OFF_LABEL)
		print("[music-expansion] _apply_config: enabled=%s paused=%s force='%s'" % [enabled, paused, force_val])
		if _is_force_off(force_val):
			_injector.clear_force()
		else:
			var stream: AudioStream = _resolve_track_stream(force_val)
			if stream != null:
				_injector.force_track(stream)
			else:
				push_warning("[music-expansion] Traccia '%s' non trovata in library." % force_val)

func _build_default_config() -> ConfigFile:
	var c := ConfigFile.new()

	# Raccoglie i nomi delle tracce per il dropdown
	var options := _force_track_options()

	c.set_value("Bool", "enabled", {
		"name":    "Abilita mod",
		"tooltip": "Attiva o disattiva la gestione musica da questa mod.",
		"default": DEFAULT_ENABLED,
		"value":   DEFAULT_ENABLED,
		"menu_pos": 1,
	})
	c.set_value("Bool", "paused", {
		"name":    "Pausa musica",
		"tooltip": "Silenzia la musica in-game (utile per debug). Premi Salva per applicare.",
		"default": DEFAULT_PAUSED,
		"value":   DEFAULT_PAUSED,
		"menu_pos": 2,
	})
	c.set_value("Dropdown", "selection_mode", {
		"name":    "Modalita selezione",
		"tooltip": "Random sceglie casualmente dal pool vanilla+mod. Cycle avanza in ordine nel pool della zona.",
		"default": SELECTION_RANDOM,
		"value":   SELECTION_RANDOM,
		"options": SELECTION_OPTIONS,
		"on_value_changed": "_on_selection_mode_changed",
		"menu_pos": 3,
	})
	c.set_value("Dropdown", "force_track", {
		"name":    "Forza brano (debug)",
		"tooltip": "Seleziona una traccia e premi Salva per farla partire subito. '(Off)' torna alla modalita' dinamica.",
		"default": FORCE_OFF_LABEL,
		"value":   FORCE_OFF_LABEL,
		"options": options,
		"on_value_changed": "_on_force_track_changed",
		"menu_pos": 4,
	})
	c.set_value("Dropdown", "test_area", {
		"name":    "Area da testare",
		"tooltip": "Scegli quale area usare per il ciclo manuale. Current Area usa la mappa in cui ti trovi.",
		"default": AREA_LABEL_CURRENT,
		"value":   AREA_LABEL_CURRENT,
		"options": AREA_OPTIONS,
		"on_value_changed": "_on_test_area_changed",
		"menu_pos": 5,
	})
	c.set_value("Int", "cycle_area_track", {
		"name":     "Ciclo tracce area",
		"tooltip":  "Numero della traccia nel pool vanilla+mod della zona effettiva. Con Current Area il range reale segue la mappa corrente; l'overlay mostra Pool: indice/totale.",
		"default":  1,
		"value":    1,
		"minRange": 1,
		"maxRange": _max_cycle_range(),
		"step":     1,
		"on_value_changed": "_on_cycle_area_track_changed",
		"menu_pos": 6,
	})
	c.set_value("Bool", "debug_overlay_enabled", {
		"name":    "Overlay debug musica",
		"tooltip": "Mostra a schermo il brano corrente e se arriva dal gioco base o dalla mod.",
		"default": false,
		"value":   false,
		"on_value_changed": "_on_debug_overlay_enabled_changed",
		"menu_pos": 7,
	})
	c.set_value("Dropdown", "debug_overlay_position", {
		"name":    "Posizione overlay debug",
		"tooltip": "Scegli dove mostrare il testo di debug della musica.",
		"default": OVERLAY_TOP_RIGHT,
		"value":   OVERLAY_TOP_RIGHT,
		"options": OVERLAY_POSITION_OPTIONS,
		"on_value_changed": "_on_debug_overlay_position_changed",
		"menu_pos": 8,
	})
	c.set_value("Float", "track_volume_db", {
		"name":     "Volume tracce mod (dB)",
		"tooltip":  "Offset volume delle tracce aggiunte. 0 = stesso livello delle tracce vanilla.",
		"default":  DEFAULT_VOLUME_DB,
		"value":    DEFAULT_VOLUME_DB,
		"minRange": -24.0,
		"maxRange": 6.0,
		"step":     1.0,
		"menu_pos": 9,
	})

	return c

func _cfg(config: ConfigFile, section: String, key: String, fallback):
	var entry = config.get_value(section, key, null)
	if entry == null or not entry is Dictionary:
		return fallback
	return entry.get("value", fallback)

func _force_track_options() -> Array:
	var options: Array = [FORCE_OFF_LABEL]
	if _library != null:
		options.append_array(_library.get_display_names())
	return options

func _max_cycle_range() -> int:
	return _cycle_range_for_area(cycle_area_key)

func _cycle_range_for_area(area_key: String) -> int:
	var count := 0
	if _injector != null:
		count = _injector.get_zone_pool_count(area_key)
	if count <= 0 and _library != null:
		if area_key == AREA_CURRENT:
			count = _library.get_max_zone_track_count()
		else:
			count = _library.get_track_count_for_zone(area_key)
	return max(1, count)

func _clamp_cycle_track_number(value: int, area_key: String) -> int:
	var max_range := _cycle_range_for_area(area_key)
	return min(max(1, value), max_range)

func _resolved_cycle_zone_for(area_key: String) -> String:
	if _injector == null:
		return ""
	return _injector.get_resolved_zone_key(area_key)

func _update_cycle_area_from_selection() -> void:
	var resolved_zone: String = _resolved_cycle_zone_for(test_area_key)
	if resolved_zone.is_empty():
		cycle_area_key = test_area_key
	else:
		cycle_area_key = resolved_zone
	_last_resolved_cycle_zone = cycle_area_key

func _is_force_off(value) -> bool:
	return _resolve_dropdown_label(value, _force_track_options()) == FORCE_OFF_LABEL

func _resolve_track_stream(value) -> AudioStream:
	var label := _resolve_dropdown_label(value, _force_track_options())
	if label == FORCE_OFF_LABEL:
		return null
	return _library.get_stream_by_name(label)

func _resolve_area_key(value) -> String:
	var label := _resolve_dropdown_label(value, AREA_OPTIONS)
	return AREA_KEYS_BY_LABEL.get(label, AREA_CURRENT)

func _resolve_selection_mode(value) -> String:
	var key := _resolve_dropdown_key(value, SELECTION_OPTIONS)
	if key == SELECTION_CYCLE:
		return SELECTION_CYCLE
	return SELECTION_RANDOM

func _resolve_debug_overlay_position(value) -> String:
	var key := _resolve_dropdown_key(value, OVERLAY_POSITION_OPTIONS)
	if key == OVERLAY_TOP_LEFT:
		return OVERLAY_TOP_LEFT
	return OVERLAY_TOP_RIGHT

func _resolve_dropdown_label(value, options: Array) -> String:
	if value is int:
		return _option_at(options, int(value))
	if value is float:
		return _option_at(options, int(value))
	var text := str(value)
	if text.is_valid_int():
		return _option_at(options, int(text))
	return text

func _resolve_dropdown_key(value, options: Dictionary) -> String:
	var keys: Array = options.keys()
	if value is int:
		return _option_at(keys, int(value))
	if value is float:
		return _option_at(keys, int(value))
	var text := str(value)
	if text.is_valid_int():
		return _option_at(keys, int(text))
	if options.has(text):
		return text
	for key in keys:
		if str(options[key]) == text:
			return str(key)
	return ""

func _option_at(options: Array, index: int) -> String:
	if index >= 0 and index < options.size():
		return str(options[index])
	return ""

func _apply_cycle_now() -> void:
	if _injector == null:
		return
	cycle_track_number = _clamp_cycle_track_number(cycle_track_number, cycle_area_key)
	_last_cycle_signature = _cycle_signature()
	_injector.force_zone_track(cycle_area_key, cycle_track_number - 1)

func _sync_cycle_from_current_track() -> bool:
	if _injector == null:
		return false
	var info: Dictionary = _injector.get_current_track_info()
	if info.is_empty():
		return false
	var track_index: int = int(info.get("track_index", 0))
	var pool_count: int = int(info.get("pool_count", 0))
	var zone_key: String = str(info.get("zone", ""))
	if track_index <= 0 or pool_count <= 0 or zone_key.is_empty():
		return false
	var changed: bool = false
	if zone_key != cycle_area_key:
		cycle_area_key = zone_key
		_last_resolved_cycle_zone = cycle_area_key
		changed = true
	var clamped_index: int = _clamp_cycle_track_number(track_index, cycle_area_key)
	if clamped_index != cycle_track_number:
		cycle_track_number = clamped_index
		changed = true
	if changed:
		_last_cycle_signature = _cycle_signature()
	return true

func _cycle_signature() -> String:
	return "%s:%d" % [cycle_area_key, cycle_track_number]

func _refresh_dynamic_config(config: ConfigFile) -> bool:
	var changed := false
	changed = _set_config_entry_value(config, "Dropdown", "force_track", "options", _force_track_options()) or changed
	changed = _set_config_entry_value(config, "Dropdown", "selection_mode", "options", SELECTION_OPTIONS) or changed
	changed = _set_config_entry_value(config, "Dropdown", "debug_overlay_position", "options", OVERLAY_POSITION_OPTIONS) or changed
	changed = _set_config_entry_value(config, "Dropdown", "test_area", "options", AREA_OPTIONS) or changed
	var area_key: String = _resolve_area_key(_cfg(config, "Dropdown", "test_area", AREA_LABEL_CURRENT))
	var cycle_key: String = _cycle_area_for_config_selection(area_key)
	var max_range: int = _cycle_range_for_area(cycle_key)
	changed = _set_config_entry_value(config, "Int", "cycle_area_track", "maxRange", max_range) or changed
	var cycle_value: int = _clamp_cycle_track_number(int(_cfg(config, "Int", "cycle_area_track", 1)), cycle_key)
	changed = _set_config_entry_value(config, "Int", "cycle_area_track", "value", cycle_value) or changed
	return changed

func _cycle_area_for_config_selection(area_key: String) -> String:
	if _injector == null:
		return area_key
	var resolved_zone: String = _injector.get_resolved_zone_key(area_key)
	return area_key if resolved_zone.is_empty() else resolved_zone

func _set_config_entry_value(config: ConfigFile, section: String, key: String, entry_key: String, value) -> bool:
	var entry = config.get_value(section, key, null)
	if entry == null or not entry is Dictionary:
		return false
	if entry.get(entry_key, null) == value:
		return false
	entry[entry_key] = value
	config.set_value(section, key, entry)
	return true

func _sync_cycle_range_in_menu(menu) -> void:
	const MIN_RANGE := 1
	var active_menu = _cycle_menu_or_stored(menu)
	var max_range: int = _cycle_range_for_area(cycle_area_key)
	cycle_track_number = _clamp_cycle_track_number(cycle_track_number, cycle_area_key)
	if active_menu == null or not active_menu.has_method("GetElements"):
		return
	var elements: Dictionary = active_menu.GetElements()
	if not elements.has("cycle_area_track"):
		return
	var element = elements["cycle_area_track"]
	if element == null:
		return
	var value_data: Variant = element.GetValueData() if element.has_method("GetValueData") else element.get("valueData")
	_syncing_cycle_control = true
	if value_data is Dictionary:
		value_data["minRange"] = MIN_RANGE
		value_data["maxRange"] = max_range
		value_data["value"] = cycle_track_number
	if element is Node:
		_sync_range_nodes(element as Node, MIN_RANGE, max_range, cycle_track_number)
	if element.has_method("SetValue"):
		element.SetValue(cycle_track_number)
	_syncing_cycle_control = false

func _save_cycle_range_to_disk() -> void:
	var ini_path := MCM_FILE_PATH + "/config.ini"
	if not FileAccess.file_exists(ini_path):
		return
	var config := ConfigFile.new()
	if config.load(ini_path) != OK:
		return
	var max_range := _cycle_range_for_area(cycle_area_key)
	var changed := false
	changed = _set_config_entry_value(config, "Int", "cycle_area_track", "maxRange", max_range) or changed
	changed = _set_config_entry_value(config, "Int", "cycle_area_track", "value", cycle_track_number) or changed
	if changed:
		config.save(ini_path)

func _cycle_menu_or_stored(menu):
	if menu != null and menu.has_method("GetElements"):
		_last_cycle_menu = menu
		return menu
	if _last_cycle_menu != null and is_instance_valid(_last_cycle_menu):
		return _last_cycle_menu
	return null

func _sync_range_nodes(node: Node, min_range: int, max_range: int, value: int) -> void:
	if node is Range:
		var range_control: Range = node as Range
		range_control.min_value = float(min_range)
		range_control.max_value = float(max_range)
		range_control.step = 1.0
		range_control.value = float(value)
	for child in node.get_children():
		if child is Node:
			_sync_range_nodes(child as Node, min_range, max_range, value)
