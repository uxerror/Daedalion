@tool
@icon("res://addons/cogito/Assets/Graphics/Editor/Icon_CogitoObject.svg")
extends CogitoObject
## Derived from CogitoObject, this class handles additional information for projectiles like lifespan, damage, destroy_on_impact. Some of these are inherited from the Wieldable that spawns this projectile.
class_name CogitoProjectile

# Lifespan is being set by the Lifespan timer.
@onready var lifespan = $Lifespan
# Damage is being set by the wieldable.
var damage_amount : int = 0

## Determine what happens if the projectile hits something. Keep this false for stuff like Arrows. True for stuff like bullets or rockets.
@export var destroy_on_impact : bool = false
## Sound that gets played when the projectile dies.
@export var sound_on_death : AudioStream
## Should the projectile stick to what it hits?
@export var stick_on_impact : bool = false
## Array of Scenes that will get spawned on parent position on death.
@export var spawn_on_death : Array[PackedScene] = []
## This prevents being able to auto pick up projectiles that have just been fired
@export_range(0.1, 3.0, 0.1, "or_greater") var pick_up_delay: float = 0.5
var can_pick_up: bool = false

@export_group("Element on Impact")
## Element applied to whatever the projectile hits (its CogitoProperties or element area). PHYSICAL = none.
@export var impact_element : CogitoProperties.Element = CogitoProperties.Element.PHYSICAL
## Element buildup applied on impact, in buildup_threshold units of the target (1.0 = exactly enough to change its state).
@export var impact_element_amount : float = 1.0
## Extra damage of impact_element dealt on impact. Scaled by the target's resistances. 0 = none.
@export var impact_damage : float = 0.0

## True once the impact element was applied, so a bouncing projectile applies it only once.
var _impact_element_applied : bool = false

var direction

func _ready():
	if Engine.is_editor_hint():
		return
	super()
	add_to_group("interactable")
	self.add_to_group("Persist") #Adding object to group for persistence
	find_interaction_nodes()
	find_cogito_properties()
	
	if lifespan:
		lifespan.timeout.connect(on_timeout)
		
	_pick_up_timer()


func _pick_up_timer() -> void:
	if lifespan and (lifespan as Timer).wait_time < pick_up_delay:
		# The projectile cannot be picked up before it dies, so don't create the timer
		return
	await get_tree().create_timer(pick_up_delay).timeout
	can_pick_up = true


func on_timeout():
	die()


## Checking collision event for property tags.
func _on_body_entered(collider: Node):
	_apply_impact_element(collider)
	
	if rigid_body and noise_magnitude_when_impacting > 0:
		var noise = ObjectNoise.new(show_noise_as_debug_mesh)
		noise.set_parameters(ObjectNoise.NoiseType.Impact, noise_magnitude_when_impacting, 0.5, noise_collision_layer)
		CogitoLevel.spawn_parent(self).add_child(noise)
	
	var collision_point = global_transform.origin
	var bullet_direction = self.linear_velocity.normalized()
	var player := CogitoLevel.local_player(self)
	if player:
		bullet_direction = (collision_point - player.get_global_transform().origin).normalized() ##This is hacky TODO needs to be fixed for Multiplayer support
	
	if stick_on_impact:
		self.linear_velocity = Vector3.ZERO
		self.angular_velocity = Vector3.ZERO
		stick_to_object(collider)
		
	if collider.has_signal("damage_received"):
		if( !collider.cogito_properties && !cogito_properties): # Case where neither projectile nor the object hit have properties defined.
			CogitoGlobals.debug_log(true, "CogitoProjectile", "Collider nor projectile have CogitoProperties, damaging as usual.")
			deal_damage(collider,bullet_direction, collision_point)
			return
		
		if( collider.cogito_properties && !cogito_properties): # Case were only collider has properties.
			CogitoGlobals.debug_log(true, "CogitoProjectile", "Collider has CogitoProperties, currently ignoring these and damaging as usual.")
			deal_damage(collider,bullet_direction, collision_point)

		if( !collider.cogito_properties && cogito_properties): # Case where only the projectile has properties defined.
			match cogito_properties.material_properties:
				CogitoProperties.MaterialProperties.SOFT:
					# Defining what happens if a soft projectile hits an object with no properties.
					CogitoGlobals.debug_log(true, "CogitoProjectile", "Soft projectile does no damage per default.")
					if destroy_on_impact:
						die()
					return
		
		if( collider.cogito_properties && cogito_properties): # Case where both projectile and the object hit have properties defined.
			if( cogito_properties.material_properties == CogitoProperties.MaterialProperties.SOFT && collider.cogito_properties.material_properties == CogitoProperties.MaterialProperties.SOFT):
				# When both objects are soft, damage the hit object.
				CogitoGlobals.debug_log(true, "CogitoProjectile", "Soft object hit, dealing damage.")
				deal_damage(collider,bullet_direction, collision_point)
			
			# Manually setting the reaction collider and calling reactions on object hit, skipping the reaction threshold time.
			collider.cogito_properties.reaction_collider = self
			collider.cogito_properties.check_for_systemic_reactions()
				
	else:
		if destroy_on_impact:
			die()



## Applies impact_element (and impact_damage) to the hit object, once per projectile.
func _apply_impact_element(collider: Node) -> void:
	if impact_element == CogitoProperties.Element.PHYSICAL or _impact_element_applied:
		return
	_impact_element_applied = true
	CogitoProperties.apply_element_to(collider, impact_element, impact_element_amount, self)
	if impact_damage > 0.0:
		CogitoProperties.deal_elemental_damage(collider, impact_damage, impact_element, self, self.linear_velocity.normalized(), global_position)


# Make the projectile stick to the object it hits using a pin joint
func stick_to_object(collider: Node):
	var joint = PinJoint3D.new()
	joint.node_a = self.get_path()
	joint.node_b = collider.get_path()

	var parent := CogitoLevel.spawn_parent(self, true)
	joint.position = parent.to_local(global_position) if parent is Node3D else global_position
	parent.add_child(joint)
	#self.linear_velocity = Vector3.ZERO
	#self.angular_velocity = Vector3.ZERO

func deal_damage(collider: Node,bullet_direction,bullet_position):
	# bullet_direction = Direction
	CogitoGlobals.debug_log(true, "CogitoProjectile", self.name + ": dealing damage amount " + str(damage_amount) + " on collider " + collider.name + " at " + str(bullet_position) + " in direction " + str(direction) )

	collider.damage_received.emit(damage_amount, self, bullet_direction,bullet_position)
	if destroy_on_impact:
		die()


func die():
	if sound_on_death:
		CogitoAudio.play_sound_3d_in(self, sound_on_death, global_position)
		
	for scene in spawn_on_death:
		if scene:
			var spawned_object = scene.instantiate()
			spawned_object.position = position
			CogitoLevel.spawn_parent(self).add_child(spawned_object)
			
	queue_free()
