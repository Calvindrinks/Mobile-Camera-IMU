extends Node
class_name WebSocketPublisher

var endpoint: String = ""
var dry_run: bool = true

var _peer: WebSocketPeer
var _last_error := ""

func _ready() -> void:
	_reset_peer()
	set_process(false)

func _process(_delta: float) -> void:
	if _peer != null:
		_peer.poll()

func connect_pub(target_endpoint: String) -> bool:
	disconnect_pub()
	_reset_peer()
	endpoint = target_endpoint
	_last_error = ""
	dry_run = true

	var err := _peer.connect_to_url(endpoint)
	if err != OK:
		_last_error = "WebSocket connect_to_url failed: %s" % error_string(err)
		return false

	set_process(true)
	dry_run = false
	return true

func disconnect_pub() -> void:
	if _peer != null:
		var state := _peer.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN or state == WebSocketPeer.STATE_CONNECTING:
			_peer.close()
			_peer.poll()
	_reset_peer()
	dry_run = true
	set_process(false)
	_last_error = "Disconnected."

func send_packet(packet: Dictionary) -> bool:
	if _peer == null:
		_last_error = "WebSocket peer not initialized."
		print(JSON.stringify(packet))
		return false

	_peer.poll()
	var state := _peer.get_ready_state()
	if dry_run or state != WebSocketPeer.STATE_OPEN:
		if state == WebSocketPeer.STATE_CLOSING or state == WebSocketPeer.STATE_CLOSED:
			_last_error = "WebSocket closed."
		print(JSON.stringify(packet))
		return false

	var err := _peer.send_text(JSON.stringify(packet))
	if err != OK:
		_last_error = "WebSocket send_text failed: %s" % error_string(err)
		return false
	return true

func get_status() -> String:
	var state := _peer.get_ready_state()
	match state:
		WebSocketPeer.STATE_CONNECTING:
			return "WebSocket connecting: " + endpoint
		WebSocketPeer.STATE_OPEN:
			return "WebSocket connected: " + endpoint
		WebSocketPeer.STATE_CLOSING:
			return "WebSocket closing: " + endpoint
		WebSocketPeer.STATE_CLOSED:
			if dry_run:
				return "WebSocket dry-run: " + _last_error
			return "WebSocket closed: " + _last_error
		_:
			return "WebSocket state: %s" % state

func is_socket_open() -> bool:
	return _peer != null and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN

func _reset_peer() -> void:
	_peer = WebSocketPeer.new()
