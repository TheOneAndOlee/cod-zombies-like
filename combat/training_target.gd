extends StaticBody3D
## Minimal PvE actor demonstrating the same health/hitbox interface as players.
## An enemy AI can replace this script without changing Gun or HealthComponent.

@export var team_id: int = 99
@export_range(0.1, 120.0) var respawn_delay: float = 5.0
@export var replicated_state: Dictionary = {}
@onready var health: HealthComponent = $Health

var respawn_remaining: float = 0.0
var _sequence: int = 0
var _last_sequence: int = -1
var _presented_dead: bool = false


func _enter_tree() -> void:
	set_multiplayer_authority(1)


func _ready() -> void:
	add_to_group("pve_enemies")
	health.died.connect(_on_died)
	MultiplayerUtils.session_started.connect(_reset_session)
	_update_presentation()


func _reset_session() -> void:
	# A new host starts a new snapshot sequence; discard the previous session.
	_sequence = 0
	_last_sequence = -1
	replicated_state = {}
	respawn_remaining = 0.0
	health.apply_network_state({"health": health.max_health})
	_update_presentation()


func _physics_process(delta: float) -> void:
	if multiplayer.is_server():
		if health.is_dead:
			respawn_remaining = maxf(0.0, respawn_remaining - delta)
			if respawn_remaining <= 0.0:
				health.server_reset()
		_sequence += 1
		replicated_state = {"sequence": _sequence, "health": health.capture_state(), "remaining": respawn_remaining}
	else:
		var sequence: int = int(replicated_state.get("sequence", -1))
		if sequence > _last_sequence:
			_last_sequence = sequence
			health.apply_network_state(replicated_state.get("health", {}))
			respawn_remaining = float(replicated_state.get("remaining", 0.0))
	_update_presentation()


func _on_died(_attacker_peer_id: int) -> void:
	if multiplayer.is_server():
		respawn_remaining = respawn_delay


func _update_presentation() -> void:
	var dead: bool = health.is_dead
	if dead != _presented_dead:
		_presented_dead = dead
		$CollisionShape3D.set_deferred("disabled", dead)
		$BodyHitbox/CollisionShape3D.set_deferred("disabled", dead)
		$HeadHitbox/CollisionShape3D.set_deferred("disabled", dead)
	$BodyMesh.visible = not dead
	$HeadMesh.visible = not dead
	$Label3D.text = "TARGET: %ds" % ceili(respawn_remaining) if dead else "PvE TARGET\n%d / %d HP" % [roundi(health.current_health), roundi(health.max_health)]
