extends SceneTree
## Three processes exercise the actual menu, persistent lobby, loading barrier,
## player spawner, roster identities, and return-to-menu cleanup.

const TEST_PORT: int = 24876
const NAMES: Dictionary = {
	"host": "Host Tester", "first": "First Tester", "second": "Second Tester",
}

var _role: String = ""
var _failed: bool = false
var _lobby: Node


func _initialize() -> void:
	_run.call_deferred()
	_watchdog.call_deferred()


func _watchdog() -> void:
	await create_timer(25.0).timeout
	_fail("Lobby smoke timed out for " + _role)


func _run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--lobby-role="):
			_role = argument.trim_prefix("--lobby-role=")
	if not NAMES.has(_role):
		_fail("Expected --lobby-role=host, first, or second.")
		return
	_lobby = root.get_node("LobbySession")
	if change_scene_to_file("res://ui/LobbyMenu.tscn") != OK:
		_fail("Could not open the lobby menu.")
		return
	await scene_changed
	var error: int
	if _role == "host":
		error = _lobby.host_game(NAMES[_role], TEST_PORT)
	else:
		error = _lobby.join_game(NAMES[_role], "127.0.0.1", TEST_PORT)
	if error != OK:
		_fail("Lobby transport creation failed: " + error_string(error))
		return
	if not await _wait_for(func() -> bool: return _lobby.roster.size() == 3, "three lobby members"):
		return
	if not _validate_roster():
		return
	if not get_nodes_in_group("players").is_empty():
		_fail("Lobby members received avatars before the host started the match.")
		return
	if _role != "host":
		if _lobby.start_match():
			_fail("A client was allowed to start the match.")
			return
	else:
		# Give both clients time to inspect the complete lobby before loading.
		await create_timer(0.5).timeout
		if not _lobby.start_match():
			_fail("The host could not start a ready lobby.")
			return
	if not await _wait_for(_match_has_three_players, "all peers ready and three spawned avatars"):
		return
	await create_timer(0.25).timeout
	if not _validate_match():
		return
	if _role == "second":
		await create_timer(0.35).timeout
		_lobby.leave_lobby("Smoke test leaving match.")
		if not await _wait_for(_back_at_menu, "second client returns to a clean menu"):
			return
		print("PASS lobby second: roster identities, loading barrier, match, leave menu")
		quit(0)
		return
	if not await _wait_for(func() -> bool: return _player_count() == 2 and _lobby.roster.size() == 2, "departed client removed from roster and world"):
		return
	if _role == "first":
		# Stay connected: the host leaves next. This exercises server_disconnected,
		# not just this client's voluntary Disconnect button.
		if not await _wait_for(_back_at_menu, "host loss returns the first client to a clean menu"):
			return
		print("PASS lobby first: host-only start, roster, match, remote despawn and host-loss cleanup")
		quit(0)
		return
	await create_timer(0.5).timeout
	_lobby.leave_lobby("Smoke test host closing lobby.")
	if not await _wait_for(_back_at_menu, "host returns to a clean menu"):
		return
	print("PASS lobby host: all-ready barrier, named avatars, client departure and host menu cleanup")
	quit(0)


func _validate_roster() -> bool:
	var local_id := get_multiplayer().get_unique_id()
	if _lobby.roster.get(local_id, "") != NAMES[_role]:
		_fail("Display name was assigned to the wrong peer ID.")
		return false
	if _lobby.roster.get(1, "") != NAMES["host"]:
		_fail("Roster did not preserve host peer ID 1.")
		return false
	for expected_name in NAMES.values():
		if not _lobby.roster.values().has(expected_name):
			_fail("Roster is missing display name " + str(expected_name))
			return false
	return true


func _match_has_three_players() -> bool:
	return _player_count() == 3 and int(_lobby.phase) == _lobby.Phase.MATCH


func _player_count() -> int:
	if not is_instance_valid(current_scene):
		return 0
	var players := current_scene.get_node_or_null("Players")
	return 0 if players == null else players.get_child_count()


func _validate_match() -> bool:
	if current_scene.scene_file_path != "res://levels/test_level.tscn":
		_fail("Match opened the wrong level.")
		return false
	for player in current_scene.get_node("Players").get_children():
		if str(player.name) != str(player.owner_peer_id):
			_fail("Avatar node name and owner peer ID disagree.")
			return false
		if player.display_name != _lobby.get_display_name(player.owner_peer_id):
			_fail("Lobby display name did not follow its owner into the match.")
			return false
		if player.get_multiplayer_authority() != 1:
			_fail("The server lost simulation authority over an avatar.")
			return false
		if player.input.get_multiplayer_authority() != player.owner_peer_id:
			_fail("Input authority belongs to the wrong peer.")
			return false
	return true


func _back_at_menu() -> bool:
	return is_instance_valid(current_scene) \
		and current_scene.scene_file_path == "res://ui/LobbyMenu.tscn" \
		and not _lobby.active and _lobby.roster.is_empty() \
		and get_nodes_in_group("players").is_empty()


func _wait_for(condition: Callable, description: String) -> bool:
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		# LOADING must stay empty until every peer's level has reported readiness.
		if int(_lobby.phase) == _lobby.Phase.LOADING and _player_count() > 0:
			_fail("Players spawned before the lobby loading barrier was released.")
			return false
		if condition.call():
			return true
		if _failed:
			return false
		await process_frame
	_fail("%s timed out waiting for %s." % [_role, description])
	return false


func _fail(message: String) -> void:
	if _failed:
		return
	_failed = true
	push_error(message)
	quit(1)
