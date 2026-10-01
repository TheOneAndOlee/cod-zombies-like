class_name Multiplayer_Utils
extends Node
## Transport setup only. The level's PlayerSpawner owns avatar creation/removal.

signal session_started
signal session_ended
signal connection_error(message: String)
signal transport_lost(message: String)

const DEFAULT_PORT: int = 7000
const STEAM_OK: int = 1

var is_host: bool = false
var is_dedicated: bool = false
var lobby_id: int = 0
var peer: MultiplayerPeer
## The lobby sets this while it owns navigation and disconnection handling.
var managed_session: bool = false

# Dynamic lookup lets the offline/ENet demo run in ordinary Godot builds too.
var _steam: Object
var _creating_lobby: bool = false


func _ready() -> void:
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	set_process(false)


func _process(_delta: float) -> void:
	# This project disables embedded callbacks. Steam lobby signals need pumping.
	if is_instance_valid(_steam):
		_steam.call("run_callbacks")


func host_enet(port: int = DEFAULT_PORT, max_clients: int = 16,
		dedicated: bool = false) -> Error:
	var new_peer := ENetMultiplayerPeer.new()
	var error := new_peer.create_server(port, max_clients)
	if error != OK:
		_report_error("Could not start ENet server: %s" % error_string(error))
		return error
	_install_peer(new_peer, true, dedicated)
	return OK


func join_enet(address: String, port: int = DEFAULT_PORT) -> Error:
	var new_peer := ENetMultiplayerPeer.new()
	var error := new_peer.create_client(address, port)
	if error != OK:
		_report_error("Could not start ENet client: %s" % error_string(error))
		return error
	_install_peer(new_peer, false)
	return OK


func host_lobby(lobby_type: int, num_players: int) -> void:
	# The int still accepts Steam.LobbyType values used by an existing lobby UI.
	if not _initialize_steam():
		return
	_creating_lobby = true
	_steam.call("createLobby", lobby_type, num_players)


func join_lobby(new_lobby_id: int) -> void:
	if not _initialize_steam():
		return
	_creating_lobby = false
	_steam.call("joinLobby", new_lobby_id)


func disconnect_session(restart_offline: bool = true) -> void:
	_close_session()
	# F6 / direct arena tests still return to offline play. A lobby match instead
	# returns to its menu, so it must not accidentally create an offline avatar.
	if restart_offline and not managed_session:
		session_started.emit()


func _initialize_steam() -> bool:
	if is_instance_valid(_steam):
		return true
	if not Engine.has_singleton("Steam") or not ClassDB.class_exists("SteamMultiplayerPeer"):
		_report_error("Steam networking requires a GodotSteam build with SteamMultiplayerPeer.")
		return false
	_steam = Engine.get_singleton("Steam")
	# Explicit lobby requests initialize Steam; offline/ENet never launch Steam.
	var initialization: Dictionary = _steam.call("steamInit", 480, true)
	if int(initialization.get("status", -1)) != 1:
		_report_error("Steam initialization failed: %s" % str(initialization))
		_steam = null
		return false
	_steam.call("initRelayNetworkAccess")
	_steam.connect("lobby_created", _on_lobby_created)
	_steam.connect("lobby_joined", _on_lobby_joined)
	set_process(not bool(ProjectSettings.get_setting("steam/initialization/processes/embed_callbacks", false)))
	return true


func _on_lobby_created(result: int, new_lobby_id: int) -> void:
	if not _creating_lobby:
		return
	_creating_lobby = false
	if result != STEAM_OK:
		_report_error("Steam lobby creation failed (result %d)." % result)
		return
	var new_peer := ClassDB.instantiate("SteamMultiplayerPeer") as MultiplayerPeer
	new_peer.set("server_relay", true)
	var error: int = new_peer.call("create_host", 0)
	if error != OK:
		_steam.call("leaveLobby", new_lobby_id)
		_report_error("Steam host creation failed (error %d)." % error)
		return
	_install_peer(new_peer, true)
	lobby_id = new_lobby_id


func _on_lobby_joined(new_lobby_id: int, _permissions: int,
		_locked: bool, response: int) -> void:
	if response != STEAM_OK:
		_report_error("Steam lobby join failed (response %d)." % response)
		return
	var host_steam_id: int = _steam.call("getLobbyOwner", new_lobby_id)
	# Creating a lobby also emits lobby_joined for its host.
	if host_steam_id == int(_steam.call("getSteamID")):
		return
	var new_peer := ClassDB.instantiate("SteamMultiplayerPeer") as MultiplayerPeer
	var error: int = new_peer.call("create_client", host_steam_id, 0)
	if error != OK:
		_steam.call("leaveLobby", new_lobby_id)
		_report_error("Steam client creation failed (error %d)." % error)
		return
	_install_peer(new_peer, false)
	lobby_id = new_lobby_id


func _install_peer(new_peer: MultiplayerPeer, hosting: bool,
		dedicated: bool = false) -> void:
	_close_session()
	peer = new_peer
	is_host = hosting
	is_dedicated = dedicated
	multiplayer.multiplayer_peer = peer
	session_started.emit()


func _close_session() -> void:
	if peer != null:
		peer.close()
	peer = null
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	if lobby_id != 0 and is_instance_valid(_steam):
		_steam.call("leaveLobby", lobby_id)
	lobby_id = 0
	is_host = false
	is_dedicated = false
	session_ended.emit()


func _on_connection_failed() -> void:
	var message := "Could not connect. Check the address/port; the lobby may be full or already in a match."
	_report_error(message)
	disconnect_session()
	transport_lost.emit(message)


func _on_server_disconnected() -> void:
	var message := "The host disconnected."
	_report_error(message)
	disconnect_session()
	transport_lost.emit(message)


func _report_error(message: String) -> void:
	push_warning(message)
	connection_error.emit(message)
