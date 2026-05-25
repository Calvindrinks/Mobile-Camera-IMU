extends Control

const ComplementaryImuScript := preload("res://scripts/ComplementaryImu.gd")
const WebSocketPublisherScript := preload("res://scripts/WebSocketPublisher.gd")
const CameraStreamerScript := preload("res://scripts/CameraStreamer.gd")
const SEND_HZ := 200.0
const UI_HZ := 10.0

@onready var status_label: Label = $Margin/Panel/Rows/Status
@onready var endpoint_edit: LineEdit = $Margin/Panel/Rows/Endpoint
@onready var connect_button: Button = $Margin/Panel/Rows/Buttons/Connect
@onready var disconnect_button: Button = $Margin/Panel/Rows/Buttons/Disconnect
@onready var stream_toggle: CheckButton = $Margin/Panel/Rows/Buttons/Streaming
@onready var payload_label: Label = $Margin/Panel/Rows/Payload

var imu := ComplementaryImuScript.new()
var publisher: Node
var camera_streamer: Node
var elapsed := 0.0
var ui_elapsed := 0.0
var debug_elapsed := 0.0
var sequence := 0

func _ready() -> void:
	if OS.has_feature("android"):
		OS.request_permissions()
	publisher = WebSocketPublisherScript.new()
	add_child(publisher)
	camera_streamer = CameraStreamerScript.new()
	add_child(camera_streamer)
	connect_button.pressed.connect(_connect_transport)
	disconnect_button.pressed.connect(_disconnect_transport)
	stream_toggle.toggled.connect(_set_streaming)
	set_process(false)
	set_physics_process(false)
	_update_status()

func _physics_process(delta: float) -> void:
	elapsed += delta
	if elapsed < 1.0 / SEND_HZ:
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
	var streaming := "streaming" if stream_toggle.button_pressed else "paused"
	var camera_status := ""
	if camera_streamer != null:
		camera_status = "\n" + camera_streamer.get_status()
	status_label.text = "%s\n%s%s" % [streaming, publisher.get_status(), camera_status]
