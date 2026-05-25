extends Node
class_name ZmqPublisher

const SOCKET_PUB := 1
const CONNECTION_CONNECT := 2

var endpoint: String = ""
var topic: String = "mobile"
var dry_run: bool = true

var _socket: Object
var _last_error: String = ""

func connect_pub(target_endpoint: String) -> bool:
	endpoint = target_endpoint
	_last_error = ""
	dry_run = true
	_socket = null

	if not ClassDB.class_exists("ZMQSender"):
		_last_error = "ZMQSender class not found; install/build godot_zeromq binary addon."
		return false

	_socket = ClassDB.instantiate("ZMQSender")
	if _socket == null:
		_last_error = "Could not instantiate ZMQSender."
		return false

	add_child(_socket)
	if not _call_first(_socket, ["init"], [endpoint, SOCKET_PUB, CONNECTION_CONNECT, "", false]):
		_last_error = "ZMQSender exists, but init(address, PUB, CONNECT, filter, false) failed."
		_socket.queue_free()
		_socket = null
		return false

	dry_run = false
	return true

func send_packet(packet: Dictionary) -> bool:
	var payload := JSON.stringify(packet)
	if dry_run or _socket == null:
		print("%s %s" % [topic, payload])
		return false

	if _call_first(_socket, ["sendString"], [payload]):
		return true
	_last_error = "ZMQSender has no sendString(message) method."
	return false

func get_status() -> String:
	if dry_run:
		return "ZMQ dry-run: " + _last_error
	return "ZMQ connected: " + endpoint

func _call_first(target: Object, methods: Array, args: Array) -> bool:
	for method in methods:
		if target.has_method(method):
			target.callv(method, args)
			return true
	return false
