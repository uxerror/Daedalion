## Inspector helper plugin to show flag names in a dropdown when setting the flag_name
## property in either a CogitoFlag resource or CogitoQuestUpdater node.
## Adapted from the Godot State Charts event inspector plugin but with the refactor part trimmed out.
@tool
extends EditorInspectorPlugin

# The UI control for handling the flag list
const FlagDropdown = preload("flag_dropdown.gd")
# The utility script for fetching flags present in CogitoQuestUpdaters and CogitoQuest resource files
const FlagFetcher = preload("flag_fetcher.gd")

## Generate a filename cache for CogitoQuests on first load
func _init() -> void:
	FlagFetcher.generate_file_cache(".")

func _can_handle(_object) -> bool:
	# We support all objects in this example.
	return true

# Check the associated script is linked to cogito_quest_updater
# as well since CogitoQuestUpdater Area3Ds won't be recognised with 'is'
func inspected_type_check(object: Object):
	if not object: return false
	var script: Script = object.get_script()
	return object is BooleanFlag \
	or object is NumericFlag \
	or object is WorldFlag

# When a resource is saved add it to the fetcher resource path cache
func on_resource_saved(resource: Resource) -> void:
	if resource is CogitoQuest:
		var path = resource.resource_path
		# If the file cache has been generated from the first dropdown click, use
		if not FlagFetcher.quest_file_cache.is_empty() and not FlagFetcher.quest_file_cache.has(path):
			FlagFetcher.quest_file_cache.append(path)

func _parse_property(object, type, name, _hint_type, _hint_string, _usage_flags, _wide) -> bool:
	if inspected_type_check(object) and name == "flag_name" and type == TYPE_STRING:
		# Create an instance of the custom property editor and register
		# it to a specific property path.
		var dropdown = FlagDropdown.new(FlagFetcher)
		add_property_editor(name, dropdown)
		# Inform the editor to remove the default property editor for
		# this property type.
		return true
	else:
		return false
