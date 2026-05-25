extends RefCounted
class_name ComplementaryImu

var orientation: Quaternion = Quaternion.IDENTITY
var accel_weight: float = 0.03

func reset() -> void:
	orientation = Quaternion.IDENTITY

func update(gravity: Vector3, gyro: Vector3, dt: float) -> Quaternion:
	if dt <= 0.0:
		return orientation

	var speed := gyro.length()
	if speed > 0.0001:
		var delta := Quaternion(gyro / speed, speed * dt)
		orientation = (orientation * delta).normalized()

	if gravity.length() > 0.001:
		var measured_up := (-gravity).normalized()
		var current_up := orientation * Vector3.UP
		var axis := current_up.cross(measured_up)
		var axis_len := axis.length()
		if axis_len > 0.0001:
			var angle := asin(clampf(axis_len, -1.0, 1.0))
			var correction := Quaternion(axis / axis_len, angle * accel_weight)
			orientation = (correction * orientation).normalized()

	return orientation
