extends Control

const ComplementaryImuScript := preload("res://scripts/ComplementaryImu.gd")
const WebSocketPublisherScript := preload("res://scripts/WebSocketPublisher.gd")
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
var elapsed := 0.0
var ui_elapsed := 0.0
var sequence := 0

func _ready() -> void:
	publisher = WebSocketPublisherScript.new()
	add_child(publisher)
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

	ui_elapsed += dt
	if ui_elapsed >= 1.0 / UI_HZ:
		ui_elapsed = 0.0
		payload_label.text = JSON.stringify(packet, "\t")
		_update_status()

func _connect_transport() -> void:
	publisher.connect_pub(endpoint_edit.text.strip_edges())
	_update_status()

func _disconnect_transport() -> void:
	stream_toggle.button_pressed = false
	set_process(false)
	set_physics_process(false)
	if publisher != null and publisher.has_method("disconnect_pub"):
		publisher.disconnect_pub()
	_update_status()

func _set_streaming(enabled: bool) -> void:
	set_physics_process(enabled)
	if enabled:
		elapsed = 0.0
		ui_elapsed = 0.0
		sequence = 0
		imu.reset()
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
		"quaternion_xyzw": [q.x, q.y, q.z, q.w],
		"gravity": _vec3_to_array(Input.get_gravity()),
		"gyroscope": _vec3_to_array(Input.get_gyroscope()),
		"accelerometer": _vec3_to_array(Input.get_accelerometer())
	}

func _vec3_to_array(v: Vector3) -> Array:
	return [v.x, v.y, v.z]

func _update_status() -> void:
	var streaming := "streaming" if stream_toggle.button_pressed else "paused"
	status_label.text = "%s\n%s" % [streaming, publisher.get_status()]
