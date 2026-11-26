extends RefCounted
## Read the authored weapon off-tree. Its solo input, animation callbacks and pools never start.

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
	var instance := item.wieldable_scene.instantiate()
	var node := instance as CogitoWieldable
	if not node:
		instance.free()
		return
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
	if node is RIFLE:
		kind = &"rifle"
		interval = maxf(0.05, node.firing_delay)
		ads_fov = node.ads_fov
		decal = node.bullet_decal_prefab if node.decal_spawn else null
		decal_texture = node.decal_texture
		impact_scene = node.collision_scene
		tracer = node.laser_ray_prefab
	elif node is MELEE:
		kind = &"melee"
		stamina = node.stamina_cost if node.uses_stamina else 0
		fire_sound = node.swing_sound
	elif node is PISTOL:
		kind = &"pistol"
		ads_fov = node.ads_fov
		projectiles.assign(node.projectile_prefab)
		speed = node.projectile_velocity
	elif node is THROW:
		kind = &"throw"
		var scene: PackedScene = node.projectile_override
		if not scene and item.drop_scene:
			scene = load(item.drop_scene)
		projectiles.append(scene)
		speed = node.projectile_velocity
	elif node is LIGHT:
		kind = &"light"
		drain = node.drain_rate
		interval = maxf(0.05, node.toggle_cooldown)
		fire_sound = node.switch_sound
	elif node is DRINK:
		kind = &"drink"
		effects.assign(node.consumable_effects)
	if "sound_primary_use" in node:
		fire_sound = node.get("sound_primary_use")
	if "sound_reload" in node:
		reload_sound = node.get("sound_reload")
	node.free()
