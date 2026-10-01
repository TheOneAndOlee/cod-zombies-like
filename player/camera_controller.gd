extends Camera3D
## Presentation only. Keep the eye and ShootRay aligned on every peer.

@export var base_fov: float = 75.0
@export var ads_fov: float = 55.0
@export var sprint_fov: float = 82.0
@export var fov_response: float = 10.0

var _player: Player
var _recoil: float = 0.0


func _ready() -> void:
	set_process(false)


func setup(player: Player, local: bool) -> void:
	_player = player
	if local:
		make_current()
	else:
		clear_current(false)
	set_process(local)
	_player.gun.get_node("ViewModel").visible = local
	if local:
		player.gun.shot_fired.connect(_on_shot_fired)


func _process(delta: float) -> void:
	var ads: bool = _player.is_alive() and _player.input.is_aiming
	var target_fov: float = ads_fov if ads else (sprint_fov if _player.is_sprinting else base_fov)
	fov = lerpf(fov, target_fov, 1.0 - exp(-fov_response * delta))
	var recovery: float = maxf(1.0, _player.gun.properties.recoil_recovery_speed)
	_recoil = move_toward(_recoil, 0.0, recovery * delta)
	# Cosmetic recoil stays separate from server spread and aim.
	_player.gun.get_node("ViewModel").rotation.x = deg_to_rad(_recoil)


func _on_shot_fired(_origin: Vector3, _end: Vector3, _hit: bool) -> void:
	_recoil = minf(12.0, _recoil + _player.gun.properties.recoil_strength_y)
