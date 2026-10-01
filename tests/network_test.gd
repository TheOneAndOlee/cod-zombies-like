extends SceneTree
## Runs an actual ENet server and client in separate MultiplayerAPI branches.
## No Steam login or second operating-system process is needed.

const PLAYER_SCENE = preload("res://player/player.tscn")
const TEST_PORT: int = 24873

var _failures: int = 0
var _checks: int = 0
var _server_api: MultiplayerAPI
var _client_api: MultiplayerAPI
var _server_peer: ENetMultiplayerPeer
var _client_peer: ENetMultiplayerPeer
var _server_world: Node3D
var _client_world: Node3D
var _server_player: Player
var _client_player: Player
var _server_other: Player
var _client_other: Player


func _initialize() -> void:
	_run.call_deferred()
	_watchdog.call_deferred()


func _watchdog() -> void:
	await create_timer(10.0).timeout
	push_error("Network test timed out before completion.")
	quit(2)


func _run() -> void:
	if not await _connect_peers():
		_finish()
		return
	var client_id := _client_api.get_unique_id()
	# Matching relative paths are required by Godot RPCs and synchronization.
	_server_player = _make_player(_server_world, "OwnedPlayer", client_id)
	_server_other = _make_player(_server_world, "OtherPlayer", 1)
	_client_player = _make_player(_client_world, "OwnedPlayer", client_id)
	_client_other = _make_player(_client_world, "OtherPlayer", 1)
	await _settle(0.25)
	_test_authority_assignment(client_id)
	_test_client_mutation_guards()
	await _test_rpc_ownership()
	await _test_damage_and_respawn_replication()
	_finish()


func _connect_peers() -> bool:
	_server_world = Node3D.new()
	_server_world.name = "ServerWorld"
	_client_world = Node3D.new()
	_client_world.name = "ClientWorld"
	# Keep the client's duplicate collision objects away from the server fixture.
	_client_world.position.x = 1000.0
	root.add_child(_server_world)
	root.add_child(_client_world)
	_server_api = MultiplayerAPI.create_default_interface()
	_client_api = MultiplayerAPI.create_default_interface()
	set_multiplayer(_server_api, _server_world.get_path())
	set_multiplayer(_client_api, _client_world.get_path())
	_server_peer = ENetMultiplayerPeer.new()
	_client_peer = ENetMultiplayerPeer.new()
	var server_error := _server_peer.create_server(TEST_PORT, 2, 4)
	_expect(server_error == OK, "Local ENet server starts")
	if server_error != OK:
		return false
	_server_api.multiplayer_peer = _server_peer
	var client_error := _client_peer.create_client("127.0.0.1", TEST_PORT, 4)
	_expect(client_error == OK, "Local ENet client starts")
	if client_error != OK:
		return false
	_client_api.multiplayer_peer = _client_peer
	var deadline := Time.get_ticks_msec() + 3000
	while _client_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		if Time.get_ticks_msec() > deadline:
			_expect(false, "ENet client connects before the timeout")
			return false
		await process_frame
	await _settle(0.1)
	_expect(_server_api.get_peers().size() == 1, "The server sees the connected client")
	return true


func _make_player(world: Node3D, node_name: String, peer_id: int) -> Player:
	var player: Player = PLAYER_SCENE.instantiate()
	player.name = node_name
	player.owner_peer_id = peer_id
	world.add_child(player)
	player.set_physics_process(false)
	player.get_node("PlayerInput").set_physics_process(false)
	player.get_node("PlayerInput").set_process(false)
	player.get_node("Head/Camera3D").set_process(false)
	return player


func _test_authority_assignment(client_id: int) -> void:
	_expect(_server_player.get_multiplayer_authority() == 1, "The server retains Player authority")
	_expect(_client_player.get_multiplayer_authority() == 1, "The client replica also identifies server authority")
	_expect(_client_player.get_node("PlayerInput").get_multiplayer_authority() == client_id, "Input authority belongs to the avatar's peer")
	_expect(not _client_player.is_local_player(), "A headless client does not enable local presentation or hardware input")
	_expect(not _client_player.camera.current and not _client_other.camera.current, "Headless and remote avatar cameras remain inactive")


func _test_client_mutation_guards() -> void:
	# A client can edit its own memory; these edits must never grant authority.
	# Non-default values ensure an unguarded reset would be caught by the test.
	_client_player.health.current_health = 50.0
	_client_player.gun.magazine_ammo = 2
	_client_player.gun.reserve_ammo = 1
	var health_before := _client_player.health.current_health
	var magazine_before := _client_player.gun.magazine_ammo
	var reserve_before := _client_player.gun.reserve_ammo
	_expect(not _client_player.health.server_take_damage(50.0), "A client cannot directly execute server damage")
	_client_player.health.server_reset()
	_client_player.gun.server_reset()
	_client_player.gun.server_tick(1.0, true, true, false, false)
	_expect(_client_player.gun.server_add_ammo(100) == 0, "A client cannot grant ammunition")
	_expect(is_equal_approx(_client_player.health.current_health, health_before), "Client server-method calls do not alter health")
	_expect(_client_player.gun.magazine_ammo == magazine_before and _client_player.gun.reserve_ammo == reserve_before, "Client server-method calls do not alter ammo")
	var position_before := _client_player.global_position
	_client_player.server_respawn(Transform3D(Basis.IDENTITY, Vector3(999.0, 999.0, 999.0)))
	_expect(_client_player.global_position.is_equal_approx(position_before), "A client cannot choose a respawn location")


func _test_rpc_ownership() -> void:
	# Actual packets use the receiving node's registered any_peer endpoint. The
	# other avatar is host-owned, so the server must reject this client's request.
	var other_yaw := _server_other._look_input.x
	_client_other.submit_input.rpc_id(1, 1, 0, Vector2.RIGHT, Vector2(0.75, 0.0), true, true, false)
	await _settle(0.1)
	_expect(is_equal_approx(_server_other._look_input.x, other_yaw), "An input RPC cannot control another peer's avatar")
	# Input is intentionally unreliable. Repeat the held state like the actual
	# 30 Hz input node, rather than assuming one UDP packet must be delivered.
	var input_deadline: int = Time.get_ticks_msec() + 1500
	while not is_equal_approx(_server_player._look_input.x, 0.5) and Time.get_ticks_msec() < input_deadline:
		_client_player.submit_input.rpc_id(1, 1, 0, Vector2.ZERO, Vector2(0.5, 0.0), false, false, false)
		await _settle(0.05)
	_expect(is_equal_approx(_server_player._look_input.x, 0.5), "The owning peer's input RPC is accepted")
	_client_player.submit_input.rpc_id(1, 1, 0, Vector2.ZERO, Vector2(1.25, 0.0), false, false, false)
	await _settle(0.1)
	_expect(is_equal_approx(_server_player._look_input.x, 0.5), "A duplicate input sequence is ignored")
	_client_player.submit_input.rpc_id(1, 2, 0, Vector2.ZERO, Vector2(NAN, 0.0), false, false, false)
	await _settle(0.1)
	_expect(is_finite(_server_player._look_input.x), "Non-finite client look values are rejected")
	_client_other.request_action.rpc_id(1, Player.Action.FIRE, 0, Vector2.ZERO)
	await _settle(0.1)
	_expect(not _server_other._fire_requested, "A fire action cannot operate another peer's weapon")
	_client_player.request_action.rpc_id(1, Player.Action.FIRE, 0, Vector2.ZERO)
	await _settle(0.1)
	_expect(_server_player._fire_requested, "The owning peer can request firing")
	_server_player._clear_actions()


func _test_damage_and_respawn_replication() -> void:
	_server_player.health.server_take_damage(25.0, 1, -1)
	_server_player._publish_state()
	await _settle(0.2)
	_expect(is_equal_approx(_client_player.health.current_health, _server_player.health.current_health), "Server damage reaches the client health state")
	_server_player.health.server_take_damage(100000.0, 1, -1)
	await _settle(0.2)
	_expect(_client_player.health.is_dead, "Server death reaches the client")
	var spawn := Transform3D(Basis(Vector3.UP, 0.4), Vector3(4.0, 2.0, -3.0))
	_server_player.server_respawn(spawn)
	await _settle(0.3)
	_expect(_client_player.is_alive(), "Server respawn restores the client alive state")
	_expect(is_equal_approx(_client_player.health.current_health, _client_player.health.max_health), "Server respawn restores client health")
	_expect(_client_player.global_position.is_equal_approx(_server_player.global_position), "Server respawn replicates its chosen location")
	_client_player.submit_input.rpc_id(1, 999, 0, Vector2.ZERO, Vector2(1.5, 0.0), false, true, false)
	await _settle(0.1)
	_expect(is_equal_approx(_server_player.rotation.y, 0.4), "Packets from a previous life cannot steer the respawned player")


func _settle(seconds: float) -> void:
	await create_timer(seconds).timeout
	# The fixture freezes physics; explicitly consume synchronized snapshots.
	if is_instance_valid(_client_player):
		_client_player._read_state()
	if is_instance_valid(_client_other):
		_client_other._read_state()


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("  PASS: ", description)
	else:
		_failures += 1
		push_error("FAIL: " + description)


func _finish() -> void:
	print("Network tests: %d checks, %d failures." % [_checks, _failures])
	if _client_peer != null:
		_client_peer.close()
	if _server_peer != null:
		_server_peer.close()
	quit(1 if _failures > 0 else 0)
