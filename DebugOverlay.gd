extends CanvasLayer

const POSITION_TOP_LEFT := "top_left"
const POSITION_TOP_RIGHT := "top_right"
const ZONE_LABELS := {
	"area05": "Area 05",
	"borderZone": "Border Zone",
	"vostok": "Vostok",
	"shelter": "Shelter",
	"forced": "Forced",
}

var enabled: bool = false
var position: String = POSITION_TOP_RIGHT

var _injector = null
var _label: Label = null
var _last_text := ""

func setup(injector) -> void:
	_injector = injector
	layer = 90
	process_mode = Node.PROCESS_MODE_ALWAYS
	_label = Label.new()
	_label.name = "MusicDebugLabel"
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.clip_text = true
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.add_theme_font_size_override("font_size", 15)
	_label.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0, 0.95))
	_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
	_label.add_theme_constant_override("outline_size", 2)
	add_child(_label)
	_apply_position()
	visible = false

func set_enabled(value: bool) -> void:
	enabled = value
	visible = enabled

func set_position(value: String) -> void:
	position = POSITION_TOP_LEFT if value == POSITION_TOP_LEFT else POSITION_TOP_RIGHT
	_apply_position()

func tick() -> void:
	if not enabled or _label == null or _injector == null:
		return
	var info: Dictionary = _injector.get_current_track_info()
	var text := _format_info(info)
	if text == _last_text:
		return
	_last_text = text
	_label.text = text

func _format_info(info: Dictionary) -> String:
	if info.is_empty():
		return "MusicExpansion\nWAITING\nNo active gameplay track"
	var source: String = str(info.get("source", "unknown"))
	var source_label: String = "CUSTOM" if source == "mod" else "VANILLA"
	var display: String = str(info.get("display", "Unknown track"))
	var zone: String = str(info.get("zone", ""))
	var zone_label: String = str(ZONE_LABELS.get(zone, zone))
	if zone_label.is_empty():
		zone_label = "Unknown"
	var track_index: int = int(info.get("track_index", 0))
	var pool_count: int = int(info.get("pool_count", 0))
	var pool_label: String = "%d/%d" % [track_index, pool_count] if pool_count > 0 else "Unknown"
	return "MusicExpansion\n%s\nTrack: %s\nZone: %s\nPool: %s" % [
		source_label,
		display,
		zone_label,
		pool_label,
	]

func _apply_position() -> void:
	if _label == null:
		return
	_label.size = Vector2(620, 140)
	_label.custom_minimum_size = Vector2(420, 126)
	_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	if position == POSITION_TOP_LEFT:
		_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
		_label.offset_left = 18
		_label.offset_top = 16
		_label.offset_right = 638
		_label.offset_bottom = 156
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	else:
		_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		_label.offset_left = -638
		_label.offset_top = 16
		_label.offset_right = -18
		_label.offset_bottom = 156
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
