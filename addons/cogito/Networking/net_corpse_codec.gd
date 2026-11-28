extends RefCounted
## Scene-order physical body transforms in a rigid frame centred on the hips.

const STRIDE := 16
const QUAT_RANGE := 0.7071067811865476


static func encode(bones: Array[PhysicalBone3D], root: Transform3D) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(STRIDE * bones.size())
	var inverse := root.affine_inverse()
	for i in bones.size():
		var local := inverse * bones[i].global_transform
		var offset := i * STRIDE
		for axis in 3:
			bytes.encode_s32(offset + 4 * axis, roundi(local.origin[axis] * 1000.0))
		bytes.encode_u32(offset + 12, _pack_rotation(local.basis.get_rotation_quaternion()))
	return bytes


static func _pack_rotation(rotation: Quaternion) -> int:
	var q := Vector4(rotation.x, rotation.y, rotation.z, rotation.w)
	var largest := 0
	for i in range(1, 4):
		if absf(q[i]) > absf(q[largest]):
			largest = i
	var bits := largest
	var sign_multiplier := signf(q[largest])
	for i in 4:
		if i != largest:
			var unit := q[i] * sign_multiplier / QUAT_RANGE
			bits = (bits << 10) | clampi(roundi((unit + 1.0) * 511.5), 0, 1023)
	return bits


static func decode(bytes: PackedByteArray) -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	for offset in range(0, bytes.size(), STRIDE):
		var position := Vector3.ZERO
		for axis in 3:
			position[axis] = bytes.decode_s32(offset + axis * 4) * 0.001
		var bits := bytes.decode_u32(offset + 12)
		var largest := bits >> 30
		var q := Vector4.ZERO
		for i in range(3, -1, -1):
			if i != largest:
				q[i] = ((bits & 1023) / 511.5 - 1.0) * QUAT_RANGE
				bits >>= 10
		q[largest] = sqrt(maxf(0, 1.0 - q.length_squared()))
		result.append(Transform3D(Basis(Quaternion(q.x, q.y, q.z, q.w)), position))
	return result
