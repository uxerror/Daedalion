extends GdUnitTestSuite


class Target:
	extends Node
	signal damage_received(amount: float, source: Node)
	var damage := 0.0


func test_airborne_damage_scales_with_speed_and_mass() -> void:
	var object: CogitoObject = auto_free(CogitoObject.new())
	object.rigid_body = RigidBody3D.new()
	object.add_child(object.rigid_body)
	object.rigid_body.mass = 3.0
	object.rigid_body.linear_velocity = Vector3(4.0, 0, 0)
	object.physics_frame_velocity_scalar = 4.0
	object.damage_dealt_when_airborne = 2.0
	object.self_damage_when_airborne = false
	var target: Target = auto_free(Target.new())
	target.damage_received.connect(func(amount: float, _source: Node): target.damage = amount)
	object._on_body_entered(target)
	assert_float(target.damage).is_equal(24.0)
