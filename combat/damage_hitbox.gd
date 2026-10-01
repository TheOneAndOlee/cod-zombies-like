class_name DamageHitbox
extends Area3D
## Optional weak-point collider. Give this Area a CollisionShape3D and put it on
## the hitbox physics layer. The camera ray must collide with areas on that layer.

@export var health_path: NodePath
@export var is_headshot: bool = true
## Non-head weak points use this multiplier; heads use the weapon's multiplier.
@export_range(0.0, 10.0) var damage_multiplier: float = 1.0


func get_health_component() -> HealthComponent:
	if not health_path.is_empty():
		return get_node_or_null(health_path) as HealthComponent
	var actor: Node = get_parent()
	while actor != null:
		for child: Node in actor.get_children():
			if child is HealthComponent:
				return child as HealthComponent
		actor = actor.get_parent()
	return null
