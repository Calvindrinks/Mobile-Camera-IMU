extends Node
class_name CameraStreamer

const NativeCameraScript := preload("res://addons/NativeCameraPlugin/NativeCamera.gd")
const FrameInfoScript := preload("res://addons/NativeCameraPlugin/model/FrameInfo.gd")

const IMAGE_HZ := 30.0
const JPEG_QUALITY := 60.0
const CAPTURE_WIDTH := 320
const REQUEST_WIDTH := 640
const REQUEST_HEIGHT := 480

var enabled := false
var _elapsed := 0.0
var _feed: CameraFeed
var _texture: CameraTexture
var _native_camera: Node
var _latest_native_frame: RefCounted
var _sequence := 0
var _last_error := ""
var _last_image_size := Vector2i.ZERO
var _empty_image_count := 0
var _using_native := false

func _ready() -> void:
	if not CameraServer.camera_feeds_updated.is_connected(_on_camera_feeds_updated):
		CameraServer.camera_feeds_updated.connect(_on_camera_feeds_updated)
	if not CameraServer.camera_feed_added.is_connected(_on_camera_feed_changed):
		CameraServer.camera_feed_added.connect(_on_camera_feed_changed)
	CameraServer.monitoring_feeds = true
	_native_camera = NativeCameraScript.new()
	_native_camera.frame_width = REQUEST_WIDTH
	_native_camera.frame_height = REQUEST_HEIGHT
	_native_camera.frames_to_skip = 0
	_native_camera.frame_rotation = 90
	_native_camera.frame_available.connect(_on_native_frame_available)
	add_child(_native_camera)

func start() -> bool:
	_sequence = 0
	_elapsed = 0.0
	_latest_native_frame = null
	_using_native = false

	if _native_camera != null and _native_camera.has_camera_permission():
		var request: RefCounted = _native_camera.create_feed_request()
		var cameras: Array = _native_camera.get_all_cameras()
		for camera in cameras:
			if not camera.is_front_facing():
				request.set_camera_id(camera.get_camera_id())
				break
		request.set_width(REQUEST_WIDTH).set_height(REQUEST_HEIGHT).set_frames_to_skip(0).set_rotation(90).set_grayscale(false)
		_native_camera.start(request)
		enabled = true
		_using_native = true
		_last_error = ""
		return true
	elif _native_camera != null:
		_native_camera.request_camera_permission()
		_last_error = "NativeCamera permission pending or plugin unavailable."

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
	if _native_camera != null:
		_native_camera.stop()
	if _feed != null:
		_feed.set_active(false)
	_feed = null
	_texture = null
	_latest_native_frame = null
	_using_native = false

func poll(delta: float) -> Dictionary:
	if enabled and _using_native:
		return _poll_native(delta)

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

func _poll_native(delta: float) -> Dictionary:
	_elapsed += delta
	if _elapsed < 1.0 / IMAGE_HZ:
		return {}
	_elapsed = 0.0

	if _latest_native_frame == null:
		_empty_image_count += 1
		_last_error = "waiting for NativeCamera frame"
		return {}

	var image: Image = _latest_native_frame.get_image()
	if image == null or image.is_empty():
		_empty_image_count += 1
		_last_error = "empty NativeCamera image"
		return {}

	_empty_image_count = 0
	_last_image_size = image.get_size()
	if image.get_width() > CAPTURE_WIDTH:
		var target_height := int(round(float(image.get_height()) * float(CAPTURE_WIDTH) / float(image.get_width())))
		image.resize(CAPTURE_WIDTH, target_height, Image.INTERPOLATE_BILINEAR)

	var jpeg: PackedByteArray = image.save_jpg_to_buffer(JPEG_QUALITY)
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
	if _using_native:
		return "native camera active last=%dx%d empty=%d error=%s" % [
			_last_image_size.x,
			_last_image_size.y,
			_empty_image_count,
			_last_error
		]
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
	if _using_native:
		packet.merge({
			"backend": "NativeCameraPlugin",
			"native_has_permission": _native_camera.has_camera_permission() if _native_camera != null else false,
			"native_has_frame": _latest_native_frame != null
		})
		return packet
	packet["backend"] = "CameraServer"
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

func _on_native_frame_available(frame_info: RefCounted) -> void:
	_latest_native_frame = frame_info
	_last_error = ""

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
