extends SceneTree
## Run three copies against one port: -- --host --smoke-role=host,
## -- --join=127.0.0.1 --smoke-role=early, then the same with role=late.
## The early client remains until the late client disconnects.

var _role: String = ""
var _level: Node3D
var _players: Node3D
var _failed: bool = false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--smoke-role="):
			_role = argument.trim_prefix("--smoke-role=")
	if _role not in ["host", "early", "late"]:
		_fail("Expected --smoke-role=host, early, or late.")
		return
	_level = load("res://levels/test_level.tscn").instantiate() as Node3D
	root.add_child(_level)
	current_scene = _level
	_players = _level.get_node("Players") as Node3D
	if _role == "host":
		if not await _wait_for_player_count(1):
			return
		_level.get_node("TrainingTarget/Health").server_take_damage(25.0)
		_level.get_node("AmmoPickup").active = false
		_level.get_node("AmmoPickup").respawn_remaining = 30.0
	if not await _wait_for_player_count(3):
		return
	# Allow the first authoritative snapshot to arrive on both clients.
	await create_timer(0.25).timeout
	_validate_avatars()
	if _failed:
		return
	if _role == "late":
		await create_timer(0.6).timeout
		print("PASS spawning late: three avatars, ownership and camera, disconnect")
		_level.multiplayer.multiplayer_peer.close()
		quit(0)
		return
	if not await _wait_for_player_count(2):
		return
	if _role == "early":
		print("PASS spawning early: late join replicated and disconnected avatar removed")
		await create_timer(0.25).timeout
		_level.multiplayer.multiplayer_peer.close()
		quit(0)
		return
	if not await _wait_for_player_count(1):
		return
	print("PASS spawning host: both ready handshakes, late join and both despawns")
	quit(0)


func _wait_for_player_count(expected: int) -> bool:
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		if _players.get_child_count() == expected:
			return true
		await process_frame
	_fail("%s timed out waiting for %d avatars; found %d." % [
		_role, expected, _players.get_child_count()])
	return false


func _validate_avatars() -> void:
	var local_id := _level.multiplayer.get_unique_id()
	var local_count: int = 0
	for avatar in _players.get_children():
		var owner_id: int = avatar.owner_peer_id
		if str(avatar.name) != str(owner_id) or avatar.get_multiplayer_authority() != 1:
			_fail("Avatar name/owner or server authority is wrong.")
			return
		if avatar.get_node("PlayerInput").get_multiplayer_authority() != owner_id:
			_fail("PlayerInput is not owned by its assigned peer.")
			return
		var camera := avatar.get_node("Head/Camera3D") as Camera3D
		var expects_camera := owner_id == local_id and DisplayServer.get_name() != "headless"
		if camera.current != expects_camera:
			_fail("A local camera is missing or a remote avatar has an active camera.")
			return
		var health := avatar.get_node("Health") as HealthComponent
		if health.current_health != health.max_health or health.is_dead:
			_fail("Initial health failed to replicate.")
			return
		if owner_id == local_id:
			local_count += 1
	if local_count != 1:
		_fail("Each peer must own exactly one local avatar.")
	if not is_equal_approx(_level.get_node("TrainingTarget/Health").current_health, 75.0):
		_fail("Current PvE target health did not replicate to a joining peer.")
	if _level.get_node("AmmoPickup").active:
		_fail("Consumed ammo pickup state did not replicate to a joining peer.")


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	quit(1)
