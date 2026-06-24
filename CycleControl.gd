extends RefCounted

# Manages the "Test area / Area track cycle" feature exposed in the MCM panel.
# Tracks which track is playing per zone, syncs the MCM slider live, and persists
# the selection to disk so it survives MCM closes.
#
# Instantiated by Main before Config; Config receives a reference and delegates
# the two MCM dropdown callbacks here.

const MCM_FILE_PATH := "user://MCM/EchoesOfVostok"

const AREA_CURRENT       := "current"
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
	"Area 05":          "area05",
	"Border Zone":      "borderZone",
	"Vostok":           "vostok",
	"Shelter":          "shelter",
}

var test_area_key: String    = AREA_CURRENT
var cycle_area_key: String   = AREA_CURRENT
var cycle_track_number: int  = 1

var _library  = null
var _injector = null

var _last_cycle_signature := ""
var _last_cycle_menu = null
var _last_resolved_cycle_zone := ""
var _syncing_cycle_control: bool = false

func setup(library, injector) -> void:
	_library  = library
	_injector = injector

# Called from Config._apply_config after loading the ini.
func apply_from_config(test_area_raw, track_number_raw: int) -> void:
	test_area_key      = _resolve_area_key(test_area_raw)
	_update_cycle_area_from_selection()
	cycle_track_number = _clamp_cycle_track_number(track_number_raw, cycle_area_key)
	_last_cycle_signature = _cycle_signature()

# Called from Main._physics_process (throttled).
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
		_save_cycle_range_to_disk()
		_sync_cycle_range_in_menu(_cycle_menu_or_stored(menu))

# ── Public helpers used by Config ─────────────────────────────────────────────

func get_max_cycle_range() -> int:
	return get_cycle_range_for_area(cycle_area_key)

func get_cycle_range_for_area(area_key: String) -> int:
	var count := 0
	if _injector != null:
		count = _injector.get_zone_pool_count(area_key)
	if count <= 0 and _library != null:
		if area_key == AREA_CURRENT:
			count = _library.get_max_zone_track_count()
		else:
			count = _library.get_track_count_for_zone(area_key)
	return max(1, count)

func clamp_cycle_track_number(value: int, area_key: String) -> int:
	return _clamp_cycle_track_number(value, area_key)

func get_cycle_area_for_config_selection(area_key: String) -> String:
	return _cycle_area_for_config_selection(area_key)

# ── MCM callbacks (delegated from Config) ─────────────────────────────────────

func on_test_area_changed(_value_id: String, new_value, menu) -> void:
	test_area_key = _resolve_area_key(new_value)
	_update_cycle_area_from_selection()
	_sync_cycle_range_in_menu(menu)

func on_cycle_area_track_changed(_value_id: String, new_value, _menu) -> void:
	cycle_track_number = _clamp_cycle_track_number(int(new_value), cycle_area_key)
	var signature: String = _cycle_signature()
	if _syncing_cycle_control or signature == _last_cycle_signature:
		_last_cycle_signature = signature
		return
	_apply_cycle_now()

# ── Private ───────────────────────────────────────────────────────────────────

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

func _update_cycle_area_from_selection() -> void:
	var resolved_zone: String = _resolved_cycle_zone_for(test_area_key)
	if resolved_zone.is_empty():
		cycle_area_key = test_area_key
	else:
		cycle_area_key = resolved_zone
	_last_resolved_cycle_zone = cycle_area_key

func _resolved_cycle_zone_for(area_key: String) -> String:
	if _injector == null:
		return ""
	return _injector.get_resolved_zone_key(area_key)

func _clamp_cycle_track_number(value: int, area_key: String) -> int:
	var max_range := get_cycle_range_for_area(area_key)
	return min(max(1, value), max_range)

func _cycle_area_for_config_selection(area_key: String) -> String:
	if _injector == null:
		return area_key
	var resolved_zone: String = _injector.get_resolved_zone_key(area_key)
	return area_key if resolved_zone.is_empty() else resolved_zone

func _sync_cycle_range_in_menu(menu) -> void:
	const MIN_RANGE := 1
	var active_menu = _cycle_menu_or_stored(menu)
	var max_range: int = get_cycle_range_for_area(cycle_area_key)
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
	var max_range := get_cycle_range_for_area(cycle_area_key)
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

func _set_config_entry_value(config: ConfigFile, section: String, key: String, entry_key: String, value) -> bool:
	var entry = config.get_value(section, key, null)
	if entry == null or not entry is Dictionary:
		return false
	if entry.get(entry_key, null) == value:
		return false
	entry[entry_key] = value
	config.set_value(section, key, entry)
	return true

# ── Dropdown resolver helpers ─────────────────────────────────────────────────

func _resolve_area_key(value) -> String:
	var label := _resolve_dropdown_label(value, AREA_OPTIONS)
	return AREA_KEYS_BY_LABEL.get(label, AREA_CURRENT)

func _resolve_dropdown_label(value, options: Array) -> String:
	if value is int:
		return _option_at(options, int(value))
	if value is float:
		return _option_at(options, int(value))
	var text := str(value)
	if text.is_valid_int():
		return _option_at(options, int(text))
	return text

func _option_at(options: Array, index: int) -> String:
	if index >= 0 and index < options.size():
		return str(options[index])
	return ""
