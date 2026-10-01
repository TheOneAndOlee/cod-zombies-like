class_name Player
extends CharacterBody3D
## The server owns simulation. Only PlayerInput belongs to the controlling peer.

signal respawn_requested(player: Player)
signal points_changed(balance: int)
signal purchase_feedback(message: String, successful: bool)

enum Action { JUMP, RELOAD, FIRE, RESPAWN, SWITCH_FIRE_MODE, EQUIP_SLOT_1, EQUIP_SLOT_2 }
const SERVER_ID: int = 1
const PITCH_LIMIT: float = deg_to_rad(89.0)

@export_group("Identity")
## Set these in the spawner BEFORE adding the player to the tree.
@export var owner_peer_id: int = 1
@export var display_name: String = "Player"
## -1 means free-for-all; matching nonnegative teams share friendly-fire rules.
@export var team_id: int = -1
@export var allow_friendly_fire: bool = false

@export_group("Economy")
@export_range(0, 1000000) var starting_points: int = 500
@export_range(1, 100000000) var maximum_points: int = 999999
## Currency persists through respawn. A newly spawned match avatar starts fresh.
var points: int = 0

@export_group("Movement")
@export_range(0.1, 30.0) var walk_speed: float = 5.0
@export_range(0.1, 40.0) var sprint_speed: float = 8.0
@export_range(0.1, 100.0) var acceleration: float = 24.0
@export_range(0.1, 100.0) var deceleration: float = 30.0
@export_range(0.0, 1.0) var air_control: float = 0.3
@export_range(0.1, 30.0) var jump_velocity: float = 6.0
@export_range(0.0, 5.0) var gravity_scale: float = 1.0
@export var allow_shooting_while_sprinting: bool = false

@export_group("Networking")
@export_range(0.1, 2.0) var input_timeout: float = 0.35
@export_range(1.0, 40.0) var interpolation_speed: float = 18.0
@export_range(1, 300) var max_input_messages_per_second: int = 120
@export_range(1, 120) var max_actions_per_second: int = 30

@export_group("Respawn")
@export var auto_respawn: bool = true
@export_range(0.0, 60.0) var respawn_delay: float = 3.0
@export var fall_death_height: float = -30.0

## One atomic snapshot avoids mixing an old position with a new respawn epoch.
## Only StateSynchronizer's authority (the server) publishes this property.
@export var replicated_state: Dictionary = {}

@onready var input: PlayerInput = $PlayerInput
@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var gun: Gun = $Head/Camera3D/Guns/Weapon
@onready var health: HealthComponent = $Health
@onready var inventory: WeaponInventory = $Inventory
@onready var interactor: Node3D = $Head/Camera3D/ObjectInteractor
@onready var body_mesh: MeshInstance3D = $BodyMesh
@onready var body_shape: CollisionShape3D = $CollisionShape3D
@onready var body_hitbox: CollisionShape3D = $BodyHitbox/CollisionShape3D
@onready var head_hitbox: CollisionShape3D = $HeadHitbox/CollisionShape3D

var life_epoch: int = 0
var respawn_remaining: float = 0.0
var is_sprinting: bool = false
var is_aiming: bool = false
var _move_input: Vector2 = Vector2.ZERO
var _look_input: Vector2 = Vector2.ZERO # x = body yaw, y = head pitch in radians.
var _sprint_held: bool = false
var _fire_held: bool = false
var _jump_requested: bool = false
var _fire_requested: bool = false
var _reload_requested: bool = false
var _switch_requested: bool = false
var _last_input_sequence: int = -1
var _last_input_time: float = -100.0
var _input_budget: int = 0
var _action_budget: int = 0
var _budget_second: int = -1
var _snapshot_sequence: int = 0
var _last_snapshot_sequence: int = -1
var _has_snapshot: bool = false
var _target_position: Vector3 = Vector3.ZERO
var _target_look: Vector2 = Vector2.ZERO
var _spawn_transform: Transform3D
var _respawn_dispatched: bool = false
var _presented_dead: bool = false
var _gravity: float = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
var _last_purchase_request: int = -1
var _last_purchase_time: float = -100.0


func _enter_tree() -> void:
	# Transferring the whole Player would also transfer health and snapshots.
	set_multiplayer_authority(SERVER_ID)
	$PlayerInput.set_multiplayer_authority(owner_peer_id)


func _ready() -> void:
	add_to_group("players")
	_spawn_transform = global_transform
	_look_input = Vector2(rotation.y, 0.0)
	_target_position = global_position
	_target_look = _look_input
	health.friendly_fire = allow_friendly_fire
	health.died.connect(_on_died)
	inventory.server_initialize(gun)
	if multiplayer.is_server():
		points = clampi(starting_points, 0, maximum_points)
	var local: bool = is_local_player()
	body_mesh.visible = not local
	$HUD.visible = local
	input.configure(_look_input)
	camera.setup(self, local)
	if multiplayer.is_server():
		_publish_state()
	else:
		_read_state()


func is_local_player() -> bool:
	# Player itself is server-owned; its input ownership identifies the camera.
	return owner_peer_id == multiplayer.get_unique_id() and DisplayServer.get_name() != "headless"


func is_alive() -> bool:
	return is_instance_valid(health) and not health.is_dead


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		_read_state()
		return
	# All peers have this node, but only the server moves its collision body.
	if _seconds() - _last_input_time > input_timeout:
		_clear_held_input()
	rotation.y = _look_input.x
	head.rotation.x = _look_input.y
	if not is_alive():
		respawn_remaining = maxf(0.0, respawn_remaining - delta)
		if auto_respawn and respawn_remaining <= 0.0:
			_request_respawn()
	else:
		_simulate_movement(delta)
		if global_position.y < fall_death_height:
			health.server_take_damage(health.max_health)
		var can_fire: bool = allow_shooting_while_sprinting or not is_sprinting
		if not can_fire:
			gun.server_cancel_burst()
		gun.server_tick(delta, _fire_held and can_fire, _fire_requested and can_fire,
			_reload_requested, is_aiming, _switch_requested)
	_clear_actions()
	_update_death_presentation()
	_publish_state()


func _process(delta: float) -> void:
	if not multiplayer.is_server() and _has_snapshot:
		var blend: float = 1.0 - exp(-interpolation_speed * delta)
		global_position = global_position.lerp(_target_position, blend)
		if not is_local_player():
			rotation.y = lerp_angle(rotation.y, _target_look.x, blend)
			head.rotation.x = lerp_angle(head.rotation.x, _target_look.y, blend)
	# Immediate local view; server independently uses validated aim.
	if is_local_player() and is_alive():
		rotation.y = input.look_angles.x
		head.rotation.x = input.look_angles.y


func _simulate_movement(delta: float) -> void:
	is_sprinting = _sprint_held and not is_aiming and _move_input.y < -0.1
	var speed: float = sprint_speed if is_sprinting else walk_speed
	var mobility: float = gun.properties.mobility_penalty
	if is_aiming:
		mobility = gun.properties.ads_firing_mobility_penalty if _fire_held else gun.properties.ads_mobility_penalty
	elif _fire_held:
		mobility = gun.properties.hipfire_mobility_penalty
	speed *= clampf(mobility, 0.0, 1.0)
	var direction: Vector3 = Basis(Vector3.UP, _look_input.x) * Vector3(_move_input.x, 0.0, _move_input.y)
	var target: Vector3 = direction * speed
	var rate: float = acceleration if not _move_input.is_zero_approx() else deceleration
	if not is_on_floor():
		rate *= air_control
		velocity.y -= _gravity * gravity_scale * delta
	elif _jump_requested:
		velocity.y = jump_velocity
	velocity.x = move_toward(velocity.x, target.x, rate * delta)
	velocity.z = move_toward(velocity.z, target.z, rate * delta)
	move_and_slide()


## Continuous input can be dropped; each packet contains the full current state.
@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func submit_input(sequence: int, epoch: int, movement: Vector2, look: Vector2,
		sprint: bool, fire: bool, ads: bool) -> void:
	if not _valid_sender() or not _use_message_budget(false):
		return
	if epoch != life_epoch or not is_alive() or sequence <= _last_input_sequence:
		return
	if not movement.is_finite() or not look.is_finite():
		return
	_last_input_sequence = sequence
	_last_input_time = _seconds()
	_move_input = movement.limit_length(1.0)
	_look_input = Vector2(wrapf(look.x, -PI, PI), clampf(look.y, -PITCH_LIMIT, PITCH_LIMIT))
	_sprint_held = sprint
	_fire_held = fire
	is_aiming = ads


## Reliable requests avoid losing quick trigger taps, jumps and reloads.
## Permission to ASK is not permission to choose damage, origin or a victim.
@rpc("any_peer", "call_remote", "reliable", 0)
func request_action(action: int, epoch: int, look: Vector2) -> void:
	if not _valid_sender() or not _use_message_budget(true):
		return
	if epoch != life_epoch or not look.is_finite():
		return
	if action == Action.RESPAWN:
		if not is_alive() and respawn_remaining <= 0.0:
			_request_respawn()
		return
	if not is_alive():
		return
	match action:
		Action.JUMP:
			_jump_requested = true
		Action.RELOAD:
			_reload_requested = true
		Action.FIRE:
			_fire_requested = true
			_look_input = Vector2(wrapf(look.x, -PI, PI), clampf(look.y, -PITCH_LIMIT, PITCH_LIMIT))
		Action.SWITCH_FIRE_MODE:
			_switch_requested = true
		Action.EQUIP_SLOT_1:
			inventory.server_equip_slot(0)
		Action.EQUIP_SLOT_2:
			inventory.server_equip_slot(1)


func _valid_sender() -> bool:
	if not multiplayer.is_server():
		return false
	var sender: int = multiplayer.get_remote_sender_id()
	# Sender zero means a direct function call by the listen host/offline.
	return sender == owner_peer_id or (sender == 0 and owner_peer_id == SERVER_ID)


func _use_message_budget(action: bool) -> bool:
	var second: int = int(Time.get_ticks_msec() / 1000)
	if second != _budget_second:
		_budget_second = second
		_input_budget = 0
		_action_budget = 0
	if action:
		_action_budget += 1
		return _action_budget <= max_actions_per_second
	_input_budget += 1
	return _input_budget <= max_input_messages_per_second


func _on_died(_attacker_peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	velocity = Vector3.ZERO
	respawn_remaining = respawn_delay
	_respawn_dispatched = false
	_clear_held_input()
	_clear_actions()
	gun.server_cancel_actions()
	_update_death_presentation()
	_publish_state()


func _request_respawn() -> void:
	if _respawn_dispatched:
		return
	_respawn_dispatched = true
	if respawn_requested.has_connections():
		respawn_requested.emit(self)
	else:
		server_respawn(_spawn_transform)


## Only server game rules/spawner call this. It is deliberately NOT an RPC.
func server_respawn(spawn_transform: Transform3D) -> void:
	if not multiplayer.is_server():
		return
	life_epoch += 1
	global_transform = spawn_transform
	velocity = Vector3.ZERO
	_look_input = Vector2(rotation.y, 0.0)
	head.rotation.x = 0.0
	_last_input_sequence = -1
	_last_input_time = -100.0
	_clear_held_input()
	_clear_actions()
	inventory.server_reset_for_respawn()
	health.server_reset()
	respawn_remaining = 0.0
	_respawn_dispatched = false
	input.reset_for_life(_look_input)
	_update_death_presentation()
	_publish_state()


func _clear_held_input() -> void:
	_move_input = Vector2.ZERO
	_sprint_held = false
	_fire_held = false
	is_aiming = false
	is_sprinting = false


func _clear_actions() -> void:
	_jump_requested = false
	_fire_requested = false
	_reload_requested = false
	_switch_requested = false


func _publish_state() -> void:
	_snapshot_sequence += 1
	replicated_state = {
		"sequence": _snapshot_sequence, "epoch": life_epoch,
		"position": global_position, "look": _look_input, "velocity": velocity,
		"health": health.capture_state(), "weapon": gun.capture_state(),
		"inventory": inventory.capture_state(), "points": points, "display_name": display_name,
		"sprinting": is_sprinting, "aiming": is_aiming,
		"respawn_remaining": respawn_remaining,
	}


func _read_state() -> void:
	if replicated_state.is_empty():
		return
	var sequence: int = int(replicated_state.get("sequence", -1))
	if sequence <= _last_snapshot_sequence:
		return
	_last_snapshot_sequence = sequence
	var epoch: int = int(replicated_state["epoch"])
	_target_position = replicated_state["position"]
	_target_look = replicated_state["look"]
	velocity = replicated_state["velocity"]
	if not _has_snapshot or epoch != life_epoch:
		# Respawns teleport instead of interpolating through the map.
		global_position = _target_position
		rotation.y = _target_look.x
		head.rotation.x = _target_look.y
		input.reset_for_life(_target_look)
	life_epoch = epoch
	_has_snapshot = true
	health.apply_network_state(replicated_state["health"])
	inventory.apply_network_state(replicated_state.get("inventory", {}))
	gun.apply_network_state(replicated_state["weapon"])
	display_name = str(replicated_state.get("display_name", display_name))
	var balance: int = int(replicated_state.get("points", points))
	if points != balance:
		points = balance
		points_changed.emit(points)
	is_sprinting = bool(replicated_state["sprinting"])
	is_aiming = bool(replicated_state["aiming"])
	respawn_remaining = float(replicated_state["respawn_remaining"])
	_update_death_presentation()


func _update_death_presentation() -> void:
	var dead: bool = not is_alive()
	if dead == _presented_dead:
		return
	_presented_dead = dead
	body_shape.set_deferred("disabled", dead)
	body_hitbox.set_deferred("disabled", dead)
	head_hitbox.set_deferred("disabled", dead)
	body_mesh.visible = not dead and not is_local_player()
	if dead:
		input.clear_held_input()


func _seconds() -> float:
	return Time.get_ticks_msec() / 1000.0


func server_add_points(amount: int) -> int:
	# Normal method, never an any_peer RPC: only trusted server game rules pay out.
	if not multiplayer.is_server() or amount <= 0:
		return 0
	var accepted: int = mini(amount, maxi(0, maximum_points - points))
	points += accepted
	if accepted > 0:
		points_changed.emit(points)
	return accepted


func server_spend_points(amount: int) -> bool:
	if not multiplayer.is_server() or amount < 0 or points < amount:
		return false
	points -= amount
	points_changed.emit(points)
	return true


func server_accept_purchase_request(request_id: int, epoch: int) -> bool:
	# All shops share this per-player guard. Replaying a packet at another shop
	# cannot repeat the transaction, and old-life packets cannot buy after respawn.
	if not multiplayer.is_server() or epoch != life_epoch or request_id <= _last_purchase_request:
		return false
	if request_id < 1:
		return false
	_last_purchase_request = request_id
	if _seconds() - _last_purchase_time < 0.25:
		return false
	_last_purchase_time = _seconds()
	return true


func server_publish_state() -> void:
	if multiplayer.is_server():
		_publish_state()


func server_purchase_feedback(message: String, successful: bool) -> void:
	if not multiplayer.is_server():
		return
	if owner_peer_id == SERVER_ID:
		_receive_purchase_feedback(message, successful)
	elif multiplayer.get_peers().has(owner_peer_id):
		_receive_purchase_feedback.rpc_id(owner_peer_id, message, successful)


@rpc("authority", "call_local", "reliable", 0)
func _receive_purchase_feedback(message: String, successful: bool) -> void:
	# This only displays a server result. It never changes points or inventory.
	purchase_feedback.emit(message, successful)
