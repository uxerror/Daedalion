## Utility script for fetching all flag names from CogitoQuest .tres files and SceneTree CogitoQuestUpdater instances.
@tool
extends Node

static var quest_files: Array[CogitoQuest] = []
static var quest_file_cache: Array[String] = []

## Fetch all flags present in the project using the current SceneTree.
## This operation will take some time depending on how many *.tres files
## are present in the project
static func fetch_all_flags(tree: SceneTree) -> Array:
	# Using a dict to squash the duplicate flag names into a set
	var dict: Dictionary[String, int] = {}
	for flag in get_all_updater_flags(tree):
		dict.set(flag, 1)
	for flag in get_all_quest_objective_flags():
		dict.set(flag, 1)
	# Remove any empty values from InventoryFlag
	dict.erase("")
	return dict.keys()

## Get all flag names defined (with duplicates) in CogitoQuestUpdater instances in the current scene.
static func get_all_updater_flags(tree: SceneTree) -> Array[String]:
	var flag_names: Array[String] = []
	var quest_updaters = tree.edited_scene_root.find_children("", "CogitoQuestUpdater")
	for updater in quest_updaters:
		for world_flag in updater.world_flag:
			flag_names.append(world_flag.flag_name)
	return flag_names

## Obtain every quest objective flag name defined (with duplicates) from a
## generated list of CogitoQuest filenames found on plugin load
static func get_all_quest_objective_flags() -> Array[String]:
	var flag_names: Array[String] = []
	load_from_quest_file_cache()
	for quest in quest_files:
		flag_names.append_array(quest.get_all_flag_names())
	return flag_names

## Load all CogitoQuest resource files from their cached file locations
static func load_from_quest_file_cache():
	quest_files = []
	for cached in quest_file_cache:
		quest_files.append(load(cached))

## Recursively find all files that match a CogitoQuest resource file. 
static func generate_file_cache(path: String):
	var dir = DirAccess.open(path)
	if DirAccess.get_open_error() == OK:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if dir.current_is_dir():
				generate_file_cache(dir.get_current_dir() +"/"+ file_name)
			else:
				if file_name.get_extension() != "tres":
					file_name = dir.get_next()
					continue
				var full_path = dir.get_current_dir() +"/"+ file_name
				if check_resource_type(full_path, "CogitoQuest"):
					quest_file_cache.append(full_path)

			file_name = dir.get_next()
	else:
		print("An error occurred when trying to access %s." % path)

## Check a *.tres resource type without using ResourceLoader. Open the file, read the first line
## and check it contains the expected type as a string
static func check_resource_type(file_name:String, expected_type:String) -> bool:
	# Quick file check, we can assume its probably not a CogitoQuest if its more than 128 KB in size
	# direct your complaints at HourOfOblivion if you prove me wrong
	if FileAccess.get_size(file_name) > 131072: return false
	var file = FileAccess.open(file_name, FileAccess.ModeFlags.READ)
	var text = file.get_line()
	# Wrap the expected type contains in quotes so you parse only that specific type
	return text.contains("\""+expected_type+"\"")
