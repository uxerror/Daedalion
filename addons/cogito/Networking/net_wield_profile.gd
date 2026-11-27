@tool
extends RefCounted
## Read the authored weapon off-tree. Its solo input, animation callbacks and pools never start.

const EXPORT_META := "cogito_weapon_profile"
const RIFLE := preload("../Wieldables/wieldable_laser_rifle.gd")
const MELEE := preload("../Wieldables/wieldable_pickaxe.gd")
const PISTOL := preload("../Wieldables/wieldable_toy_pistol.gd")
const THROW := preload("../Wieldables/wieldable_throwable.gd")
const LIGHT := preload("../Wieldables/wieldable_flashlight.gd")
const DRINK := preload("../Wieldables/wieldable_consumable.gd")

var kind: StringName
var interval := 0.2
var equip_seconds := 0.0
var reload_seconds := 1.0
var drain := 0.0
var stamina := 0.0
var speed := 0.0
var ads_fov := 65.0
var projectiles: Array[PackedScene] = []
var effects: Array[ConsumableEffect] = []
var fire_sound: AudioStream
var reload_sound: AudioStream
var decal: PackedScene
var decal_texture: Texture2D
var impact_scene: PackedScene
var tracer: PackedScene
var equip_clip: StringName
var fire_clip: StringName
var reload_clip: StringName


## Build the simulation and presentation settings from a trusted local item definition.
func configure(item: WieldableItemPD) -> void:
	if not item.wieldable_scene:
		return
	var state := item.wieldable_scene.get_state()
	for index in state.get_node_property_count(0):
		if state.get_node_property_name(0, index) == "metadata/" + EXPORT_META:
			var fields: Dictionary = state.get_node_property_value(0, index)
			for field: String in fields:
				set(field, fields[field])
			_resolve_throw(item)
			return
	var instance := item.wieldable_scene.instantiate()
	var node := instance as CogitoWieldable
	if not node:
		instance.free()
		return
	read_authored(node)
	node.free()
	_resolve_throw(item)


func _resolve_throw(item: WieldableItemPD) -> void:
	if kind == &"throw" and not projectiles[0] and item.drop_scene:
		projectiles[0] = load(item.drop_scene)


## Read the definition at export time so the dedicated template never creates a viewmodel.
func read_authored(node: Node) -> void:
	var authored: Script = node.get_script()
	var player: AnimationPlayer
	var players := node.find_children("*", "AnimationPlayer", true, false)
	if not players.is_empty():
		player = players[0]
	equip_clip = node.anim_equip
	fire_clip = node.anim_action_primary
	reload_clip = node.anim_reload
	if player and player.has_animation(equip_clip):
		equip_seconds = player.get_animation(equip_clip).length
	if player and player.has_animation(fire_clip):
		interval = maxf(0.05, player.get_animation(fire_clip).length)
	if player and player.has_animation(reload_clip):
		reload_seconds = maxf(0.05, player.get_animation(reload_clip).length)
	if derives_from(authored, RIFLE):
		kind = &"rifle"
		interval = maxf(0.05, node.firing_delay)
		ads_fov = node.ads_fov
		decal = node.bullet_decal_prefab if node.decal_spawn else null
		decal_texture = node.decal_texture
		impact_scene = node.collision_scene
		tracer = node.laser_ray_prefab
	elif derives_from(authored, MELEE):
		kind = &"melee"
		stamina = node.stamina_cost if node.uses_stamina else 0
		fire_sound = node.swing_sound
	elif derives_from(authored, PISTOL):
		kind = &"pistol"
		ads_fov = node.ads_fov
		projectiles.assign(node.projectile_prefab)
		speed = node.projectile_velocity
	elif derives_from(authored, THROW):
		kind = &"throw"
		projectiles.append(node.projectile_override)
		speed = node.projectile_velocity
	elif derives_from(authored, LIGHT):
		kind = &"light"
		drain = node.drain_rate
		interval = maxf(0.05, node.toggle_cooldown)
		fire_sound = node.switch_sound
	elif derives_from(authored, DRINK):
		kind = &"drink"
		effects.assign(node.consumable_effects)
	if "sound_primary_use" in node:
		fire_sound = node.get("sound_primary_use")
	if "sound_reload" in node:
		reload_sound = node.get("sound_reload")


## Editor export uses placeholder instances for game scripts. Inspect the script hierarchy.
static func derives_from(authored: Script, base: Script) -> bool:
	while authored:
		if authored == base:
			return true
		authored = authored.get_base_script()
	return false
