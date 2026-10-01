class_name HealthComponent
extends Node
## Add to a player or an AI enemy. Only server code can change gameplay health.
## The actor's snapshot calls capture_state/apply_network_state for replication.

signal health_changed(current: float, maximum: float)
signal damaged(amount: float, attacker_peer_id: int)
signal died(attacker_peer_id: int)

@export_range(1.0, 100000.0) var max_health: float = 100.0
@export var friendly_fire: bool = false
## Used for AI without a team_id property. -1 means free-for-all / no team.
@export var team_id: int = -1
@export_range(0.0, 5.0) var hurt_duration: float = 0.2

var current_health: float = 100.0
var is_dead: bool = false
var is_hurt: bool:
	get:
		return hurt_time_left > 0.0 and not is_dead
var hurt_time_left: float = 0.0
var last_attacker_peer_id: int = 0


func _ready() -> void:
	current_health = maxf(1.0, max_health)


func _physics_process(delta: float) -> void:
	if multiplayer.is_server():
		hurt_time_left = maxf(0.0, hurt_time_left - delta)


func server_take_damage(amount: float, attacker_peer_id: int = 0, attacker_team: int = -1) -> bool:
	# This is deliberately a normal method, never an any_peer damage RPC.
	if not multiplayer.is_server() or is_dead or not is_finite(amount) or amount <= 0.0:
		return false
	var target_team: int = _get_target_team()
	if not friendly_fire and attacker_team >= 0 and target_team == attacker_team:
		return false
	var previous_health: float = current_health
	current_health = maxf(0.0, current_health - amount)
	is_dead = current_health <= 0.0
	hurt_time_left = hurt_duration
	last_attacker_peer_id = attacker_peer_id
	health_changed.emit(current_health, max_health)
	damaged.emit(previous_health - current_health, attacker_peer_id)
	if is_dead:
		died.emit(attacker_peer_id)
	return true


func server_reset() -> void:
	if not multiplayer.is_server():
		return
	current_health = maxf(1.0, max_health)
	is_dead = false
	hurt_time_left = 0.0
	last_attacker_peer_id = 0
	health_changed.emit(current_health, max_health)


func capture_state() -> Dictionary:
	return {"health": current_health, "maximum": max_health,
		"hurt_time": hurt_time_left, "attacker": last_attacker_peer_id}


func apply_network_state(state: Dictionary) -> void:
	# Caller is Player's authority-only snapshot receiver.
	var previous_health: float = current_health
	var was_dead: bool = is_dead
	max_health = maxf(1.0, float(state.get("maximum", max_health)))
	current_health = clampf(float(state.get("health", current_health)), 0.0, max_health)
	hurt_time_left = maxf(0.0, float(state.get("hurt_time", 0.0)))
	last_attacker_peer_id = int(state.get("attacker", 0))
	is_dead = current_health <= 0.0
	if not is_equal_approx(previous_health, current_health):
		health_changed.emit(current_health, max_health)
	if current_health < previous_health:
		damaged.emit(previous_health - current_health, last_attacker_peer_id)
	if is_dead and not was_dead:
		died.emit(last_attacker_peer_id)


func _get_target_team() -> int:
	var actor: Node = get_parent()
	# PvP actors supply their team; simple PvE actors may use this component's team.
	for property: Dictionary in actor.get_property_list():
		if property.name == &"team_id":
			return int(actor.get("team_id"))
	return team_id
