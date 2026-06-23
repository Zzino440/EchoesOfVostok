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
var cycle_track_number: int = 1

var _mcm_helpers = null
var _on_update: Callable
var _injector = null  # MusicInjector (per force_track live via on_value_changed)
var _library  = null  # TrackLibrary (per le options del dropdown)
var _last_cycle_signature := ""

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
	_apply_config(config)
	_apply_cycle_if_changed()
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

func _on_test_area_changed(_value_id: String, new_value, _menu) -> void:
	test_area_key = _resolve_area_key(new_value)
	_apply_cycle_now()

func _on_cycle_area_track_changed(_value_id: String, new_value, _menu) -> void:
	cycle_track_number = max(1, int(new_value))
	_apply_cycle_now()

func _apply_config(config: ConfigFile) -> void:
	enabled   = bool(_cfg(config, "Bool",  "enabled",         DEFAULT_ENABLED))
	paused    = bool(_cfg(config, "Bool",  "paused",          DEFAULT_PAUSED))
	volume_db = float(_cfg(config, "Float", "track_volume_db", DEFAULT_VOLUME_DB))
	selection_mode = _resolve_selection_mode(_cfg(config, "Dropdown", "selection_mode", SELECTION_RANDOM))
	test_area_key = _resolve_area_key(_cfg(config, "Dropdown", "test_area", AREA_LABEL_CURRENT))
	cycle_track_number = max(1, int(_cfg(config, "Int", "cycle_area_track", 1)))

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
		"tooltip":  "Numero della traccia nel pool vanilla+mod dell'area selezionata. Se superi il totale, ricomincia da capo.",
		"default":  1,
		"value":    1,
		"minRange": 1,
		"maxRange": _max_cycle_range(),
		"step":     1,
		"on_value_changed": "_on_cycle_area_track_changed",
		"menu_pos": 6,
	})
	c.set_value("Float", "track_volume_db", {
		"name":     "Volume tracce mod (dB)",
		"tooltip":  "Offset volume delle tracce aggiunte. 0 = stesso livello delle tracce vanilla.",
		"default":  DEFAULT_VOLUME_DB,
		"value":    DEFAULT_VOLUME_DB,
		"minRange": -24.0,
		"maxRange": 6.0,
		"step":     1.0,
		"menu_pos": 7,
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
	return 32

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

func _apply_cycle_if_changed() -> void:
	var signature := _cycle_signature()
	if signature == _last_cycle_signature:
		return
	_apply_cycle_now()

func _apply_cycle_now() -> void:
	if _injector == null:
		return
	_last_cycle_signature = _cycle_signature()
	_injector.force_zone_track(test_area_key, cycle_track_number - 1)

func _cycle_signature() -> String:
	return "%s:%d" % [test_area_key, cycle_track_number]

func _refresh_dynamic_config(config: ConfigFile) -> bool:
	var changed := false
	changed = _set_config_entry_value(config, "Dropdown", "force_track", "options", _force_track_options()) or changed
	changed = _set_config_entry_value(config, "Dropdown", "selection_mode", "options", SELECTION_OPTIONS) or changed
	changed = _set_config_entry_value(config, "Dropdown", "test_area", "options", AREA_OPTIONS) or changed
	changed = _set_config_entry_value(config, "Int", "cycle_area_track", "maxRange", _max_cycle_range()) or changed
	return changed

func _set_config_entry_value(config: ConfigFile, section: String, key: String, entry_key: String, value) -> bool:
	var entry = config.get_value(section, key, null)
	if entry == null or not entry is Dictionary:
		return false
	if entry.get(entry_key, null) == value:
		return false
	entry[entry_key] = value
	config.set_value(section, key, entry)
	return true
