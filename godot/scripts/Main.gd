extends Control

const ComplementaryImuScript := preload("res://scripts/ComplementaryImu.gd")
const WebSocketPublisherScript := preload("res://scripts/WebSocketPublisher.gd")
const CameraStreamerScript := preload("res://scripts/CameraStreamer.gd")
const DEFAULT_SEND_HZ := 200.0
const UI_HZ := 10.0
const LANDSCAPE_UI_SCALE := 3.0

const BASE_FONT_SIZES := {
	"Title": 46,
	"Status": 28,
	"EndpointPreset": 28,
	"Endpoint": 28,
	"ImuHz": 28,
	"CameraHz": 28,
	"Resolution": 28,
	"Connect": 28,
	"Disconnect": 28,
	"Streaming": 28,
	"Payload": 24
}
const BASE_MIN_HEIGHTS := {
	"EndpointPreset": 56,
	"Endpoint": 56,
	"ImuHz": 56,
	"CameraHz": 56,
	"Resolution": 56,
	"Connect": 64,
	"Disconnect": 64,
	"Streaming": 64
}
const ENDPOINT_PRESETS := [
	"ws://192.168.0.16:8765",
	"ws://172.168.101.40:8765"
]
const IMU_HZ_OPTIONS := [200.0, 100.0]
const CAMERA_HZ_OPTIONS := [30.0, 10.0]

@onready var status_label: Label = $Margin/Panel/Rows/Status
@onready var endpoint_preset: OptionButton = $Margin/Panel/Rows/EndpointRow/EndpointPreset
@onready var endpoint_edit: LineEdit = $Margin/Panel/Rows/EndpointRow/Endpoint
@onready var imu_hz_option: OptionButton = $Margin/Panel/Rows/Settings/ImuHz
@onready var camera_hz_option: OptionButton = $Margin/Panel/Rows/Settings/CameraHz
@onready var resolution_option: OptionButton = $Margin/Panel/Rows/Settings/Resolution
@onready var connect_button: Button = $Margin/Panel/Rows/Buttons/Connect
@onready var disconnect_button: Button = $Margin/Panel/Rows/Buttons/Disconnect
@onready var stream_toggle: CheckButton = $Margin/Panel/Rows/Buttons/Streaming
@onready var payload_label: Label = $Margin/Panel/Rows/Payload
@onready var title_label: Label = $Margin/Panel/Rows/Title

var imu := ComplementaryImuScript.new()
var publisher: Node
var camera_streamer: Node
var elapsed := 0.0
var ui_elapsed := 0.0
var debug_elapsed := 0.0
var sequence := 0
var _last_landscape_ui := false
var _send_hz := DEFAULT_SEND_HZ
var _camera_hz := 30.0
var _resolution_options: Array[Vector2i] = []

func _ready() -> void:
	if OS.has_feature("android"):
		OS.request_permissions()
	publisher = WebSocketPublisherScript.new()
	add_child(publisher)
	camera_streamer = CameraStreamerScript.new()
	add_child(camera_streamer)
	endpoint_preset.item_selected.connect(_select_endpoint_preset)
	imu_hz_option.item_selected.connect(_select_imu_hz)
	camera_hz_option.item_selected.connect(_select_camera_hz)
	resolution_option.item_selected.connect(_select_resolution)
	connect_button.pressed.connect(_connect_transport)
	disconnect_button.pressed.connect(_disconnect_transport)
	stream_toggle.toggled.connect(_set_streaming)
	set_process(false)
	set_physics_process(false)
	_populate_resolution_options()
	_update_responsive_ui()
	_update_status()

func _physics_process(delta: float) -> void:
	elapsed += delta
	if elapsed < 1.0 / _send_hz:
		_update_orientation(delta)
		return

	var dt := elapsed
	elapsed = 0.0
	var q := _update_orientation(dt)
	var packet := _make_packet(q)
	publisher.send_packet(packet)
	var image_packet: Dictionary = camera_streamer.poll(dt)
	if not image_packet.is_empty():
		publisher.send_image_packet(image_packet)

	ui_elapsed += dt
	if ui_elapsed >= 1.0 / UI_HZ:
		ui_elapsed = 0.0
		payload_label.text = JSON.stringify(packet, "\t")
		_update_status()

	debug_elapsed += dt
	if debug_elapsed >= 1.0:
		debug_elapsed = 0.0
		if camera_streamer != null:
			publisher.send_packet(camera_streamer.get_debug_packet())

func _connect_transport() -> void:
	publisher.connect_pub(endpoint_edit.text.strip_edges())
	_update_status()

func _select_endpoint_preset(index: int) -> void:
	if index < ENDPOINT_PRESETS.size():
		endpoint_edit.text = ENDPOINT_PRESETS[index]
	endpoint_edit.grab_focus()

func _select_imu_hz(index: int) -> void:
	if index < IMU_HZ_OPTIONS.size():
		_send_hz = IMU_HZ_OPTIONS[index]
	_update_status()

func _select_camera_hz(index: int) -> void:
	if index < CAMERA_HZ_OPTIONS.size():
		_camera_hz = CAMERA_HZ_OPTIONS[index]
		if camera_streamer != null:
			camera_streamer.set_image_hz(_camera_hz)
	_update_status()

func _select_resolution(index: int) -> void:
	if index < _resolution_options.size() and camera_streamer != null:
		camera_streamer.set_resolution(_resolution_options[index])
	_update_status()

func _disconnect_transport() -> void:
	stream_toggle.button_pressed = false
	set_process(false)
	set_physics_process(false)
	if publisher != null and publisher.has_method("disconnect_pub"):
		publisher.disconnect_pub()
	if camera_streamer != null:
		camera_streamer.stop()
	_update_status()

func _set_streaming(enabled: bool) -> void:
	set_physics_process(enabled)
	if enabled:
		_populate_resolution_options()
		if camera_streamer != null:
			camera_streamer.set_image_hz(_camera_hz)
		elapsed = 0.0
		ui_elapsed = 0.0
		debug_elapsed = 0.0
		sequence = 0
		imu.reset()
		if camera_streamer != null:
			camera_streamer.start()
	elif camera_streamer != null:
		camera_streamer.stop()
	_update_status()

func _update_orientation(delta: float) -> Quaternion:
	var gravity := Input.get_gravity()
	var gyro := Input.get_gyroscope()
	return imu.update(gravity, gyro, delta)

func _make_packet(q: Quaternion) -> Dictionary:
	sequence += 1
	return {
		"type": "imu",
		"seq": sequence,
		"timestamp_msec": Time.get_ticks_msec(),
		"imu_frame": "camera_body",
		"imu_hz": _send_hz,
		"screen_orientation": _screen_orientation_name(),
		"quaternion_xyzw": [q.x, q.y, q.z, q.w],
		"gravity": _accel_like_to_camera_body_array(Input.get_gravity()),
		"gyroscope": _gyro_to_camera_body_array(Input.get_gyroscope()),
		"accelerometer": _accel_like_to_camera_body_array(Input.get_accelerometer())
	}

func _accel_like_to_camera_body_array(v: Vector3) -> Array:
	return [-v.x, v.y, v.z]

func _gyro_to_camera_body_array(v: Vector3) -> Array:
	return [v.x, -v.y, -v.z]

func _screen_orientation_name() -> String:
	var orientation := DisplayServer.screen_get_orientation()
	match orientation:
		DisplayServer.SCREEN_PORTRAIT:
			return "portrait"
		DisplayServer.SCREEN_REVERSE_LANDSCAPE:
			return "reverse_landscape"
		DisplayServer.SCREEN_REVERSE_PORTRAIT:
			return "reverse_portrait"
		DisplayServer.SCREEN_LANDSCAPE:
			return "landscape"
		DisplayServer.SCREEN_SENSOR_LANDSCAPE:
			return "sensor_landscape"
		DisplayServer.SCREEN_SENSOR_PORTRAIT:
			return "sensor_portrait"
		DisplayServer.SCREEN_SENSOR:
			return "sensor"
		_:
			return "unknown:%d" % orientation

func _update_status() -> void:
	_update_responsive_ui()
	var streaming := "streaming" if stream_toggle.button_pressed else "paused"
	var camera_status := ""
	if camera_streamer != null:
		camera_status = "\n" + camera_streamer.get_status()
	status_label.text = "%s | IMU %.0fHz | Cam %.0fHz\n%s%s" % [streaming, _send_hz, _camera_hz, publisher.get_status(), camera_status]

func _update_responsive_ui() -> void:
	var landscape := _is_landscape_orientation()
	if landscape == _last_landscape_ui:
		return
	_last_landscape_ui = landscape
	var scale := LANDSCAPE_UI_SCALE if landscape else 1.0
	_apply_font_size(title_label, "Title", scale)
	_apply_font_size(status_label, "Status", scale)
	_apply_font_size(endpoint_preset, "EndpointPreset", scale)
	_apply_font_size(endpoint_edit, "Endpoint", scale)
	_apply_font_size(imu_hz_option, "ImuHz", scale)
	_apply_font_size(camera_hz_option, "CameraHz", scale)
	_apply_font_size(resolution_option, "Resolution", scale)
	_apply_font_size(connect_button, "Connect", scale)
	_apply_font_size(disconnect_button, "Disconnect", scale)
	_apply_font_size(stream_toggle, "Streaming", scale)
	_apply_font_size(payload_label, "Payload", scale)
	_apply_min_height(endpoint_preset, "EndpointPreset", scale)
	_apply_min_height(endpoint_edit, "Endpoint", scale)
	_apply_min_height(imu_hz_option, "ImuHz", scale)
	_apply_min_height(camera_hz_option, "CameraHz", scale)
	_apply_min_height(resolution_option, "Resolution", scale)
	_apply_min_height(connect_button, "Connect", scale)
	_apply_min_height(disconnect_button, "Disconnect", scale)
	_apply_min_height(stream_toggle, "Streaming", scale)

func _is_landscape_orientation() -> bool:
	var orientation := DisplayServer.screen_get_orientation()
	return orientation == DisplayServer.SCREEN_LANDSCAPE \
		or orientation == DisplayServer.SCREEN_REVERSE_LANDSCAPE \
		or orientation == DisplayServer.SCREEN_SENSOR_LANDSCAPE

func _apply_font_size(node: Control, key: String, scale: float) -> void:
	node.add_theme_font_size_override("font_size", int(round(BASE_FONT_SIZES[key] * scale)))

func _apply_min_height(node: Control, key: String, scale: float) -> void:
	node.custom_minimum_size.y = int(round(BASE_MIN_HEIGHTS[key] * scale))

func _populate_resolution_options() -> void:
	if camera_streamer == null:
		return
	var previous: Vector2i = camera_streamer.get_resolution()
	var supported: Array = camera_streamer.refresh_supported_resolutions()
	_resolution_options.clear()
	resolution_option.clear()
	var selected_index := 0
	for size in supported:
		if size is Vector2i and not _resolution_options.has(size):
			_resolution_options.append(size)
	for i: int in _resolution_options.size():
		var resolution := _resolution_options[i]
		resolution_option.add_item("%dx%d" % [resolution.x, resolution.y])
		if resolution == previous:
			selected_index = i
	if _resolution_options.is_empty():
		_resolution_options.append(Vector2i(1280, 720))
		resolution_option.add_item("1280x720")
	if selected_index >= _resolution_options.size():
		selected_index = 0
	resolution_option.select(selected_index)
	camera_streamer.set_resolution(_resolution_options[selected_index])
