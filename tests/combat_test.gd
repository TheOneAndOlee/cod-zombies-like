extends SceneTree
## Run with: godot --headless --path . --script res://tests/combat_test.gd
## These are integration checks: the real Player scene and physics ray are used.

const PLAYER_SCENE = preload("res://player/player.tscn")

var _failures: int = 0
var _checks: int = 0
var _world: Node3D
var _shooter: Player
var _target: Player


func _initialize() -> void:
	_run.call_deferred()
	_watchdog.call_deferred()


func _watchdog() -> void:
	await create_timer(10.0).timeout
	push_error("Combat test timed out before completion.")
	quit(2)


func _run() -> void:
	_world = Node3D.new()
	_world.name = "CombatTestWorld"
	root.add_child(_world)
	_shooter = _make_player("Shooter", Vector3.ZERO, 1)
	_target = _make_player("Target", Vector3(0.0, 0.0, -8.0), 2)
	# Give every player its own stats so modifying a test gun cannot affect another.
	_shooter.gun.properties = _shooter.gun.properties.duplicate(true)
	_configure_test_weapon()
	await physics_frame
	await physics_frame
	_test_health()
	_test_ammunition()
	await _test_hitscan()
	await _test_death_and_respawn()
	await _test_movement()
	print("Combat tests: %d checks, %d failures." % [_checks, _failures])
	_world.queue_free()
	await process_frame
	quit(1 if _failures > 0 else 0)


func _make_player(node_name: String, spawn_position: Vector3, peer_id: int) -> Player:
	var player: Player = PLAYER_SCENE.instantiate()
	player.name = node_name
	player.owner_peer_id = peer_id
	player.position = spawn_position
	_world.add_child(player)
	# The test supplies simulation time explicitly; hardware and gravity must not
	# silently change our fixture between assertions.
	player.set_physics_process(false)
	player.get_node("PlayerInput").set_physics_process(false)
	player.get_node("PlayerInput").set_process(false)
	player.get_node("Head/Camera3D").set_process(false)
	return player


func _configure_test_weapon() -> void:
	var stats := _shooter.gun.properties
	stats.mag_size = 5
	stats.reserve_ammo = 10
	stats.fire_rate = 600.0
	stats.bullet_damage = 20.0
	stats.headshot_multiplier = 2.0
	stats.headshottable = true
	stats.reload_time = 0.25
	stats.current_firing_type = Gun_Properties.FIRE_TYPE.SEMI_AUTO
	_shooter.gun.server_reset()


func _test_health() -> void:
	var health := _target.health
	health.server_reset()
	var maximum := health.max_health
	_expect(not health.server_take_damage(-10.0), "Negative damage is rejected")
	_expect(not health.server_take_damage(NAN), "NaN damage is rejected")
	_expect(not health.server_take_damage(INF), "Infinite damage is rejected")
	_expect(is_equal_approx(health.current_health, maximum), "Invalid damage cannot change health")
	_target.team_id = 7
	_target.allow_friendly_fire = false
	_expect(not health.server_take_damage(10.0, 1, 7), "Friendly fire is blocked for matching teams")
	_expect(health.server_take_damage(10.0, 1, 8), "An enemy team can damage the player")
	_expect(is_equal_approx(health.current_health, maximum - 10.0), "Damage subtracts the expected health")
	_expect(health.is_hurt, "A successful hit enters hurt state")
	health._physics_process(health.hurt_duration + 0.01)
	_expect(not health.is_hurt, "Hurt state expires after its configured duration")
	health.server_take_damage(maximum * 2.0, 1, 8)
	_expect(health.is_dead and is_zero_approx(health.current_health), "Lethal damage clamps health at zero")
	_expect(not health.server_take_damage(10.0, 1, 8), "Dead targets cannot be damaged again")
	_target.server_respawn(_target.global_transform)
	_target.team_id = -1
	_expect(not health.is_dead and not health.is_hurt, "Reset clears death and hurt states")


func _test_ammunition() -> void:
	var gun := _shooter.gun
	gun.server_reset()
	# Aim away from the target: this group tests ammunition, not damage.
	_shooter.get_node("Head/Camera3D").rotation.y = PI
	gun.server_tick(0.0, true, true, false, false)
	_expect(gun.magazine_ammo == 4, "A shot consumes one round")
	gun.server_tick(0.01, true, true, false, false)
	_expect(gun.magazine_ammo == 4, "Trigger spam cannot bypass the fire cooldown")
	gun.server_tick(0.11, true, false, false, false)
	_expect(gun.magazine_ammo == 4, "Holding a semi-auto trigger cannot fire another shot")
	gun.server_tick(0.0, true, true, false, false)
	_expect(gun.magazine_ammo == 3, "A new trigger press can fire after the cooldown")
	var total_before_reload := gun.magazine_ammo + gun.reserve_ammo
	gun.server_tick(0.0, false, false, true, false)
	_expect(gun.is_reloading, "Reload starts when the magazine has space")
	gun.server_tick(0.01, true, true, false, false)
	_expect(gun.magazine_ammo == 3, "Reloading prevents firing")
	gun.server_tick(0.30, false, false, false, false)
	_expect(not gun.is_reloading and gun.magazine_ammo == 5, "Reload completes and fills the magazine")
	_expect(gun.magazine_ammo + gun.reserve_ammo == total_before_reload, "Reload conserves total ammunition")
	_expect(gun.server_add_ammo(-5) == 0, "A negative ammo pickup is ignored")
	var reserve_before_pickup := gun.reserve_ammo
	var accepted := gun.server_add_ammo(100000)
	_expect(accepted >= 0 and gun.reserve_ammo == reserve_before_pickup + accepted, "Ammo pickup reports the amount actually accepted")
	_expect(gun.server_add_ammo(1) == 0, "Ammo pickups stop at the reserve limit")
	gun.server_reset()
	gun.magazine_ammo = 0
	gun.reserve_ammo = 2
	gun.server_tick(0.0, false, false, true, false)
	gun.server_tick(0.30, false, false, false, false)
	_expect(gun.magazine_ammo == 2 and gun.reserve_ammo == 0, "Partial reload uses only the remaining reserve")
	gun.magazine_ammo = 0
	gun.server_tick(1.0, true, true, false, false)
	_expect(gun.magazine_ammo == 0, "An empty gun cannot fire")
	gun.server_reset()
	gun.current_firing_type = Gun_Properties.FIRE_TYPE.FULL_AUTO
	gun.server_tick(0.0, true, false, false, false)
	gun.server_tick(0.11, true, false, false, false)
	_expect(gun.magazine_ammo == 3, "Full auto fires again while the trigger is held")
	gun.server_reset()
	gun.current_firing_type = Gun_Properties.FIRE_TYPE.FULL_AUTO
	gun.server_tick(0.0, false, true, false, false)
	_expect(gun.magazine_ammo == 4, "A quick reliable tap fires a full-auto weapon even after release")
	gun.server_reset()
	gun.current_firing_type = Gun_Properties.FIRE_TYPE.BURST
	gun.server_tick(0.0, true, true, false, false)
	gun.server_tick(0.11, false, false, false, false)
	gun.server_tick(0.11, false, false, false, false)
	gun.server_tick(1.0, false, false, false, false)
	_expect(gun.magazine_ammo == 2 and gun.burst_shots_left == 0, "One burst press fires exactly three rounds even after release")
	gun.server_tick(0.0, false, false, true, false)
	gun.server_cancel_actions()
	_expect(not gun.is_reloading and gun.magazine_ammo == 2, "Canceling a reload does not create ammunition")
	_shooter.get_node("Head/Camera3D").rotation = Vector3.ZERO


func _test_hitscan() -> void:
	_target.health.server_reset()
	_shooter.gun.server_reset()
	# Explicit zero spread makes geometric hit checks deterministic.
	_set_zero_spread()
	_aim_at(_target.global_position + Vector3(0.0, 0.9, 0.0))
	await physics_frame
	_shooter.gun.server_tick(1.0, true, true, false, true)
	_expect(is_equal_approx(_target.health.current_health, _target.health.max_health - 20.0), "A server body hitscan applies base damage")
	_target.health.server_reset()
	_shooter.gun.server_reset()
	_aim_at(_target.get_node("HeadHitbox").global_position)
	await physics_frame
	_shooter.gun.server_tick(1.0, true, true, false, true)
	_expect(is_equal_approx(_target.health.current_health, _target.health.max_health - 40.0), "A server head hitscan applies the headshot multiplier")
	var wall := StaticBody3D.new()
	wall.name = "OccludingWall"
	wall.position = Vector3(0.0, 1.0, -4.0)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(3.0, 3.0, 0.5)
	collision.shape = shape
	wall.add_child(collision)
	_world.add_child(wall)
	_target.health.server_reset()
	_shooter.gun.server_reset()
	await physics_frame
	await physics_frame
	_shooter.gun.server_tick(1.0, true, true, false, true)
	_expect(is_equal_approx(_target.health.current_health, _target.health.max_health), "A wall blocks damage to the target behind it")
	wall.queue_free()
	await physics_frame


func _set_zero_spread() -> void:
	# Updated alongside the weapon resource contract.
	_shooter.gun.properties.hip_spread_degrees = 0.0
	_shooter.gun.properties.ads_spread_degrees = 0.0


func _aim_at(point: Vector3) -> void:
	var camera: Camera3D = _shooter.get_node("Head/Camera3D")
	camera.look_at(point, Vector3.UP)


func _test_death_and_respawn() -> void:
	_shooter.gun.server_reset()
	_shooter.health.server_take_damage(_shooter.health.max_health * 2.0)
	var ammunition_before := _shooter.gun.magazine_ammo
	_shooter.gun.server_tick(1.0, true, true, false, false)
	_expect(_shooter.gun.magazine_ammo == ammunition_before, "Dead players cannot fire")
	var spawn := Transform3D(Basis(Vector3.UP, 0.7), Vector3(3.0, 2.0, 4.0))
	_shooter.velocity = Vector3(1.0, -9.0, 2.0)
	_shooter.server_respawn(spawn)
	await physics_frame
	_expect(_shooter.is_alive(), "Respawn restores the alive state")
	_expect(is_equal_approx(_shooter.health.current_health, _shooter.health.max_health), "Respawn restores full health")
	_expect(_shooter.global_position.is_equal_approx(spawn.origin), "Respawn moves to the server-selected location")
	_expect(_shooter.velocity.is_zero_approx(), "Respawn clears old velocity")
	_expect(_shooter.gun.magazine_ammo == _shooter.gun.properties.mag_size, "Respawn refills the magazine")
	_expect(not _shooter.gun.is_reloading, "Respawn clears pending weapon actions")


func _test_movement() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.position = Vector3(0.0, -0.5, 0.0)
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(100.0, 1.0, 100.0)
	floor_shape.shape = floor_box
	floor_body.add_child(floor_shape)
	_world.add_child(floor_body)
	_shooter.server_respawn(Transform3D(Basis.IDENTITY, Vector3(10.0, 0.01, 0.0)))
	await physics_frame
	await physics_frame
	_shooter.submit_input(1, _shooter.life_epoch, Vector2(99.0, 99.0), Vector2(TAU * 4.0, PI), false, false, false)
	_expect(is_equal_approx(_shooter._move_input.length(), 1.0), "Server clamps oversized movement input")
	_expect(is_equal_approx(_shooter._look_input.y, Player.PITCH_LIMIT), "Server clamps camera pitch to 89 degrees")
	_expect(absf(_shooter._look_input.x) <= PI, "Server wraps horizontal look")
	for index in range(6):
		await _movement_step(2 + index, Vector2.ZERO)
	_expect(_shooter.is_on_floor(), "The player capsule rests on the floor")
	await _movement_step(8, Vector2(0.0, -1.0))
	_expect(_shooter.velocity.z < 0.0 and absf(_shooter.velocity.z) < _shooter.walk_speed, "Movement accelerates smoothly toward walking speed")
	for index in range(20):
		await _movement_step(9 + index, Vector2(0.0, -1.0))
	_expect(is_equal_approx(absf(_shooter.velocity.z), _shooter.walk_speed * _shooter.gun.properties.mobility_penalty), "Held movement reaches walking speed with the weapon mobility multiplier")
	await _movement_step(29, Vector2.ZERO)
	_expect(_shooter.velocity.z < 0.0 and absf(_shooter.velocity.z) < _shooter.walk_speed, "Releasing movement decelerates smoothly")
	for index in range(12):
		await _movement_step(30 + index, Vector2.ZERO)
	_expect(is_zero_approx(_shooter.velocity.z), "Released movement comes to a stop")
	for index in range(24):
		await _movement_step(42 + index, Vector2(0.0, -1.0), true)
	_expect(_shooter.is_sprinting and is_equal_approx(absf(_shooter.velocity.z), _shooter.sprint_speed * _shooter.gun.properties.mobility_penalty), "Forward sprint reaches sprint speed with the weapon mobility multiplier")
	_shooter.request_action(Player.Action.JUMP, _shooter.life_epoch, Vector2.ZERO)
	await _movement_step(66, Vector2.ZERO)
	_expect(_shooter.velocity.y > 0.0 and not _shooter.is_on_floor(), "Jump leaves the floor with upward velocity")
	var upward_velocity := _shooter.velocity.y
	_shooter.request_action(Player.Action.JUMP, _shooter.life_epoch, Vector2.ZERO)
	await _movement_step(67, Vector2.ZERO)
	_expect(_shooter.velocity.y < upward_velocity, "Airborne jump requests cannot grant a second jump")
	_shooter.submit_input(68, _shooter.life_epoch, Vector2(0.0, -1.0), Vector2.ZERO, true, true, false)
	_shooter._last_input_time = _shooter._seconds() - _shooter.input_timeout - 1.0
	_shooter._physics_process(0.0)
	_expect(_shooter._move_input.is_zero_approx() and not _shooter._fire_held and not _shooter._sprint_held, "Expired input releases movement, fire and sprint")
	_shooter._budget_second = int(Time.get_ticks_msec() / 1000)
	_shooter._input_budget = _shooter.max_input_messages_per_second
	_shooter.submit_input(69, _shooter.life_epoch, Vector2.RIGHT, Vector2.ZERO, false, false, false)
	_expect(_shooter._move_input.is_zero_approx(), "Continuous input above the server message budget is rejected")
	_shooter._action_budget = _shooter.max_actions_per_second
	_shooter.request_action(Player.Action.FIRE, _shooter.life_epoch, Vector2.ZERO)
	_expect(not _shooter._fire_requested, "Actions above the server message budget are rejected")
	floor_body.queue_free()


func _movement_step(sequence: int, movement: Vector2, sprint: bool = false) -> void:
	_shooter.submit_input(sequence, _shooter.life_epoch, movement, Vector2.ZERO, sprint, false, false)
	await physics_frame
	_shooter._physics_process(1.0 / 60.0)


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("  PASS: ", description)
	else:
		_failures += 1
		push_error("FAIL: " + description)
