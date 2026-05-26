extends Node
class_name CameraStreamer

const NativeCameraScript := preload("res://addons/NativeCameraPlugin/NativeCamera.gd")
const FrameInfoScript := preload("res://addons/GMPShared/FrameInfo.gd")

const DEFAULT_IMAGE_HZ := 30.0
const JPEG_QUALITY := 0.6
const DEFAULT_REQUEST_WIDTH := 1280
const DEFAULT_REQUEST_HEIGHT := 720
const AUTO_UPRIGHT := true

var enabled := false
var _elapsed := 0.0
var _feed: CameraFeed
var _texture: CameraTexture
var _native_camera: Node
var _latest_native_frame: RefCounted
var _sequence := 0
var _last_error := ""
var _last_image_size := Vector2i.ZERO
var _last_jpeg_size := 0
var _empty_image_count := 0
var _using_native := false
var _image_hz := DEFAULT_IMAGE_HZ
var _request_size := Vector2i(DEFAULT_REQUEST_WIDTH, DEFAULT_REQUEST_HEIGHT)
var _supported_resolutions: Array[Vector2i] = []

func _ready() -> void:
	if not CameraServer.camera_feeds_updated.is_connected(_on_camera_feeds_updated):
		CameraServer.camera_feeds_updated.connect(_on_camera_feeds_updated)
	if not CameraServer.camera_feed_added.is_connected(_on_camera_feed_changed):
		CameraServer.camera_feed_added.connect(_on_camera_feed_changed)
	CameraServer.monitoring_feeds = true
	_native_camera = NativeCameraScript.new()
	_native_camera.frame_width = _request_size.x
	_native_camera.frame_height = _request_size.y
	_native_camera.frames_to_skip = 0
	_native_camera.frame_rotation = 90
	_native_camera.auto_upright = AUTO_UPRIGHT
	_native_camera.scale_width = _request_size.x
	_native_camera.scale_height = _request_size.y
	_native_camera.frame_available.connect(_on_native_frame_available)
	add_child(_native_camera)
	refresh_supported_resolutions()

func set_image_hz(value: float) -> void:
	_image_hz = max(1.0, value)

func set_resolution(size: Vector2i) -> void:
	if size.x <= 0 or size.y <= 0:
		return
	_request_size = size
	if _native_camera != null:
		_native_camera.frame_width = _request_size.x
		_native_camera.frame_height = _request_size.y
		_native_camera.scale_width = _request_size.x
		_native_camera.scale_height = _request_size.y
	if enabled and _using_native:
		stop()
		start()

func get_resolution() -> Vector2i:
	return _request_size

func refresh_supported_resolutions() -> Array[Vector2i]:
	_supported_resolutions.clear()
	if _native_camera == null or not Engine.has_singleton("NativeCameraPlugin"):
		return _fallback_resolutions()
	var cameras: Array = _native_camera.get_all_cameras()
	var selected_camera = null
	for camera in cameras:
		if not camera.is_front_facing():
			selected_camera = camera
			break
	if selected_camera == null and not cameras.is_empty():
		selected_camera = cameras[0]
	if selected_camera == null:
		return _fallback_resolutions()
	for size in selected_camera.get_output_sizes():
		var resolution := Vector2i(size.get_width(), size.get_height())
		if resolution.x > 0 and resolution.y > 0 and not _supported_resolutions.has(resolution):
			_supported_resolutions.append(resolution)
	_supported_resolutions.sort_custom(_compare_resolution_area_desc)
	if _supported_resolutions.is_empty():
		return _fallback_resolutions()
	return _supported_resolutions.duplicate()

func get_supported_resolutions() -> Array[Vector2i]:
	if _supported_resolutions.is_empty():
		return _fallback_resolutions()
	return _supported_resolutions.duplicate()

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
		request.set_width(_request_size.x).set_height(_request_size.y).set_frames_to_skip(0).set_rotation(90).set_grayscale(false)
		if request.has_method("set_auto_upright"):
			request.set_auto_upright(AUTO_UPRIGHT)
		if request.has_method("set_scale_width") and request.has_method("set_scale_height"):
			request.set_scale_width(_request_size.x).set_scale_height(_request_size.y)
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
	if _elapsed < 1.0 / _image_hz:
		return {}
	_elapsed = 0.0

	var image := _texture.get_image()
	if image == null or image.is_empty():
		_empty_image_count += 1
		_last_error = "empty image count=%d datatype=%d" % [_empty_image_count, _feed.get_datatype() if _feed != null else -1]
		return {}
	_empty_image_count = 0
	_last_image_size = image.get_size()

	if image.get_width() > _request_size.x:
		var target_height := int(round(float(image.get_height()) * float(_request_size.x) / float(image.get_width())))
		image.resize(_request_size.x, target_height, Image.INTERPOLATE_BILINEAR)

	var jpeg := image.save_jpg_to_buffer(JPEG_QUALITY)
	if jpeg.is_empty():
		_last_jpeg_size = 0
		_last_error = "empty JPEG buffer"
		return {}
	_last_jpeg_size = jpeg.size()

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
	if _elapsed < 1.0 / _image_hz:
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
	if image.get_width() > _request_size.x:
		var target_height := int(round(float(image.get_height()) * float(_request_size.x) / float(image.get_width())))
		image.resize(_request_size.x, target_height, Image.INTERPOLATE_BILINEAR)

	var jpeg: PackedByteArray = image.save_jpg_to_buffer(JPEG_QUALITY)
	if jpeg.is_empty():
		_last_jpeg_size = 0
		_last_error = "empty NativeCamera JPEG buffer"
		return {}
	_last_jpeg_size = jpeg.size()

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
		return "native camera active request=%dx%d last=%dx%d empty=%d error=%s" % [
			_request_size.x,
			_request_size.y,
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
		"last_jpeg_size": _last_jpeg_size,
		"empty_image_count": _empty_image_count,
		"last_error": _last_error
	}
	if _using_native:
		packet.merge({
			"backend": "NativeCameraPlugin",
			"native_has_permission": _native_camera.has_camera_permission() if _native_camera != null else false,
			"native_has_frame": _latest_native_frame != null,
			"request_size": [_request_size.x, _request_size.y],
			"image_hz": _image_hz,
			"auto_upright": AUTO_UPRIGHT,
			"supported_resolution_count": _supported_resolutions.size(),
			"supported_resolutions": _resolution_array(_supported_resolutions)
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

func _fallback_resolutions() -> Array[Vector2i]:
	return [
		Vector2i(1280, 720),
		Vector2i(1920, 1080),
		Vector2i(640, 480)
	]

func _compare_resolution_area_desc(a: Vector2i, b: Vector2i) -> bool:
	return a.x * a.y > b.x * b.y

func _resolution_array(resolutions: Array[Vector2i]) -> Array:
	var result := []
	for resolution in resolutions:
		result.append([resolution.x, resolution.y])
	return result
