extends Node3D
## Normal Play starts offline. Command-line options exercise the same scene
## through ENet, independently of the existing Steam lobby UI.


func _ready() -> void:
	# The lobby already installed its peer before changing to this scene.
	# Re-reading --host/--join here would replace that live connection.
	if LobbySession.active:
		return
	var arguments := OS.get_cmdline_user_args()
	var port: int = Multiplayer_Utils.DEFAULT_PORT
	var join_address: String = ""
	for argument in arguments:
		if argument.begins_with("--port="):
			port = int(argument.trim_prefix("--port="))
		elif argument.begins_with("--join="):
			join_address = argument.trim_prefix("--join=")
	if port < 1 or port > 65535:
		push_error("--port must be between 1 and 65535.")
		return
	if arguments.has("--host") or arguments.has("--dedicated"):
		MultiplayerUtils.host_enet(port, 16, arguments.has("--dedicated"))
	elif not join_address.is_empty():
		MultiplayerUtils.join_enet(join_address, port)
