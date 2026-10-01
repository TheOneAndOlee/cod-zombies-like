extends Area3D
## Walk into this server-owned supply crate to replenish the equipped weapon.
## It stays in the scene while unavailable, making late-join state inexpensive.

@export_range(1, 1000) var ammo_amount: int = 60
@export_range(0.1, 120.0) var respawn_delay: float = 10.0
@export var replicated_state: Dictionary = {}

var active: bool = true
var respawn_remaining: float = 0.0
var _sequence: int = 0
var _last_sequence: int = -1


func _enter_tree() -> void:
	set_multiplayer_authority(1)


func _ready() -> void:
	MultiplayerUtils.session_started.connect(_reset_session)


func _reset_session() -> void:
	_sequence = 0
	_last_sequence = -1
	replicated_state = {}
	active = true
	respawn_remaining = 0.0


func _physics_process(delta: float) -> void:
	if multiplayer.is_server():
		if not active:
			respawn_remaining = maxf(0.0, respawn_remaining - delta)
			active = respawn_remaining <= 0.0
		if active:
			for body: Node3D in get_overlapping_bodies():
				if not body.has_method("is_alive") or not bool(body.call("is_alive")):
					continue
				var weapon := body.get_node_or_null("Head/Camera3D/Guns/Weapon") as Gun
				if weapon != null and weapon.server_add_ammo(ammo_amount) > 0:
					active = false
					respawn_remaining = respawn_delay
					break
		_sequence += 1
		replicated_state = {"sequence": _sequence, "active": active, "remaining": respawn_remaining}
	else:
		var sequence: int = int(replicated_state.get("sequence", -1))
		if sequence > _last_sequence:
			_last_sequence = sequence
			active = bool(replicated_state.get("active", true))
			respawn_remaining = float(replicated_state.get("remaining", 0.0))
	$Crate.visible = active
	$Label3D.text = "AMMO +%d" % ammo_amount if active else "AMMO: %ds" % ceili(respawn_remaining)
