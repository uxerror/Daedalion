extends CogitoElementArea
## Water volume: makes floating bodies float, soaks and douses everything inside and conducts electricity.
class_name FluidArea3D

@export var density: float = 1.0
@export var simulate_turbulence := true

@onready var time := 0.0
@onready var noise := FastNoiseLite.new()
var surface_height: float = 0.0

func _init() -> void:
	element = CogitoProperties.Element.WATER
	amount_per_second = 4.0
	conducts_shock = true
	shock_damage_per_second = 10.0


func _ready() -> void:
	super()
	surface_height = position.y
	for owner_id in get_shape_owners():
		var collision = shape_owner_get_owner(owner_id)
		if collision is CollisionShape3D:
			var shape: Shape3D = collision.shape
			if shape is BoxShape3D:
				var collision_top = Vector3(0.0, shape.size.y * 0.5, 0.0)
				surface_height += (collision.transform * collision_top).y
				break

	if network_replica:
		set_physics_process(false)
	body_entered.connect(body_enter)
	body_exited.connect(body_exit)


func apply_element_replica(active: bool, charged: bool, remaining: float) -> void:
	super(active, charged, remaining)
	set_physics_process(false)


func unbind_element_replica() -> void:
	super()
	set_physics_process(true)


func _physics_process(delta: float) -> void:
	time += delta


func body_enter(body: Node3D) -> void:
	if not network_replica and body.has_method("fluid_area_enter"):
		body.fluid_area_enter(self)


func body_exit(body: Node3D) -> void:
	if not network_replica and body.has_method("fluid_area_exit"):
		body.fluid_area_exit(self)


func get_height(pos: Vector3) -> float:
	return surface_height + 0.3 * noise.get_noise_3d(time * 2.0 + pos.x, pos.y, time * 5.0 + pos.z)	
