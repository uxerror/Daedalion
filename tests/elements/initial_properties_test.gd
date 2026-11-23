extends GdUnitTestSuite

const PROPERTIES := preload("res://addons/cogito/Components/Properties/CogitoProperties.tscn")


class PoweredObject:
	extends Node3D
	var properties: CogitoProperties

	func _ready() -> void:
		properties.electric_on_ready = true


func test_parent_initializes_power_before_element_startup() -> void:
	var parent: PoweredObject = auto_free(PoweredObject.new())
	parent.properties = PROPERTIES.instantiate()
	parent.properties.elemental_properties = CogitoProperties.ElementalProperties.CONDUCTIVE
	parent.add_child(parent.properties)
	add_child(parent)
	await get_tree().process_frame
	assert_bool(parent.properties.is_electric).is_true()
