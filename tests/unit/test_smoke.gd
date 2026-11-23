extends GdUnitTestSuite


func test_properties_scene_instantiates() -> void:
	var props: Node = auto_free(
		load("res://addons/cogito/Components/Properties/CogitoProperties.tscn").instantiate()
	)
	assert_object(props).is_not_null()
