extends SceneTree
## Optional rendered check: run without --headless using the compatibility renderer.

func _initialize() -> void:
	_run.call_deferred()
	# Also bound rendering/connection waits if a regression prevents completion.
	create_timer(30.0).timeout.connect(func() -> void: quit(1))


func _run() -> void:
	root.size = Vector2i(1100, 820)
	if change_scene_to_file("res://ui/LobbyMenu.tscn") != OK:
		quit(1)
		return
	await scene_changed
	var lobby: Node = root.get_node("LobbySession")
	if lobby.host_game("Local Host", 24877) != OK:
		quit(1)
		return
	for frame in range(4):
		await process_frame
	RenderingServer.force_draw()
	await RenderingServer.frame_post_draw
	var screenshot: Image = root.get_texture().get_image()
	var error: Error = screenshot.save_png("res://tests/lobby_preview.png")
	print("Menu screenshot saved: ", error == OK)
	if error != OK:
		quit(1)
		return
	if not lobby.start_match():
		quit(1)
		return
	while lobby.phase != lobby.Phase.MATCH:
		await process_frame
	var player: Player = current_scene.get_node("Players/1")
	player.server_respawn(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.01, -13.7)))
	for frame in range(4):
		await physics_frame
	RenderingServer.force_draw()
	await RenderingServer.frame_post_draw
	if root.get_texture().get_image().save_png("res://tests/wall_buy_preview.png") != OK:
		quit(1)
		return
	var wall: WallBuy = current_scene.get_node("OlympiaWallBuy")
	wall.request_purchase(1, player.life_epoch)
	for frame in range(4):
		await process_frame
	RenderingServer.force_draw()
	await RenderingServer.frame_post_draw
	error = root.get_texture().get_image().save_png("res://tests/purchase_preview.png")
	var purchase_succeeded: bool = player.inventory.has_weapon("olympia") and player.points == 0
	print("Rendered purchase completed: ", purchase_succeeded)
	lobby.leave_lobby()
	quit(0 if error == OK and purchase_succeeded else 1)

