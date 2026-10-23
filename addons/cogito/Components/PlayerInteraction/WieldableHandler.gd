extends Node3D
class_name WieldableHandler
## Part of PlayerInteractionComponent: equips and swaps wieldables and passes the player's actions to them.
## The wieldable container is exported on PlayerInteractionComponent.

@onready var pic: PlayerInteractionComponent = get_parent()

var is_changing_wieldables: bool = false # Used to avoid any input acitons while wieldables are being swapped
# Various variables used for wieldable handling
var equipped_wieldable_item: WieldableItemPD = null
var equipped_wieldable_node: CogitoWieldable = null
var wieldable_was_on: bool = false
var is_wielding: bool:
	get: return equipped_wieldable_item != null
# Used to auto equip the last, or just selected, wieldable automatically after or while carrying
var wieldable_item_to_auto_equip: WieldableItemPD = null
var auto_equip_wieldable_after_carrying: bool = false
var primary_action_held: bool = false


func equip_wieldable(wieldable_item: WieldableItemPD):
	if wieldable_item != null:
		equipped_wieldable_item = wieldable_item #Set Inventory Item reference
		# Set Wieldable node reference
		var wieldable_node = wieldable_item.build_wieldable_scene()
		pic.wieldable_container.add_child(wieldable_node)
		equipped_wieldable_node = wieldable_node
		equipped_wieldable_node.set_ammo_type(equipped_wieldable_item.current_ammo_type)
		equipped_wieldable_node.item_reference = wieldable_item
		print("PIC: Found ", equipped_wieldable_item.name, " in wieldable node array: ", wieldable_node.name)
		wieldable_node.equip(pic)
		await get_tree().create_timer(wieldable_node.animation_player.current_animation_length).timeout
		is_changing_wieldables = false
		if is_instance_valid(wieldable_node) and wieldable_node == equipped_wieldable_node and wieldable_node.animation_player.is_playing():
			await wieldable_node.animation_player.animation_finished
		_apply_held_primary_action()
	else:
		is_changing_wieldables = false


func change_wieldable_to(next_wieldable: InventoryItemPD):
	is_changing_wieldables = true
	if equipped_wieldable_item != null:
		equipped_wieldable_item.is_being_wielded = false
		if equipped_wieldable_node != null:
			equipped_wieldable_node.unequip()
			if equipped_wieldable_node.animation_player.is_playing(): # Wait until unequip animation finishes.
				await get_tree().create_timer(equipped_wieldable_node.animation_player.current_animation_length).timeout
	equipped_wieldable_item = null
	if equipped_wieldable_node != null:
		equipped_wieldable_node.queue_free()
	equipped_wieldable_node = null
	equip_wieldable(next_wieldable)


func attempt_action_primary(is_released: bool):
	if is_changing_wieldables: # Block action if currently in the process of changing wieldables
		return
	if equipped_wieldable_node == null:
		print("Nothing equipped, but is_wielding was true. This shouldn't happen!")
		return

	equipped_wieldable_node.action_primary(equipped_wieldable_item, is_released)


func _apply_held_primary_action() -> void:
	if primary_action_held and Input.is_action_pressed("action_primary") and is_wielding and !pic.carrying.is_carrying:
		attempt_action_primary(false)


func attempt_action_secondary(is_released: bool):
	if is_changing_wieldables: # Block action if currently in the process of changing wieldables
		return
	if equipped_wieldable_node == null:
		print("Nothing equipped, but is_wielding was true. This shouldn't happen!")
		return
	else:
		equipped_wieldable_node.action_secondary(is_released)


func attempt_change_ammo():
	if equipped_wieldable_node: equipped_wieldable_node.change_ammo()


func attempt_reload():
	if equipped_wieldable_node: equipped_wieldable_node.reload()


# This gets a world space collision point of whatever the camera is pointed at, depending on the equipped wieldable range.
func get_camera_collision() -> Vector3:
	var viewport = get_viewport().get_visible_rect().size
	var camera = get_viewport().get_camera_3d()

	var ray_origin = camera.project_ray_origin(viewport/2)
	var ray_end = ray_origin + camera.project_ray_normal(viewport/2)*equipped_wieldable_item.wieldable_range

	var new_intersection = PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	new_intersection.exclude = [pic.player_rid]
	var intersection = get_world_3d().direct_space_state.intersect_ray(new_intersection)

	if not intersection.is_empty():
		var col_point = intersection.position
		return col_point
	else:
		return ray_end


func save():
	if equipped_wieldable_node and equipped_wieldable_node.has_method("toggle_on_off"):
		wieldable_was_on = equipped_wieldable_node.is_on
	var interaction_component_data = {
	"equipped_wieldable_item": equipped_wieldable_item,
	#"equipped_wieldable_node": equipped_wieldable_node,
	"is_wielding": is_wielding,
	"wieldable_was_on" : wieldable_was_on,
	}
	return interaction_component_data


func set_state():
	### Clearing out data from previous player state
	pic.updated_wieldable_data.emit(null, 0, null) # Clearing out wieldable HUD Data

	# Clearing out any instantiated wielable nodes
	var leftover_wieldable_nodes : Array[Node] = pic.wieldable_container.get_children()
	for leftover_wieldable_node in leftover_wieldable_nodes:
		leftover_wieldable_node.queue_free()

	# Clearing out equipped wieldable node and it's reference
	if equipped_wieldable_node != null:
		equipped_wieldable_node.queue_free()
	equipped_wieldable_node = null

	# Now equip saved wieldable item "from scratch"
	if is_wielding and equipped_wieldable_item:
		var temp_wieldable : WieldableItemPD = equipped_wieldable_item
		equipped_wieldable_item = null

		temp_wieldable.is_being_wielded = false
		temp_wieldable.use(pic.get_parent())

		if equipped_wieldable_node and equipped_wieldable_node.has_method("toggle_on_off") and wieldable_was_on:
			equipped_wieldable_node.toggle_flashlight(wieldable_was_on)


# Called by CarryableComponent just before carrying an object
func setup_wieldable_to_auto_equip(next_wieldable: WieldableItemPD = null) -> void:
	if equipped_wieldable_node != null:
		wieldable_item_to_auto_equip = equipped_wieldable_node.item_reference
	elif equipped_wieldable_item != null:
		wieldable_item_to_auto_equip = equipped_wieldable_item
	elif next_wieldable != null: # Called when using quickslots to assign a wieldable while carrying an object
		wieldable_item_to_auto_equip = next_wieldable
	elif wieldable_item_to_auto_equip == null:
		print("PIC: can't set up auto reequip as none of equipped_wieldable_node, equipped_wieldable_item, nor wieldable_to_auto_equip exist")
		return

	if equipped_wieldable_node != null:
		if equipped_wieldable_node.has_method("toggle_on_off"):
			wieldable_was_on = equipped_wieldable_node.is_on
		change_wieldable_to(null)

	auto_equip_wieldable_after_carrying = true


func auto_equip_last_wieldable() -> void:
	if auto_equip_wieldable_after_carrying and wieldable_item_to_auto_equip != null:
		if equipped_wieldable_node != null:
			equipped_wieldable_node.queue_free()
			await get_tree().create_timer(equipped_wieldable_node.animation_player.current_animation_length).timeout
			if equipped_wieldable_node != null:
				equipped_wieldable_node.free()
		equipped_wieldable_node = null
		equipped_wieldable_item = null
		is_changing_wieldables = false

		var temp_wieldable : WieldableItemPD = wieldable_item_to_auto_equip
		temp_wieldable.is_being_wielded = false
		# Failing to reequip the wieldable, such as in carry->drop->carry scenarios, preserves the reequip status until it succeeds
		if temp_wieldable.use(pic.get_parent()):
			auto_equip_wieldable_after_carrying = false

		if equipped_wieldable_node and equipped_wieldable_node.has_method("toggle_on_off") and wieldable_was_on:
			equipped_wieldable_node.is_on = !wieldable_was_on
			equipped_wieldable_node.toggle_on_off()


func update_equipped() -> void:
	if equipped_wieldable_item:
		equipped_wieldable_item.update_wieldable_data(pic)
