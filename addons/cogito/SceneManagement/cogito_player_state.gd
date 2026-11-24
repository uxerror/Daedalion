@abstract class_name CogitoPlayerState
extends Resource

@abstract func populate_player_data(player)
@abstract func populate_save_data(player, slot)

# What every player has, saved and loaded by save_common_data() and load_common_data().
@export var player_inventory : CogitoInventory
@export var player_quickslots : Array[InventorySlotPD]
@export var saved_wieldable_charges : Array
@export var player_position : Vector3
@export var player_rotation : Vector3
@export var player_attributes : Dictionary
@export var player_currencies : Dictionary
@export var world_dictionary : Dictionary
@export var interaction_component_state : Array
@export var quest_objective_states: Dictionary = {}
@export var player_active_quests : Array[CogitoQuest]
@export var player_active_quest_progression : Dictionary
@export var player_completed_quests : Array[CogitoQuest]
@export var player_failed_quests : Array[CogitoQuest]

@export var player_current_scene : String
@export var player_current_scene_path : String

#Saving some extra data for save game management/UI
@export var player_state_screenshot_file : String
@export var player_state_savetime : int
@export var player_state_slot_name : String


func write_state(slot: String) -> Error:
	return CogitoSceneManager.write_state_resource(self, CogitoSceneManager.player_file(slot))


## Saves what every player has: inventory, quick slots, quests, wieldable charges, attributes, currencies,
## the world dictionary, position and body rotation, the interaction component state, and the save slot info.
## Call it from populate_save_data() and add what is specific to the player controller.
func save_common_data(player, slot) -> void:
	self.player_inventory = player.inventory_data # Saving player inventory
	self.player_quickslots = player.inventory_data.assigned_quickslots # Saving assigned quickslots
	
	# Saving current quests to player state.
	self.player_active_quest_progression = player.saved_quest_progression.duplicate(true)
	player_active_quests = CogitoQuestManager.active.quests.duplicate()
	player_completed_quests = CogitoQuestManager.completed.quests.duplicate()
	player_failed_quests = CogitoQuestManager.failed.quests.duplicate()
	quest_objective_states.clear()
	for quest: CogitoQuest in player_active_quests + player_completed_quests + player_failed_quests:
		quest_objective_states[quest] = quest.capture_objectives()

	self.clear_saved_wieldable_charges()
	for item_slot in player.inventory_data.inventory_slots:
		if item_slot and item_slot.inventory_item and item_slot.inventory_item.has_method("update_wieldable_data"): # Checking for wieldables.
			var item_save_data = item_slot.inventory_item.save()
			self.append_saved_wieldable_charges(item_save_data)
			CogitoGlobals.debug_log(true,"CSM","Saved charge for " + str(item_slot.inventory_item) )
	
	self.player_current_scene = CogitoSceneManager._current_scene_name
	CogitoGlobals.debug_log(true,"CSM","Save_player_state(): setting player_current_scene to " + CogitoSceneManager._current_scene_name)
	self.player_current_scene_path = CogitoSceneManager._current_scene_path
	self.player_position = player.global_position
	self.player_rotation = player.body.global_rotation
	
	## New way of saving attributes:
	self.clear_saved_attribute_data()
	for attribute in player.player_attributes:
		var cur_value
		if !player.player_attributes[attribute].dont_save_current_value:
			cur_value = player.player_attributes[attribute].value_current
		else:
			cur_value = 0
		var max_value = player.player_attributes[attribute].value_max
		var attribute_data := Vector2(cur_value, max_value)
		self.add_player_attribute_to_state_data(attribute, attribute_data)
	
	self.clear_saved_currency_data()
	for currency in player.player_currencies:
		var cur_value
		if !player.player_currencies[currency].dont_save_current_value:
			cur_value = player.player_currencies[currency].value_current
		else:
			cur_value = 0
		var max_value = player.player_currencies[currency].value_max
		var currency_data := Vector2(cur_value, max_value)
		self.add_player_currency_to_state_data(currency, currency_data)
	
	## Saving world dictionary
	var local_dict_copy : Dictionary = CogitoSceneManager._current_world_dict.duplicate(true)
	self.clear_world_dictionary()
	for entry in local_dict_copy:
		CogitoGlobals.debug_log(true,"CSM", "World Dict: attemtping to save key: " + str(entry) )
		self.add_to_world_dictionary(entry, local_dict_copy[entry])

	## Getting time of saving
	self.player_state_savetime = int(Time.get_unix_time_from_system())
	self.player_state_slot_name = slot

	# Writing the state from current player interaction component:
	var current_player_interaction_component = player.player_interaction_component
	self.clear_saved_interaction_component_state()
	self.add_interaction_component_state_data_to_array(current_player_interaction_component.save())


## Counterpart of save_common_data(). Call it first in populate_player_data().
func load_common_data(player) -> void:
	if player_inventory:
		player.inventory_data = player_inventory
	var inventory: CogitoInventory = player.inventory_data
	var items := _restore_inventory(inventory) if inventory else {}

	player.saved_quest_progression = player_active_quest_progression.duplicate(true)
	CogitoQuestManager.restore_quests(self)

	for key: String in player_attributes:
		var attribute: CogitoAttribute = player.player_attributes.get(key)
		if attribute:
			var values: Vector2 = player_attributes[key]
			attribute.restore_attribute(values.x, values.y)
	var health: CogitoAttribute = player.player_attributes.get("health")
	player.is_dead = health != null and health.value_current <= 0.0
	for key: String in player_currencies:
		var currency: CogitoCurrency = player.player_currencies.get(key)
		if currency:
			var values: Vector2 = player_currencies[key]
			currency.set_currency(values.x, values.y)

	player.global_position = player_position
	player.body.global_rotation = player_rotation
	if inventory:
		inventory.force_inventory_update()
	if player.player_interaction_component:
		_restore_interaction(player.player_interaction_component, items)


func _restore_interaction(interaction: PlayerInteractionComponent, items: Dictionary) -> void:
	for entry: Variant in interaction_component_state:
		if not entry is Dictionary:
			continue
		for key: String in entry:
			if key != "equipped_wieldable_item" and key != "is_wielding":
				interaction.set(key, entry[key])
		var item := entry.get("equipped_wieldable_item") as WieldableItemPD
		if not items.has(item) or not item.wieldable_scene or not entry.get("is_wielding", true):
			item = null
		interaction.equipped_wieldable_item = item
		interaction.set_state.call_deferred()


func _restore_inventory(inventory: CogitoInventory) -> Dictionary:
	var items := {}
	for i in inventory.inventory_slots.size():
		var stack := inventory.inventory_slots[i]
		if stack and stack.inventory_item:
			items[stack.inventory_item] = true
		else:
			inventory.inventory_slots[i] = null
	inventory.assigned_quickslots = player_quickslots.duplicate()
	for i in inventory.assigned_quickslots.size():
		var stack := inventory.assigned_quickslots[i]
		if stack and (not stack.inventory_item or not inventory.inventory_slots.has(stack)):
			inventory.assigned_quickslots[i] = null
	for entry: Variant in saved_wieldable_charges:
		if not entry is Dictionary:
			continue
		var item := entry.get("resource") as WieldableItemPD
		if item and items.has(item):
			item.restore_charges(entry)
	return items


func add_player_attribute_to_state_data(name: String, attribute_data:Vector2):
	player_attributes[name] = attribute_data


func clear_saved_attribute_data():
	player_attributes.clear()


# Functions for currencies
func add_player_currency_to_state_data(name: String, currency_data:Vector2):
	player_currencies[name] = currency_data


func clear_saved_currency_data():
	player_currencies.clear()


# Functions for world dictionary
func add_to_world_dictionary(world_property_name: String, world_property_data):
	if world_dictionary.has(world_property_name):
		world_dictionary[world_property_name] = world_property_data
		CogitoGlobals.debug_log(true, "CogitoPlayerState", "world dict key found and value saved: " + str(world_property_name) + " " + str(world_property_data) )
	else:
		world_dictionary.get_or_add(world_property_name)
		world_dictionary[world_property_name] = world_property_data
		CogitoGlobals.debug_log(true, "CogitoPlayerState", "world dict key not found. Added and value saved: " + str(world_property_name) + " " + str(world_property_data) )


func add_to_active_quest_flags(quest_name: String, flags: Dictionary):
	player_active_quest_progression.get_or_add(quest_name)
	player_active_quest_progression[quest_name] = flags
	CogitoGlobals.debug_log(true, "CogitoPlayerState", "Saved dictionary flags: " + str(quest_name) + " " + str(flags) )


func clear_world_dictionary():
	world_dictionary.clear()


func add_interaction_component_state_data_to_array(state_data):
	interaction_component_state.append(state_data)


func clear_saved_interaction_component_state():
	interaction_component_state.clear()


func append_saved_wieldable_charges(saved_item_data):
	saved_wieldable_charges.append(saved_item_data)


func clear_saved_wieldable_charges():
	saved_wieldable_charges.clear()
