class_name PlayerSpawner
extends MultiplayerSpawner
## Identical paths on every peer: TestLevel/Players/<owner_peer_id>.
## The server is the only peer allowed to call spawn() or remove avatars.

@export var player_scene: PackedScene = preload("res://player/player.tscn")
@export var spawn_points_path: NodePath = ^"../SpawnPoints"
@export var default_team_id: int = -1

var _ready_peers: Dictionary = {}
var _next_spawn_index: int = 0
var _lobby_match_epoch: int = 0
var _lobby_generation: int = 0

@onready var _players: Node3D = get_node(spawn_path) as Node3D
@onready var _spawn_points: Node3D = get_node(spawn_points_path) as Node3D


func _ready() -> void:
	set_multiplayer_authority(1)
	_lobby_match_epoch = LobbySession.match_epoch
	_lobby_generation = LobbySession.session_generation
	spawn_function = _create_player
	multiplayer.connected_to_server.connect(_announce_world_ready)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	MultiplayerUtils.session_started.connect(_start_session)
	MultiplayerUtils.session_ended.connect(_clear_players)
	# Children and spawn markers must be inside the tree before using transforms.
	_start_session.call_deferred()


func _start_session() -> void:
	if not is_inside_tree():
		return
	if LobbySession.active:
		# Loading acknowledgements go through the persistent autoload. No avatar
		# is spawned here until it releases the all-players-ready barrier.
		LobbySession.report_world_ready(self, _lobby_match_epoch, _lobby_generation)
		return
	if multiplayer.is_server():
		if not MultiplayerUtils.is_dedicated:
			_spawn_for_peer(1)
	else:
		_announce_world_ready()


func _announce_world_ready() -> void:
	if LobbySession.active or multiplayer.is_server():
		return
	var active_peer := multiplayer.multiplayer_peer
	if active_peer != null and active_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		_world_ready.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _world_ready() -> void:
	# Kept for direct arena / F6 test sessions. It must never bypass a lobby's
	# all-player loading barrier, even if a modified client sends this RPC.
	if LobbySession.active or not multiplayer.is_server():
		return
	# Never accept a requested peer ID from the packet: the sender is the owner.
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 1 or not multiplayer.get_peers().has(sender_id):
		return
	_spawn_for_peer(sender_id)


func release_players(peer_ids: Array[int]) -> void:
	if not multiplayer.is_server() or not LobbySession.active:
		return
	if LobbySession.phase != LobbySession.Phase.MATCH:
		return
	if _lobby_match_epoch != LobbySession.match_epoch or _lobby_generation != LobbySession.session_generation:
		return
	for peer_id in peer_ids:
		_spawn_for_peer(peer_id)


func _spawn_for_peer(peer_id: int) -> void:
	if not multiplayer.is_server() or _ready_peers.has(peer_id):
		return
	_ready_peers[peer_id] = true
	_set_world_visibility(peer_id, true)
	# Visibility gates existing avatars too: a lobby peer may connect before
	# loading this level, and must not receive node spawns at nonexistent paths.
	for existing_player in _players.get_children():
		var synchronizer := existing_player.get_node("StateSynchronizer") as MultiplayerSynchronizer
		synchronizer.set_visibility_for(peer_id, true)
	var spawn_transform := _choose_spawn_transform()
	spawn({
		"peer_id": peer_id,
		"display_name": LobbySession.get_display_name(peer_id),
		"team_id": default_team_id,
		"position": _players.to_local(spawn_transform.origin),
		"yaw": spawn_transform.basis.get_euler().y,
	})


func _create_player(data: Variant) -> Node:
	# MultiplayerSpawner calls this on every peer before adding the node.
	# Ownership must be set here, before PlayerInput and cameras enter _ready().
	var spawn_data: Dictionary = data
	var player := player_scene.instantiate() as Player
	player.name = str(int(spawn_data["peer_id"]))
	player.owner_peer_id = int(spawn_data["peer_id"])
	player.display_name = str(spawn_data.get("display_name", "Player"))
	player.team_id = int(spawn_data["team_id"])
	player.position = spawn_data["position"]
	player.rotation.y = float(spawn_data["yaw"])
	player.set_multiplayer_authority(1, true)
	if multiplayer.is_server():
		var synchronizer := player.get_node("StateSynchronizer") as MultiplayerSynchronizer
		synchronizer.public_visibility = false
		for ready_peer_id in _ready_peers:
			synchronizer.set_visibility_for(int(ready_peer_id), true)
	player.respawn_requested.connect(_on_respawn_requested)
	return player


func _on_respawn_requested(player: Player) -> void:
	if not multiplayer.is_server() or not is_instance_valid(player):
		return
	player.server_respawn(_choose_spawn_transform(player))


func _choose_spawn_transform(respawning_player: Player = null) -> Transform3D:
	var markers := _spawn_points.get_children()
	if markers.is_empty():
		return Transform3D(Basis.IDENTITY, Vector3(0.0, 0.1, 0.0))
	# Prefer the marker furthest from a living avatar. Rotate ties so joining
	# players don't all pick the same marker when the arena is initially empty.
	var best_marker: Node3D = markers[_next_spawn_index % markers.size()] as Node3D
	var best_distance: float = -1.0
	for offset in range(markers.size()):
		var marker := markers[(_next_spawn_index + offset) % markers.size()] as Node3D
		var nearest_distance: float = INF
		for other in _players.get_children():
			if other == respawning_player or other.is_queued_for_deletion():
				continue
			var health := other.get_node_or_null("Health")
			if health != null and health.get("is_dead") == true:
				continue
			nearest_distance = minf(nearest_distance, marker.global_position.distance_squared_to(other.global_position))
		if nearest_distance > best_distance:
			best_distance = nearest_distance
			best_marker = marker
	_next_spawn_index = (markers.find(best_marker) + 1) % markers.size()
	return best_marker.global_transform


func _on_peer_disconnected(peer_id: int) -> void:
	_ready_peers.erase(peer_id)
	if not multiplayer.is_server():
		return
	_set_world_visibility(peer_id, false)
	for existing_player in _players.get_children():
		var synchronizer := existing_player.get_node("StateSynchronizer") as MultiplayerSynchronizer
		_forget_peer_visibility(synchronizer, peer_id)
	var player := _players.get_node_or_null(str(peer_id))
	if player != null:
		# MultiplayerSpawner mirrors the despawn to all clients.
		player.queue_free()


func _clear_players() -> void:
	for ready_peer_id in _ready_peers:
		_set_world_visibility(int(ready_peer_id), false)
	_ready_peers.clear()
	_next_spawn_index = 0
	# Session teardown is local on every peer, after the old connection closes.
	for player in _players.get_children():
		_players.remove_child(player)
		player.queue_free()


func _set_world_visibility(peer_id: int, visible: bool) -> void:
	# Static PvE targets and pickups need the same world-ready gate as avatars.
	for node in get_tree().get_nodes_in_group("world_state_sync"):
		var synchronizer := node as MultiplayerSynchronizer
		if synchronizer != null:
			synchronizer.public_visibility = false
			if visible:
				synchronizer.set_visibility_for(peer_id, true)
			else:
				_forget_peer_visibility(synchronizer, peer_id)


func _forget_peer_visibility(synchronizer: MultiplayerSynchronizer, peer_id: int) -> void:
	# Godot removes the replication peer BEFORE emitting peer_disconnected.
	# Forget its permission without asking replication to update a missing peer.
	# Clearing the grant also keeps a reconnect with the same ID behind readiness.
	var was_blocking: bool = synchronizer.is_blocking_signals()
	synchronizer.set_block_signals(true)
	synchronizer.set_visibility_for(peer_id, false)
	synchronizer.set_block_signals(was_blocking)
