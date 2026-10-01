extends SceneTree
## Real Player/WallBuy scenes, physics occlusion, and authenticated ENet requests.

const PLAYER_SCENE = preload("res://player/player.tscn")
const WALL_BUY_SCENE = preload("res://interactables/WallBuy.tscn")
const TEST_PORT: int = 24875

var _checks: int = 0
var _failures: int = 0
var _request_id: int = 0
var _offline_world: Node3D
var _player: Player
var _wall: WallBuy
var _server_world: Node3D
var _client_world: Node3D
var _server_peer: ENetMultiplayerPeer
var _client_peer: ENetMultiplayerPeer
var _server_api: MultiplayerAPI
var _client_api: MultiplayerAPI
var _server_player: Player
var _client_player: Player
var _server_host: Player
var _server_wall: WallBuy
var _client_wall: WallBuy
var _feedback_messages: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()
	_watchdog.call_deferred()


func _watchdog() -> void:
	await create_timer(20.0).timeout
	push_error("Wall-buy tests timed out.")
	quit(2)


func _run() -> void:
	_offline_world = _make_world("OfflineWorld")
	_player = _make_player(_offline_world, 1)
	_wall = _make_wall(_offline_world)
	await physics_frame
	await physics_frame
	await _test_invalid_offline_requests()
	_test_purchase_and_refill()
	await _test_pve_rewards()
	_offline_world.queue_free()
	await process_frame
	if await _connect_peers():
		await _test_authenticated_requests()
	print("Wall-buy tests: %d checks, %d failures." % [_checks, _failures])
	if _client_peer != null:
		_client_peer.close()
	if _server_peer != null:
		_server_peer.close()
	quit(1 if _failures > 0 else 0)


func _make_world(node_name: String) -> Node3D:
	var world := Node3D.new()
	world.name = node_name
	var players := Node3D.new()
	players.name = "Players"
	world.add_child(players)
	root.add_child(world)
	return world


func _make_player(world: Node3D, peer_id: int) -> Player:
	var player: Player = PLAYER_SCENE.instantiate()
	player.name = str(peer_id)
	player.owner_peer_id = peer_id
	world.get_node("Players").add_child(player)
	player.set_physics_process(false)
	player.set_process(false)
	player.input.set_physics_process(false)
	player.camera.set_process(false)
	return player


func _make_wall(world: Node3D) -> WallBuy:
	var wall: WallBuy = WALL_BUY_SCENE.instantiate()
	wall.name = "WallBuy"
	wall.position = Vector3(0.0, 0.0, -2.0)
	world.add_child(wall)
	return wall


func _attempt(epoch: int = -1) -> void:
	# Independent cases should not be conflated with the deliberate spam test.
	_player._last_purchase_time = -100.0
	_request_id += 1
	_wall.request_purchase(_request_id, _player.life_epoch if epoch < 0 else epoch)


func _expect_unchanged(points_before: int, description: String) -> void:
	_expect(_player.points == points_before and not _player.inventory.has_weapon("olympia"), description)


func _test_invalid_offline_requests() -> void:
	_expect(_player.points == 500, "A new player starts with the configured 500 points")
	_expect(_player.inventory.has_weapon("m16a1"), "The starting rifle is registered in inventory")
	_expect(_wall.can_reach(_player), "A nearby unobstructed wall buy is reachable")
	_expect(_player.server_add_points(-5) == 0, "Negative point grants are rejected")
	_expect(not _player.server_spend_points(-5), "Negative purchases cannot mint points")
	_player.global_position = Vector3(20.0, 0.0, 0.0)
	_attempt()
	_expect_unchanged(500, "A distant player cannot purchase")
	_player.global_position = Vector3.ZERO
	var blocker := StaticBody3D.new()
	blocker.position = Vector3(0.0, 1.6, -1.0)
	var shape_node := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.0, 3.0, 0.3)
	shape_node.shape = box
	blocker.add_child(shape_node)
	_offline_world.add_child(blocker)
	await physics_frame
	await physics_frame
	_expect(not _wall.can_reach(_player), "World geometry blocks purchase line of sight")
	_attempt()
	_expect_unchanged(500, "A purchase through a solid wall is rejected")
	blocker.queue_free()
	await physics_frame
	_player.server_spend_points(500)
	_attempt()
	_expect_unchanged(0, "Insufficient points never grant a weapon")
	_player.server_add_points(500)
	_wall.weapon_id = "not_a_catalog_weapon"
	_attempt()
	_expect_unchanged(500, "An unknown weapon ID is rejected")
	_wall.weapon_id = "olympia"
	var capacity := _player.inventory.max_weapon_slots
	_player.inventory.max_weapon_slots = 1
	_attempt()
	_expect_unchanged(500, "A full inventory cannot buy another weapon")
	_player.inventory.max_weapon_slots = capacity
	_player.health.server_take_damage(_player.health.max_health)
	_attempt()
	_expect_unchanged(500, "A dead player cannot purchase")
	var previous_epoch := _player.life_epoch
	_player.server_respawn(Transform3D.IDENTITY)
	_attempt(previous_epoch)
	_expect_unchanged(500, "A request from a previous life is rejected")
	_expect(_player.points == 500, "Respawn preserves points")


func _test_purchase_and_refill() -> void:
	_attempt()
	_expect(_player.inventory.has_weapon("olympia"), "A valid purchase adds Olympia")
	_expect(_player.inventory.equipped_weapon_id == "olympia", "Buying a new weapon equips it")
	_expect(_player.points == 0, "A successful purchase charges the server's weapon cost once")
	_expect(_player.gun.magazine_ammo == _player.gun.properties.mag_size, "A purchased weapon starts with a full magazine")
	_expect(_player.inventory.is_reserve_full("olympia"), "A purchased weapon starts with a full reserve")
	_player.server_add_points(1000)
	_player.gun.reserve_ammo = 0
	_player._last_purchase_time = -100.0
	_wall.request_purchase(_request_id, _player.life_epoch)
	_expect(_player.points == 1000 and _player.gun.reserve_ammo == 0, "Replaying a successful request cannot buy ammo or charge points")
	_attempt()
	_expect(_player.points == 750 and _player.inventory.is_reserve_full("olympia"), "An owned weapon buys reserve ammo for the cheaper ammo price")
	_attempt()
	_expect(_player.points == 750, "Full reserve ammo cannot be purchased again")
	var olympia_slot := _player.inventory.weapon_slots.find("olympia")
	var rifle_slot := _player.inventory.weapon_slots.find("m16a1")
	_player.gun.magazine_ammo = 1
	_player.gun.reserve_ammo = 0
	_player.inventory.server_equip_slot(rifle_slot)
	var rifle_magazine := _player.gun.magazine_ammo
	var rifle_reserve := _player.gun.reserve_ammo
	_attempt()
	_expect(_player.points == 500, "An unequipped owned weapon can buy ammo")
	_expect(_player.inventory.equipped_weapon_id == "m16a1", "Refilling an unequipped weapon does not switch weapons")
	_expect(_player.gun.magazine_ammo == rifle_magazine and _player.gun.reserve_ammo == rifle_reserve, "An unequipped refill does not alter the active weapon's ammunition")
	_player.inventory.server_equip_slot(olympia_slot)
	_expect(_player.gun.magazine_ammo == 1 and _player.inventory.is_reserve_full("olympia"), "Ammo refill preserves a partial magazine and persists through switching")
	_player.gun.reserve_ammo = 0
	_attempt()
	var points_after_purchase := _player.points
	_player.gun.reserve_ammo = 0
	_request_id += 1
	_wall.request_purchase(_request_id, _player.life_epoch)
	_expect(_player.points == points_after_purchase and _player.gun.reserve_ammo == 0, "Rapid unique requests are throttled on the server")
	_player.server_respawn(Transform3D.IDENTITY)
	_expect(_player.inventory.has_weapon("olympia") and _player.inventory.equipped_weapon_id == "olympia", "Respawn preserves owned weapons and the equipped slot")


func _connect_peers() -> bool:
	_server_world = _make_world("ServerWorld")
	_client_world = _make_world("ClientWorld")
	_server_api = MultiplayerAPI.create_default_interface()
	_client_api = MultiplayerAPI.create_default_interface()
	set_multiplayer(_server_api, _server_world.get_path())
	set_multiplayer(_client_api, _client_world.get_path())
	_server_peer = ENetMultiplayerPeer.new()
	_client_peer = ENetMultiplayerPeer.new()
	var server_error := _server_peer.create_server(TEST_PORT, 2, 4)
	_expect(server_error == OK, "Wall-buy ENet server starts")
	if server_error != OK:
		return false
	_server_api.multiplayer_peer = _server_peer
	var client_error := _client_peer.create_client("127.0.0.1", TEST_PORT, 4)
	_expect(client_error == OK, "Wall-buy ENet client starts")
	if client_error != OK:
		return false
	_client_api.multiplayer_peer = _client_peer
	var deadline := Time.get_ticks_msec() + 3000
	while _client_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		if Time.get_ticks_msec() > deadline:
			_expect(false, "Wall-buy peers connect before timeout")
			return false
		await process_frame
	await create_timer(0.1).timeout
	var client_id := _client_api.get_unique_id()
	_server_host = _make_player(_server_world, 1)
	_server_player = _make_player(_server_world, client_id)
	_client_player = _make_player(_client_world, client_id)
	_client_player.purchase_feedback.connect(func(message: String, _successful: bool) -> void:
		_feedback_messages.append(message))
	_make_player(_client_world, 1)
	_server_wall = _make_wall(_server_world)
	_client_wall = _make_wall(_client_world)
	await physics_frame
	await physics_frame
	return true


func _send_client_request(epoch: int = -1) -> void:
	_server_player._last_purchase_time = -100.0
	_request_id += 1
	_client_wall.request_purchase.rpc_id(1, _request_id, _server_player.life_epoch if epoch < 0 else epoch)
	await create_timer(0.1).timeout
	_client_player._read_state()


func _test_authenticated_requests() -> void:
	_expect(not _client_player.inventory.server_buy_weapon("olympia"), "A client cannot grant itself an inventory weapon")
	_server_player.global_position = Vector3(20.0, 0.0, 0.0)
	# Forging local memory must not change the server's selected actor or prices.
	_client_player.global_position = Vector3.ZERO
	_client_player.points = 999999
	_client_wall.cost = 0
	await _send_client_request()
	_expect(not _server_player.inventory.has_weapon("olympia") and _server_player.points == 500, "Forged local position and price cannot bypass server range validation")
	_expect(not _server_host.inventory.has_weapon("olympia") and _server_host.points == 500, "A client's request cannot purchase on behalf of the nearby host")
	_server_player.global_position = Vector3.ZERO
	_server_player.remove_from_group("players")
	await _send_client_request()
	_expect(not _server_player.inventory.has_weapon("olympia"), "A connected peer without a spawned avatar cannot purchase")
	_server_player.add_to_group("players")
	_server_player.server_spend_points(500)
	await _send_client_request()
	_expect(_server_player.points == 0 and not _server_player.inventory.has_weapon("olympia"), "Forged client points cannot pay for a server purchase")
	_expect(_feedback_messages.any(func(message: String) -> bool: return message.begins_with("Not enough points")), "Low-funds feedback arrives through the server-only response RPC")
	_server_player.server_add_points(500)
	_server_player.health.server_take_damage(_server_player.health.max_health)
	await _send_client_request()
	_expect(_server_player.points == 500 and not _server_player.inventory.has_weapon("olympia"), "Dead-client purchase RPCs are rejected")
	var stale_epoch := _server_player.life_epoch
	_server_player.server_respawn(Transform3D.IDENTITY)
	await _send_client_request(stale_epoch)
	_expect(not _server_player.inventory.has_weapon("olympia"), "A stale-life purchase RPC is rejected")
	await _send_client_request()
	_expect(_server_player.inventory.has_weapon("olympia") and _server_player.points == 0, "An authenticated valid purchase uses the server price")
	_expect(_client_player.inventory.has_weapon("olympia") and _client_player.points == 0, "Purchased inventory and points replicate to the owning client")
	_server_player.server_add_points(500)
	_server_player.gun.reserve_ammo = 0
	_server_player._last_purchase_time = -100.0
	_client_wall.request_purchase.rpc_id(1, _request_id, _server_player.life_epoch)
	await create_timer(0.1).timeout
	_expect(_server_player.points == 500 and _server_player.gun.reserve_ammo == 0, "A duplicate RPC does not double-charge or refill")
	await _send_client_request()
	_expect(_server_player.points == 250 and _server_player.inventory.is_reserve_full("olympia"), "Authenticated ammo purchase refills the server inventory")
	await _send_client_request()
	_expect(_server_player.points == 250, "A full-ammo RPC does not charge points")
	var client_points := _client_player.points
	_expect(_client_player.server_add_points(1000) == 0, "Clients cannot grant themselves authoritative points")
	_expect(not _client_player.server_spend_points(1), "Clients cannot directly spend authoritative points")
	_expect(_client_player.points == client_points, "Client currency server-method calls leave its snapshot unchanged")


func _test_pve_rewards() -> void:
	# Real traces prove rewards are tied to accepted damage, not a fire request.
	var target: Node3D = load("res://combat/training_target.tscn").instantiate()
	target.position = Vector3(0.0, 0.0, -6.0)
	_offline_world.add_child(target)
	_player.inventory.server_equip_slot(0)
	var original_properties: Gun_Properties = _player.gun.properties
	var test_properties: Gun_Properties = original_properties.duplicate(true)
	test_properties.bullet_damage = 25.0
	test_properties.pellets_per_shot = 1
	test_properties.ads_spread_degrees = 0.0
	test_properties.point_per_shot = 10.0
	test_properties.point_per_body_kill = 40.0
	_player.gun.set_weapon_properties(test_properties)
	_player.camera.look_at(target.position + Vector3(0.0, 0.85, 0.0))
	await physics_frame
	await physics_frame
	var initial_points: int = _player.points
	_player.gun.server_tick(2.0, true, true, false, true)
	_expect(target.health.current_health == 75.0 and _player.points == initial_points + 10, "An accepted PvE body hit awards points on the server")
	_player.team_id = 3
	target.team_id = 3
	_player.gun.server_tick(1.0, true, true, false, true)
	_expect(_player.points == initial_points + 10 and target.health.current_health == 75.0, "Rejected friendly damage cannot award points")
	_player.team_id = -1
	target.team_id = 99
	test_properties.bullet_damage = 100.0
	_player.gun.server_tick(1.0, true, true, false, true)
	_expect(target.health.is_dead and _player.points == initial_points + 60, "A lethal PvE body shot adds exactly one kill reward")
	_player.gun.server_tick(1.0, true, true, false, true)
	_expect(_player.points == initial_points + 60, "Shooting an already-dead target cannot farm rewards")
	_player.gun.set_weapon_properties(original_properties)
	_player.server_add_points(_player.maximum_points)
	_expect(_player.points == _player.maximum_points, "Point rewards stop at the configured maximum")
	_expect(_player.server_add_points(1) == 0, "A capped reward reports that no points were added")
	target.queue_free()
	await process_frame


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("  PASS: ", description)
	else:
		_failures += 1
		push_error("FAIL: " + description)
