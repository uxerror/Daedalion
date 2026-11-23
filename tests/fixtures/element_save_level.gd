extends Node3D
## Rebuilds the same miniature level before and after loading a scene state.

const FIXTURES := preload("res://tests/fixtures/element_fixtures.gd")
const PROPS := preload("res://addons/cogito/Components/Properties/CogitoProperties.tscn")
const CRATE := preload(
	"res://addons/cogito/DemoScenes/DemoPrefabs/ElementStands/element_crate.tscn"
)
const F = CogitoProperties.ElementalProperties


func _add_to_level(node: Node, parent: Node = null) -> Node:
	(parent if parent else self).add_child(node)
	node.owner = self
	return node


func _add_properties_body(
	body_name: String, flags: int, pos: Vector3, settings := {}
) -> CogitoProperties:
	var body := FIXTURES.Holder.new()
	body.name = body_name
	body.position = pos
	_add_to_level(body)
	var original: CogitoProperties = PROPS.instantiate()
	original.elemental_properties = flags
	original.is_logging = false
	for key in settings:
		original.set(key, settings[key])
	body.cogito_properties = original
	_add_to_level(original, body)
	return original


func populate() -> void:
	var crate: Node3D = CRATE.instantiate()
	crate.name = "Crate"
	crate.position = Vector3(0, 200, 0)
	_add_to_level(crate)
	var crate2: Node3D = CRATE.instantiate()
	crate2.name = "Crate2"
	crate2.position = Vector3(10, 200, 0)
	_add_to_level(crate2)
	crate2.get_node("CogitoProperties").make_flammable()
	crate2.get_node("CogitoProperties").fuel = 0.3
	crate2.get_node("CogitoProperties").fuel_remaining = 0.3
	crate2.get_node("CogitoProperties").burn_out_result = CogitoProperties.BurnOutResult.DESTROY
	_add_properties_body("Stump", F.FLAMMABLE, Vector3(20, 200, 0))
	_add_properties_body(
		"Bush",
		F.FLAMMABLE,
		Vector3(30, 200, 0),
		{"fuel": 0.3, "burn_out_result": CogitoProperties.BurnOutResult.DESTROY}
	)
	_add_properties_body("Torch", F.FLAMMABLE, Vector3(40, 200, 0), {"ignite_on_ready": true})
	var area := CogitoElementArea.new()
	area.name = "Campfire"
	area.collision_mask = 0
	area.position = Vector3(50, 200, 0)
	_add_to_level(area)
	for npc_name in ["NPC", "NPC2"]:
		var npc: CogitoNPC = FIXTURES.make_npc()
		npc.name = npc_name
		npc.position = Vector3(60 if npc_name == "NPC" else 70, 0.1, 100)
		_add_to_level(npc)
	CogitoPersistentId.stamp_level(self)
