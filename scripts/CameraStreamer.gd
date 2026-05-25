extends Node
class_name CameraStreamer

const IMAGE_HZ := 30.0
const JPEG_QUALITY := 60.0
const CAPTURE_WIDTH := 320

var enabled := false
var _elapsed := 0.0
var _feed: CameraFeed
var _texture: CameraTexture
var _sequence := 0
var _last_error := ""
var _last_image_size := Vector2i.ZERO
var _empty_image_count := 0

func _ready() -> void:
	if not CameraServer.camera_feeds_updated.is_connected(_on_camera_feeds_updated):
		CameraServer.camera_feeds_updated.connect(_on_camera_feeds_updated)
	if not CameraServer.camera_feed_added.is_connected(_on_camera_feed_changed):
		CameraServer.camera_feed_added.connect(_on_camera_feed_changed)
	CameraServer.monitoring_feeds = true

func start() -> bool:
	_sequence = 0
	_elapsed = 0.0
	CameraServer.monitoring_feeds = true
	_feed = _find_back_camera_feed()
	if _feed == null:
		_feed = _find_any_feed()
	if _feed == null:
		_last_error = "No camera feed found yet. feed_count=%d" % CameraServer.get_feed_count()
		push_warning(_last_error)
		enabled = false
		return false

	_feed.set_active(true)
	_texture = CameraTexture.new()
	_texture.camera_feed_id = _feed.get_id()
	_texture.camera_is_active = true
	_feed.set_active(true)
	_texture.which_feed = CameraServer.FEED_RGBA_IMAGE
	enabled = true
	_last_error = ""
	return true

func stop() -> void:
	enabled = false
	if _feed != null:
		_feed.set_active(false)
	_feed = null
	_texture = null

func poll(delta: float) -> Dictionary:
	if not enabled or _texture == null:
		_elapsed += delta
		if _elapsed >= 1.0:
			_elapsed = 0.0
			start()
		return {}

	_elapsed += delta
	if _elapsed < 1.0 / IMAGE_HZ:
		return {}
	_elapsed = 0.0

	var image := _texture.get_image()
	if image == null or image.is_empty():
		_empty_image_count += 1
		_last_error = "empty image count=%d datatype=%d" % [_empty_image_count, _feed.get_datatype() if _feed != null else -1]
		return {}
	_empty_image_count = 0
	_last_image_size = image.get_size()

	if image.get_width() > CAPTURE_WIDTH:
		var target_height := int(round(float(image.get_height()) * float(CAPTURE_WIDTH) / float(image.get_width())))
		image.resize(CAPTURE_WIDTH, target_height, Image.INTERPOLATE_BILINEAR)

	var jpeg := image.save_jpg_to_buffer(JPEG_QUALITY)
	if jpeg.is_empty():
		return {}

	_sequence += 1
	return {
		"type": "image",
		"seq": _sequence,
		"timestamp_msec": Time.get_ticks_msec(),
		"width": image.get_width(),
		"height": image.get_height(),
		"jpeg": jpeg
	}

func get_status() -> String:
	if not enabled:
		return "camera stopped: %s feed_count=%d" % [_last_error, CameraServer.get_feed_count()]
	if _feed == null:
		return "camera unavailable"
	return "camera active: %s feed_count=%d last=%dx%d empty=%d" % [
		_describe_feed(_feed),
		CameraServer.get_feed_count(),
		_last_image_size.x,
		_last_image_size.y,
		_empty_image_count
	]

func get_debug_packet() -> Dictionary:
	var packet := {
		"type": "debug",
		"timestamp_msec": Time.get_ticks_msec(),
		"camera_status": get_status(),
		"feed_count": CameraServer.get_feed_count(),
		"last_image_size": [_last_image_size.x, _last_image_size.y],
		"empty_image_count": _empty_image_count,
		"last_error": _last_error
	}
	if _feed != null:
		packet.merge({
			"feed_id": _feed.get_id(),
			"feed_name": _feed.get_name(),
			"feed_position": _feed.get_position(),
			"feed_datatype": _feed.get_datatype(),
			"feed_active": _feed.is_active(),
			"texture_active": _texture.camera_is_active if _texture != null else false,
			"texture_feed_id": _texture.camera_feed_id if _texture != null else -1,
			"texture_which_feed": _texture.which_feed if _texture != null else -1
		})
	return packet

func _on_camera_feeds_updated() -> void:
	if not enabled and _texture == null:
		start()

func _on_camera_feed_changed(_id: int) -> void:
	if not enabled and _texture == null:
		start()

func _find_back_camera_feed() -> CameraFeed:
	for feed in CameraServer.feeds():
		if feed is CameraFeed and feed.get_position() == CameraFeed.FEED_BACK:
			return feed
	return null

func _find_any_feed() -> CameraFeed:
	for feed in CameraServer.feeds():
		if feed is CameraFeed:
			return feed
	return null

func _describe_feed(feed: CameraFeed) -> String:
	return "id=%d name=%s pos=%d datatype=%d active=%s" % [
		feed.get_id(),
		feed.get_name(),
		feed.get_position(),
		feed.get_datatype(),
		str(feed.is_active())
	]
