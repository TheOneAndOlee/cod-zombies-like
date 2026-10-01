extends CanvasLayer
## Local presentation only. The labels read server snapshots; buttons send intent.

@onready var player: Player = get_parent()
@onready var stats: Label = $Margin/Stats
@onready var status: Label = $Status
@onready var prompt: Label = $InteractionPrompt
@onready var feedback: Label = $PurchaseFeedback
@onready var disconnect_button: Button = $Disconnect

var _feedback_time: float = 0.0


func _ready() -> void:
	player.purchase_feedback.connect(_on_purchase_feedback)
	disconnect_button.pressed.connect(_on_disconnect)


func _process(delta: float) -> void:
	if not visible or not is_instance_valid(player.gun):
		return
	var weapon: Gun = player.gun
	var weapon_name: String = WeaponCatalog.get_display_name(player.inventory.equipped_weapon_id)
	stats.text = "%s  |  HP %d / %d  |  %d Points\n%s  %d / %d  |  [1] [2] Switch weapon" % [
		player.display_name, player.health.current_health, player.health.max_health,
		player.points, weapon_name, weapon.magazine_ammo, weapon.reserve_ammo]
	prompt.text = player.interactor.current_prompt
	_feedback_time = maxf(0.0, _feedback_time - delta)
	feedback.visible = _feedback_time > 0.0
	disconnect_button.visible = Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	if not player.is_alive():
		status.text = "Eliminated — respawn in %.1fs" % player.respawn_remaining if player.respawn_remaining > 0.0 else "Press Enter to respawn"
	elif weapon.is_reloading:
		status.text = "Reloading…"
	elif Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		status.text = "Click to capture mouse • Esc to toggle"
	else:
		status.text = ""


func _on_purchase_feedback(message: String, successful: bool) -> void:
	feedback.text = message
	feedback.modulate = Color(0.55, 1.0, 0.7) if successful else Color(1.0, 0.4, 0.35)
	_feedback_time = 3.0


func _on_disconnect() -> void:
	# This exits the session; it does not pause the multiplayer server simulation.
	get_node("/root/LobbySession").leave_lobby()
