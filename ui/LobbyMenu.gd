extends Control
## Presentation only. Networking and authoritative roster live in LobbySession.

@onready var name_edit: LineEdit = %NameEdit
@onready var address_edit: LineEdit = %AddressEdit
@onready var port_edit: SpinBox = %PortEdit
@onready var host_button: Button = %HostButton
@onready var join_button: Button = %JoinButton
@onready var disconnect_button: Button = %DisconnectButton
@onready var start_button: Button = %StartButton
@onready var roster_list: ItemList = %RosterList
@onready var status_label: Label = %StatusLabel
@onready var roster_title: Label = %RosterTitle


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	host_button.pressed.connect(_host_pressed)
	join_button.pressed.connect(_join_pressed)
	disconnect_button.pressed.connect(LobbySession.leave_lobby)
	start_button.pressed.connect(LobbySession.start_match)
	LobbySession.roster_changed.connect(_refresh)
	LobbySession.state_changed.connect(_refresh)
	LobbySession.status_changed.connect(_on_status_changed)
	_refresh()
	if not LobbySession.run_startup_arguments():
		name_edit.grab_focus()


func _host_pressed() -> void:
	LobbySession.host_game(name_edit.text, int(port_edit.value))
	_refresh()


func _join_pressed() -> void:
	LobbySession.join_game(name_edit.text, address_edit.text, int(port_edit.value))
	_refresh()


func _on_status_changed(_message: String) -> void:
	_refresh()


func _refresh() -> void:
	var connected := LobbySession.active
	name_edit.editable = not connected
	address_edit.editable = not connected
	port_edit.editable = not connected
	host_button.disabled = connected
	join_button.disabled = connected
	disconnect_button.disabled = not connected
	start_button.visible = connected and multiplayer.is_server()
	start_button.disabled = LobbySession.phase != LobbySession.Phase.LOBBY
	status_label.text = LobbySession.status_message
	roster_title.text = "Players (%d / %d)" % [LobbySession.roster.size(), LobbySession.MAX_PLAYERS]
	roster_list.clear()
	var peer_ids := LobbySession.roster.keys()
	peer_ids.sort()
	for peer_id in peer_ids:
		var suffix := "  • Host" if int(peer_id) == 1 else ""
		if int(peer_id) == multiplayer.get_unique_id():
			suffix += "  • You"
		roster_list.add_item("%s  —  Peer %d%s" % [
			LobbySession.get_display_name(int(peer_id)), int(peer_id), suffix])
