class_name PlayerInput
extends Node
## Hardware input lives here. The controller only knows about commands.

@export_range(0.0001, 0.02, 0.0001) var mouse_sensitivity: float = 0.002
@export_range(10.0, 60.0) var send_rate: float = 30.0
@export var capture_mouse_on_start: bool = true

var movement_direction: Vector2 = Vector2.ZERO
var look_angles: Vector2 = Vector2.ZERO
var is_firing: bool = false
var is_aiming: bool = false
var _sequence: int = 0
var _send_elapsed: float = 0.0
var _has_focus: bool = true
var _configured: bool = false

@onready var player: Player = get_parent()


func configure(initial_look: Vector2) -> void:
	look_angles = initial_look
	_configured = true
	# Only this child is assigned to owner_peer_id by Player._enter_tree().
	# Remote avatars never read our keyboard or change mouse capture.
	var local: bool = is_multiplayer_authority() and player.is_local_player()
	set_process_unhandled_input(local)
	set_physics_process(local)
	if local and capture_mouse_on_start:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if not _configured or not is_multiplayer_authority():
		return
	if event.is_action_pressed("ToggleMouse"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
		clear_held_input()
		get_viewport().set_input_as_handled()
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion and player.is_alive():
		look_angles.x = wrapf(look_angles.x - event.relative.x * mouse_sensitivity, -PI, PI)
		look_angles.y = clampf(look_angles.y - event.relative.y * mouse_sensitivity, -Player.PITCH_LIMIT, Player.PITCH_LIMIT)
	if event.is_action_pressed("Respawn"):
		_send_action(Player.Action.RESPAWN)
	if not player.is_alive():
		return
	if event.is_action_pressed("Jump"):
		_send_action(Player.Action.JUMP)
	if event.is_action_pressed("Reload"):
		_send_action(Player.Action.RELOAD)
	if event.is_action_pressed("Shoot"):
		_send_action(Player.Action.FIRE)
	if event.is_action_pressed("Switch Firing Mode"):
		_send_action(Player.Action.SWITCH_FIRE_MODE)
	if event.is_action_pressed("Gun1"):
		_send_action(Player.Action.EQUIP_SLOT_1)
	if event.is_action_pressed("Gun2"):
		_send_action(Player.Action.EQUIP_SLOT_2)
	if event.is_action_pressed("Interact"):
		player.interactor.interact()


func _physics_process(delta: float) -> void:
	if not _configured or not is_multiplayer_authority():
		return
	var active: bool = _has_focus and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and player.is_alive()
	movement_direction = Input.get_vector("Left", "Right", "Forward", "Backwards") if active else Vector2.ZERO
	is_firing = active and Input.is_action_pressed("Shoot")
	is_aiming = active and Input.is_action_pressed("ADS")
	_send_elapsed += delta
	if _send_elapsed < 1.0 / send_rate:
		return
	_send_elapsed = 0.0
	_sequence += 1
	var sprint: bool = active and Input.is_action_pressed("Sprint")
	var ads: bool = is_aiming
	if multiplayer.is_server():
		player.submit_input(_sequence, player.life_epoch, movement_direction, look_angles, sprint, is_firing, ads)
	elif multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		player.submit_input.rpc_id(Player.SERVER_ID, _sequence, player.life_epoch, movement_direction, look_angles, sprint, is_firing, ads)


func _send_action(action: Player.Action) -> void:
	if multiplayer.is_server():
		player.request_action(action, player.life_epoch, look_angles)
	elif multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		player.request_action.rpc_id(Player.SERVER_ID, action, player.life_epoch, look_angles)


func reset_for_life(initial_look: Vector2) -> void:
	look_angles = initial_look
	clear_held_input()


func clear_held_input() -> void:
	movement_direction = Vector2.ZERO
	is_firing = false
	is_aiming = false
	_send_elapsed = 1.0 # Send stopped/new-life input on the next physics tick.


func _notification(what: int) -> void:
	if what != NOTIFICATION_APPLICATION_FOCUS_OUT and what != NOTIFICATION_APPLICATION_FOCUS_IN:
		return
	if not is_inside_tree() or not _configured or not is_multiplayer_authority():
		return
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_has_focus = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		clear_held_input()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_has_focus = true
