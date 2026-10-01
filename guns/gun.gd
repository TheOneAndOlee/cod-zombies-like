class_name Gun
extends Node3D
## Server-owned hitscan weapon. PlayerInput requests buttons; Player calls
## server_tick after moving and applying the validated camera orientation.

signal ammo_changed(magazine: int, reserve: int)
signal shot_fired(origin: Vector3, end: Vector3, hit: bool)
signal reload_changed(reloading: bool)
signal firing_mode_changed(mode: int)

@export var properties: Gun_Properties
@export var hitscan_ray_path: NodePath = ^"../ShootRay"
## Optional visual muzzle. Damage always traces from the camera's ShootRay.
@export var muzzle: Node3D
@export_range(1.0, 3000.0) var max_range: float = 150.0

var magazine_ammo: int = 0
var reserve_ammo: int = 0
var current_firing_type: Gun_Properties.FIRE_TYPE = Gun_Properties.FIRE_TYPE.FULL_AUTO
var is_reloading: bool = false
var cooldown_left: float = 0.0
var reload_time_left: float = 0.0
var burst_shots_left: int = 0

var _ray: RayCast3D
var _player: Node
var _random := RandomNumberGenerator.new()
var _custom_model: Node
var _scored_targets: Dictionary = {}


func _ready() -> void:
	if properties == null:
		properties = Gun_Properties.new()
	_ray = get_node_or_null(hitscan_ray_path) as RayCast3D
	_player = _find_player()
	_random.randomize()
	if _ray == null:
		push_error("Gun needs a camera RayCast3D at " + str(hitscan_ray_path))
	else:
		_ray.collide_with_areas = true
		_ray.collide_with_bodies = true
		# Exclude the body AND its head Areas to prevent shooting yourself.
		if _player != null:
			_exclude_actor_colliders(_player)
	_initialize_ammunition()
	max_range = properties.shot_range
	_refresh_view_model()


func set_weapon_properties(configuration: Gun_Properties) -> void:
	# Clients use only a locally approved catalog resource from a server snapshot.
	if configuration == null or configuration == properties:
		return
	properties = configuration
	max_range = properties.shot_range
	_refresh_view_model()


func server_equip_weapon(configuration: Gun_Properties, ammo_state: Dictionary, use_swap_delay: bool = true) -> void:
	if not multiplayer.is_server() or configuration == null:
		return
	var remaining_cooldown: float = cooldown_left
	var swap_delay: float = maxf(0.0, properties.swap_from_time) + maxf(0.0, configuration.swap_to_time)
	server_cancel_actions()
	set_weapon_properties(configuration)
	apply_network_state(ammo_state)
	# Cooldown belongs to the shared Gun node. Switching cannot reset a shot timer.
	cooldown_left = maxf(remaining_cooldown, swap_delay if use_swap_delay else 0.0)


func _refresh_view_model() -> void:
	var view_model := get_node_or_null("ViewModel") as Node3D
	if view_model == null:
		return
	if is_instance_valid(_custom_model):
		view_model.remove_child(_custom_model)
		_custom_model.queue_free()
		_custom_model = null
	for child: Node in view_model.get_children():
		if child is GeometryInstance3D:
			(child as GeometryInstance3D).visible = properties.model == null
	if properties.model != null:
		_custom_model = properties.model.instantiate()
		view_model.add_child(_custom_model)


func server_tick(delta: float, trigger_held: bool, trigger_pressed: bool,
		reload_pressed: bool, aim_down_sights: bool, switch_mode_pressed: bool = false) -> void:
	# Root Player and Gun stay server-owned, including on the host's own avatar.
	if not multiplayer.is_server():
		return
	if _player == null or not bool(_player.call("is_alive")):
		server_cancel_actions()
		return
	cooldown_left = maxf(0.0, cooldown_left - delta)
	# Avoid an extra physics tick from tiny floating-point remainders (600 RPM).
	if cooldown_left < 0.00001:
		cooldown_left = 0.0
	if is_reloading:
		reload_time_left = maxf(0.0, reload_time_left - delta)
		if reload_time_left <= 0.0:
			_finish_reload()
		else:
			return
	if switch_mode_pressed:
		_switch_firing_mode()
	if reload_pressed:
		_start_reload()
	if is_reloading:
		return
	if current_firing_type == Gun_Properties.FIRE_TYPE.BURST:
		if trigger_pressed and burst_shots_left == 0 and cooldown_left <= 0.0:
			burst_shots_left = maxi(1, properties.bullets_per_burst)
	var wants_shot: bool = false
	match current_firing_type:
		Gun_Properties.FIRE_TYPE.FULL_AUTO:
			# Reliable presses preserve a quick tap between continuous-input packets.
			wants_shot = trigger_held or trigger_pressed
		Gun_Properties.FIRE_TYPE.SEMI_AUTO:
			wants_shot = trigger_pressed
		Gun_Properties.FIRE_TYPE.BURST:
			wants_shot = burst_shots_left > 0
	if not wants_shot or cooldown_left > 0.0:
		return
	if magazine_ammo <= 0:
		burst_shots_left = 0
		if properties.auto_reload_when_empty:
			_start_reload()
		return
	_fire_hitscan(aim_down_sights)


func _fire_hitscan(aim_down_sights: bool) -> void:
	if _ray == null:
		return
	magazine_ammo -= 1
	cooldown_left = 60.0 / maxf(1.0, properties.fire_rate)
	if burst_shots_left > 0:
		burst_shots_left -= 1
		if burst_shots_left == 0:
			cooldown_left += maxf(0.0, properties.burst_pause)
	ammo_changed.emit(magazine_ammo, reserve_ammo)
	var spread: float = properties.ads_spread_degrees if aim_down_sights else properties.hip_spread_degrees
	var origin: Vector3 = _ray.global_position
	var destination: Vector3 = origin
	var hit: bool = false
	_scored_targets.clear()
	for pellet_index: int in range(clampi(properties.pellets_per_shot, 1, 32)):
		# Sample a disk rather than a square so spread has no diagonal bias.
		var radius: float = tan(deg_to_rad(clampf(spread, 0.0, 45.0))) * sqrt(_random.randf())
		var angle: float = _random.randf_range(0.0, TAU)
		var direction := Vector3(cos(angle) * radius, sin(angle) * radius, -1.0).normalized()
		_ray.target_position = direction * maxf(1.0, max_range)
		_ray.force_raycast_update()
		if pellet_index == 0:
			destination = _ray.get_collision_point() if _ray.is_colliding() else _ray.to_global(_ray.target_position)
		if _ray.is_colliding():
			hit = true
			_apply_hit(_ray.get_collider())
	# One visual/audio/recoil event per trigger, even for a multi-pellet shotgun.
	# Only approved shots produce effects. No client sends a hit point or damage.
	_play_shot(origin, destination, hit)
	if multiplayer.has_multiplayer_peer() and not multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		var synchronizer := _player.get_node_or_null("StateSynchronizer") as MultiplayerSynchronizer
		for peer_id: int in multiplayer.get_peers():
			# Lobby peers do not have this avatar yet. Match spawner grants visibility.
			if synchronizer != null and (synchronizer.public_visibility or synchronizer.get_visibility_for(peer_id)):
				_play_shot.rpc_id(peer_id, origin, destination, hit)


func _apply_hit(collider: Object) -> void:
	if not collider is Node:
		return
	var damage: float = maxf(0.0, properties.bullet_damage)
	var target: Node = collider as Node
	var headshot: bool = false
	if collider is DamageHitbox:
		var hitbox := collider as DamageHitbox
		if hitbox.is_headshot and properties.headshottable:
			headshot = true
			damage *= maxf(1.0, properties.headshot_multiplier)
		elif not hitbox.is_headshot:
			damage *= maxf(0.0, hitbox.damage_multiplier)
		var hitbox_health: HealthComponent = hitbox.get_health_component()
		if hitbox_health != null:
			target = hitbox_health
	var attacker_id: int = int(_player.get("owner_peer_id"))
	var attacker_team: int = int(_player.get("team_id"))
	# Any AI can participate by adding HealthComponent or implementing this method.
	while target != null:
		if target is HealthComponent:
			_damage_health(target as HealthComponent, damage, attacker_id, attacker_team, headshot)
			return
		if target.has_method("server_take_damage"):
			target.call("server_take_damage", damage, attacker_id, attacker_team)
			return
		for child: Node in target.get_children():
			if child is HealthComponent:
				_damage_health(child as HealthComponent, damage, attacker_id, attacker_team, headshot)
				return
		target = target.get_parent()


func _damage_health(target_health: HealthComponent, damage: float, attacker_id: int, attacker_team: int, headshot: bool) -> void:
	var was_dead: bool = target_health.is_dead
	if not target_health.server_take_damage(damage, attacker_id, attacker_team):
		return
	var actor: Node = target_health.get_parent()
	if not actor.is_in_group("pve_enemies") or not _player.has_method("server_add_points"):
		return
	var reward: int = 0
	var target_id: int = target_health.get_instance_id()
	# Several pellets hitting one enemy still count as one scoring hit.
	if not _scored_targets.has(target_id):
		_scored_targets[target_id] = true
		reward += maxi(0, roundi(properties.point_per_shot))
	if not was_dead and target_health.is_dead:
		var kill_points: float = properties.point_per_headshot_kill if headshot else properties.point_per_body_kill
		reward += maxi(0, roundi(kill_points))
	if reward > 0:
		_player.call("server_add_points", reward)


@rpc("authority", "call_local", "unreliable_ordered", 2)
func _play_shot(origin: Vector3, destination: Vector3, hit: bool) -> void:
	# Connect muzzle flash, tracer, sound and local recoil to this signal.
	shot_fired.emit(origin, destination, hit)


func _start_reload() -> void:
	if is_reloading or magazine_ammo >= maxi(1, properties.mag_size) or reserve_ammo <= 0:
		return
	burst_shots_left = 0
	is_reloading = true
	reload_time_left = maxf(0.05, properties.reload_time)
	reload_changed.emit(true)


func _finish_reload() -> void:
	var needed: int = maxi(0, properties.mag_size - magazine_ammo)
	var loaded: int = mini(needed, reserve_ammo)
	magazine_ammo += loaded
	reserve_ammo -= loaded
	is_reloading = false
	reload_time_left = 0.0
	reload_changed.emit(false)
	ammo_changed.emit(magazine_ammo, reserve_ammo)


func _switch_firing_mode() -> void:
	if not properties.switchable_firing_modes or properties.possible_firing_modes.is_empty():
		return
	var index: int = properties.possible_firing_modes.find(current_firing_type)
	current_firing_type = properties.possible_firing_modes[(index + 1) % properties.possible_firing_modes.size()]
	burst_shots_left = 0
	firing_mode_changed.emit(current_firing_type)


func server_cancel_actions() -> void:
	if not multiplayer.is_server():
		return
	burst_shots_left = 0
	if is_reloading:
		is_reloading = false
		reload_time_left = 0.0
		reload_changed.emit(false)


func server_cancel_burst() -> void:
	# Sprint restrictions stop queued bullets without interrupting a reload.
	if multiplayer.is_server():
		burst_shots_left = 0


func server_reset() -> void:
	if not multiplayer.is_server():
		return
	server_cancel_actions()
	cooldown_left = 0.0
	_initialize_ammunition()


func _initialize_ammunition() -> void:
	magazine_ammo = maxi(1, properties.mag_size)
	reserve_ammo = clampi(properties.reserve_ammo, 0, maxi(0, properties.max_reserve_ammo))
	current_firing_type = properties.current_firing_type
	ammo_changed.emit(magazine_ammo, reserve_ammo)
	firing_mode_changed.emit(current_firing_type)


func server_add_ammo(amount: int) -> int:
	if not multiplayer.is_server() or amount <= 0:
		return 0
	var accepted: int = mini(amount, maxi(0, properties.max_reserve_ammo - reserve_ammo))
	reserve_ammo += accepted
	if accepted > 0:
		ammo_changed.emit(magazine_ammo, reserve_ammo)
	return accepted


func capture_state() -> Dictionary:
	return {"magazine": magazine_ammo, "reserve": reserve_ammo,
		"reloading": is_reloading, "reload_time": reload_time_left, "mode": current_firing_type}


func apply_network_state(state: Dictionary) -> void:
	var previous_magazine: int = magazine_ammo
	var previous_reserve: int = reserve_ammo
	var was_reloading: bool = is_reloading
	var previous_mode: int = current_firing_type
	magazine_ammo = clampi(int(state.get("magazine", magazine_ammo)), 0, maxi(1, properties.mag_size))
	reserve_ammo = clampi(int(state.get("reserve", reserve_ammo)), 0, maxi(0, properties.max_reserve_ammo))
	is_reloading = bool(state.get("reloading", false))
	reload_time_left = maxf(0.0, float(state.get("reload_time", 0.0)))
	current_firing_type = clampi(int(state.get("mode", current_firing_type)), 0, 2) as Gun_Properties.FIRE_TYPE
	if previous_magazine != magazine_ammo or previous_reserve != reserve_ammo:
		ammo_changed.emit(magazine_ammo, reserve_ammo)
	if was_reloading != is_reloading:
		reload_changed.emit(is_reloading)
	if previous_mode != current_firing_type:
		firing_mode_changed.emit(current_firing_type)


func _find_player() -> Node:
	var ancestor: Node = get_parent()
	while ancestor != null:
		if ancestor.has_method("is_alive"):
			return ancestor
		ancestor = ancestor.get_parent()
	return null


func _exclude_actor_colliders(actor: Node) -> void:
	if actor is CollisionObject3D:
		_ray.add_exception(actor as CollisionObject3D)
	for child: Node in actor.get_children():
		_exclude_actor_colliders(child)
