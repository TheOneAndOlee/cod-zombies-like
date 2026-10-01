extends Node3D
## Chooses a nearby shop for local UI. It never grants a weapon or spends points.

signal focus_changed(is_looking_at_interactable: bool, text_to_change: String)

@export var interact_distance: float = 3.0
@onready var raycast: RayCast3D = $InteractRay
@onready var player: Player = owner

var focused_shop: WallBuy
var current_prompt: String = ""
var _purchase_sequence: int = 0


func _ready() -> void:
	raycast.add_exception(player)
	raycast.target_position = Vector3(0.0, 0.0, -interact_distance)
	# Player itself is server-owned; input ownership determines local presentation.
	set_physics_process(player.owner_peer_id == multiplayer.get_unique_id() and DisplayServer.get_name() != "headless")


func _physics_process(_delta: float) -> void:
	_update_focus()


func _update_focus() -> void:
	focused_shop = null
	current_prompt = ""
	if not player.is_alive() or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		focus_changed.emit(false, "")
		return
	raycast.force_raycast_update()
	var collider: Object = raycast.get_collider()
	# First prefer the panel under the reticle. Ray mask includes world walls,
	# so looking through a wall cannot select the panel behind it.
	if collider is WallBuy and collider.can_reach(player):
		focused_shop = collider as WallBuy
	else:
		# Standing in a shop's volume is also a valid interaction, even if looking
		# slightly away. The server rechecks distance and line of sight on purchase.
		var nearest_distance: float = INF
		for node: Node in get_tree().get_nodes_in_group("wall_buys"):
			var shop := node as WallBuy
			if shop == null or shop.multiplayer != multiplayer:
				continue
			if not shop.overlaps_body(player) or not shop.can_reach(player):
				continue
			var distance: float = player.global_position.distance_squared_to(shop.global_position)
			if distance < nearest_distance:
				focused_shop = shop
				nearest_distance = distance
	if is_instance_valid(focused_shop):
		current_prompt = focused_shop.get_prompt(player)
	focus_changed.emit(focused_shop != null, current_prompt)


func interact() -> void:
	if not player.is_local_player():
		return
	_update_focus()
	if not is_instance_valid(focused_shop):
		return
	_purchase_sequence += 1
	if multiplayer.is_server():
		focused_shop.request_purchase(_purchase_sequence, player.life_epoch)
	elif multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		focused_shop.request_purchase.rpc_id(1, _purchase_sequence, player.life_epoch)
