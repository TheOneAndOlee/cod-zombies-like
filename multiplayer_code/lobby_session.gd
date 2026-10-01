extends Node
## Persistent lobby state and the match-loading barrier. All lobby RPCs live on
## this autoload, so messages never target a level a client has not loaded yet.

signal roster_changed
signal state_changed
signal status_changed(message: String)

enum Phase { OFFLINE, CONNECTING, LOBBY, LOADING, MATCH }

const MENU_SCENE: String = "res://ui/LobbyMenu.tscn"
const MATCH_SCENE: String = "res://levels/test_level.tscn"
const MAX_PLAYERS: int = 16
const MAX_NAME_LENGTH: int = 24
const LOAD_TIMEOUT: float = 25.0

var active: bool = false
var phase: Phase = Phase.OFFLINE
## Only the server edits this dictionary; clients receive authoritative copies.
var roster: Dictionary = {}
var status_message: String = "Host a lobby or join one on your local network."
var match_epoch: int = 0
## Cancels deferred scene work left over from a previous connection.
var session_generation: int = 0

var _local_display_name: String = "Player"
var _expected_peers: Dictionary = {}
var _ready_peers: Dictionary = {}
var _world_spawner: Node
var _startup_arguments_handled: bool = false


func _ready() -> void:
	set_multiplayer_authority(1)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	MultiplayerUtils.transport_lost.connect(_on_transport_lost)
	MultiplayerUtils.connection_error.connect(_on_connection_error)


func host_game(display_name: String, port: int = 7000) -> Error:
	if active:
		return ERR_ALREADY_IN_USE
	if not _valid_port(port):
		return ERR_INVALID_PARAMETER
	_prepare_connection(display_name)
	var error := MultiplayerUtils.host_enet(port, MAX_PLAYERS - 1)
	if error != OK:
		_reset_session()
		return error
	roster[1] = _local_display_name
	phase = Phase.LOBBY
	_set_status("Hosting on UDP port %d. Players can join before you start." % port)
	roster_changed.emit()
	state_changed.emit()
	return OK


func join_game(display_name: String, address: String, port: int = 7000) -> Error:
	if active:
		return ERR_ALREADY_IN_USE
	if not _valid_port(port) or address.strip_edges().is_empty():
		_set_status("Enter a server address and a port between 1 and 65535.")
		return ERR_INVALID_PARAMETER
	_prepare_connection(display_name)
	_set_status("Connecting to %s:%d..." % [address.strip_edges(), port])
	var error := MultiplayerUtils.join_enet(address.strip_edges(), port)
	if error != OK:
		_reset_session()
	return error


func start_match() -> bool:
	# A normal method, not an any_peer RPC: only the local host menu can start.
	if not active or not multiplayer.is_server() or phase != Phase.LOBBY:
		return false
	for peer_id in multiplayer.get_peers():
		if not roster.has(peer_id):
			_set_status("A player is still connecting. Wait for their name in the roster.")
			return false
	# This sample closes admission once loading begins. Existing players still
	# finish loading; new joins fail cleanly and can retry after a new lobby opens.
	multiplayer.multiplayer_peer.refuse_new_connections = true
	_expected_peers.clear()
	for peer_id in roster:
		_expected_peers[int(peer_id)] = true
	_ready_peers.clear()
	_world_spawner = null
	match_epoch += 1
	_begin_match.rpc(match_epoch)
	_watch_loading_timeout(session_generation, match_epoch)
	return true


func leave_lobby(reason: String = "Disconnected.") -> void:
	# Reset first: session-ended handlers must not mistake this for a new match.
	_reset_session()
	MultiplayerUtils.disconnect_session(false)
	_set_status(reason)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_show_menu.call_deferred(session_generation)


func get_display_name(peer_id: int) -> String:
	return str(roster.get(peer_id, "Player %d" % peer_id))


func report_world_ready(spawner: Node, epoch: int, generation: int) -> void:
	# Spawner captures both tokens in _ready. An old deferred callback cannot
	# acknowledge a replacement level or a new connection after leaving a match.
	if not active or phase != Phase.LOADING or epoch != match_epoch:
		return
	if generation != session_generation or not is_instance_valid(spawner):
		return
	_world_spawner = spawner
	if multiplayer.is_server():
		_record_world_ready(1, epoch)
	else:
		_world_ready.rpc_id(1, epoch)


func run_startup_arguments() -> bool:
	# Preserve the original --host / --join arena shortcuts when F5 now opens
	# the lobby. Only interpret startup arguments once, not on a later disconnect.
	if _startup_arguments_handled:
		return false
	_startup_arguments_handled = true
	if active:
		return false
	for argument in OS.get_cmdline_user_args():
		if argument in ["--host", "--dedicated"] or argument.begins_with("--join="):
			_open_direct_arena.call_deferred(session_generation)
			return true
	return false


func _prepare_connection(display_name: String) -> void:
	session_generation += 1
	active = true
	phase = Phase.CONNECTING
	roster.clear()
	_expected_peers.clear()
	_ready_peers.clear()
	_world_spawner = null
	_local_display_name = _clean_display_name(display_name)
	MultiplayerUtils.managed_session = true
	state_changed.emit()


func _reset_session() -> void:
	session_generation += 1
	active = false
	phase = Phase.OFFLINE
	roster.clear()
	_expected_peers.clear()
	_ready_peers.clear()
	_world_spawner = null
	MultiplayerUtils.managed_session = false
	roster_changed.emit()
	state_changed.emit()


func _on_connected_to_server() -> void:
	if active and phase == Phase.CONNECTING:
		_register_player.rpc_id(1, _local_display_name)


func _on_peer_connected(peer_id: int) -> void:
	if not active or not multiplayer.is_server():
		return
	if phase != Phase.LOBBY:
		_reject_player.rpc_id(peer_id, "This match has already started. Join a new lobby instead.")
		_disconnect_rejected_peer(peer_id, session_generation)


@rpc("any_peer", "call_remote", "reliable")
func _register_player(requested_name: String) -> void:
	if not active or not multiplayer.is_server():
		return
	# A client provides only its name. Its identity comes from the transport.
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 1 or not multiplayer.get_peers().has(sender_id):
		return
	if phase != Phase.LOBBY:
		_reject_player.rpc_id(sender_id, "The host has already started the match.")
		_disconnect_rejected_peer(sender_id, session_generation)
		return
	if roster.has(sender_id):
		return
	roster[sender_id] = _clean_display_name(requested_name)
	_broadcast_roster()


func _broadcast_roster() -> void:
	_receive_roster.rpc(roster)


@rpc("authority", "call_local", "reliable")
func _receive_roster(server_roster: Dictionary) -> void:
	if not active:
		return
	roster = server_roster.duplicate(true)
	if phase == Phase.CONNECTING:
		phase = Phase.LOBBY
		_set_status("Connected. Waiting for the host to start the match.")
	roster_changed.emit()
	state_changed.emit()


@rpc("authority", "call_local", "reliable")
func _begin_match(epoch: int) -> void:
	if not active or phase != Phase.LOBBY:
		return
	match_epoch = epoch
	phase = Phase.LOADING
	_set_status("Loading arena. Waiting until every player is ready...")
	state_changed.emit()
	_load_match_scene.call_deferred(session_generation, epoch)


func _load_match_scene(generation: int, epoch: int) -> void:
	if not active or generation != session_generation or epoch != match_epoch:
		return
	if phase != Phase.LOADING:
		return
	var error := get_tree().change_scene_to_file(MATCH_SCENE)
	if error != OK:
		leave_lobby("Could not load the arena: %s" % error_string(error))


@rpc("any_peer", "call_remote", "reliable")
func _world_ready(epoch: int) -> void:
	if not active or not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 1 or not multiplayer.get_peers().has(sender_id):
		return
	_record_world_ready(sender_id, epoch)


func _record_world_ready(peer_id: int, epoch: int) -> void:
	if phase != Phase.LOADING or epoch != match_epoch or not _expected_peers.has(peer_id):
		return
	_ready_peers[peer_id] = true
	_maybe_release_match()


func _maybe_release_match() -> void:
	if phase != Phase.LOADING or not is_instance_valid(_world_spawner):
		return
	for peer_id in _expected_peers:
		if not _ready_peers.has(peer_id):
			return
	var peer_ids: Array[int] = []
	for peer_id in _expected_peers:
		peer_ids.append(int(peer_id))
	peer_ids.sort()
	_match_released.rpc(match_epoch)
	# This is the first place that creates avatars in a lobby-managed match.
	_world_spawner.release_players(peer_ids)


@rpc("authority", "call_local", "reliable")
func _match_released(epoch: int) -> void:
	if not active or phase != Phase.LOADING or epoch != match_epoch:
		return
	phase = Phase.MATCH
	_set_status("Match in progress.")
	state_changed.emit()


func _on_peer_disconnected(peer_id: int) -> void:
	if not active or not multiplayer.is_server():
		return
	roster.erase(peer_id)
	_expected_peers.erase(peer_id)
	_ready_peers.erase(peer_id)
	_broadcast_roster()
	_maybe_release_match()


func _watch_loading_timeout(generation: int, epoch: int) -> void:
	await get_tree().create_timer(LOAD_TIMEOUT).timeout
	if not active or generation != session_generation or epoch != match_epoch:
		return
	if phase != Phase.LOADING or not multiplayer.is_server():
		return
	for peer_id in _expected_peers.keys():
		if int(peer_id) != 1 and not _ready_peers.has(peer_id):
			_reject_player.rpc_id(int(peer_id), "Loading the arena timed out. Rejoin the next lobby.")
			_disconnect_rejected_peer(int(peer_id), generation)


@rpc("authority", "call_remote", "reliable")
func _reject_player(reason: String) -> void:
	if active:
		leave_lobby(reason)


func _disconnect_rejected_peer(peer_id: int, generation: int) -> void:
	# Give the reliable rejection message a moment to reach the joining peer.
	await get_tree().create_timer(0.25).timeout
	if active and session_generation == generation and multiplayer.is_server():
		if multiplayer.get_peers().has(peer_id):
			multiplayer.multiplayer_peer.disconnect_peer(peer_id)


func _on_transport_lost(message: String) -> void:
	if active:
		leave_lobby(message)


func _on_connection_error(message: String) -> void:
	if active:
		_set_status(message)


func _show_menu(generation: int) -> void:
	if active or generation != session_generation:
		return
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.scene_file_path == MENU_SCENE:
		return
	get_tree().change_scene_to_file(MENU_SCENE)


func _open_direct_arena(generation: int) -> void:
	if not active and generation == session_generation:
		get_tree().change_scene_to_file(MATCH_SCENE)


func _valid_port(port: int) -> bool:
	if port >= 1 and port <= 65535:
		return true
	_set_status("Port must be between 1 and 65535.")
	return false


func _clean_display_name(value: String) -> String:
	var clean := ""
	for index in range(mini(value.length(), 128)):
		var codepoint := value.unicode_at(index)
		if codepoint >= 32 and codepoint != 127:
			clean += value[index]
	clean = clean.strip_edges().left(MAX_NAME_LENGTH)
	return "Player" if clean.is_empty() else clean


func _set_status(message: String) -> void:
	status_message = message
	status_changed.emit(message)
