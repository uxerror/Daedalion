extends GdUnitTestSuite

const DART := preload("res://addons/cogito/PackedScenes/Pickups/pickup_dart_cold.tscn")


func test_dart_supports_editor_aabb_preview() -> void:
	var dart: CogitoProjectile = auto_free(DART.instantiate())
	var script: Script = dart.get_script()
	(
		assert_bool(script.is_tool())
		. override_failure_message("The editor must run the dart's inherited AABB preview setter.")
		. is_true()
	)
