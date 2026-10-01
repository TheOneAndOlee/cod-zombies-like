class_name WallBuy
extends Area3D
## A shop's exported data is trusted only on the SERVER's copy of this scene.
## Clients send a request number and life epoch, never a price, balance or victim.

@export_group("Offer")
@export var weapon_id: String = "olympia"
@export var weapon_name: String = "Olympia"
@export_range(0, 1000000) var cost: int = 500
@export_range(0, 1000000) var ammo_cost: int = 250

@export_group("Interaction")
@export_range(0.5, 10.0) var max_purchase_distance: float = 3.0
@export var require_line_of_sight: bool = true
## World geometry only. Player bodies and shop Areas must not block this ray.
@export_flags_3d_physics var obstruction_mask: int = 1


func _enter_tree() -> void:
	set_multiplayer_authority(1)


func _ready() -> void:
	add_to_group("wall_buys")
	$Label3D.text = "%s\n%d Points  /  Ammo %d" % [weapon_name, cost, ammo_cost]


func get_prompt(player: Player) -> String:
	if not WeaponCatalog.has_weapon(weapon_id):
		return "Unavailable weapon"
	if player.inventory.has_weapon(weapon_id):
		if player.inventory.is_reserve_full(weapon_id):
			return "%s — Ammo full" % weapon_name
		return "[E] Refill %s — %d Points" % [weapon_name, ammo_cost]
	if not player.inventory.can_add_weapon(weapon_id):
		return "%s — Inventory full" % weapon_name
	return "[E] Buy %s — %d Points" % [weapon_name, cost]


func can_reach(player: Player) -> bool:
	# Also used by the local prompt, but the server always runs its own check.
	# A player may look at the panel or stand in its proximity Area; both paths
	# require a nearby authoritative eye position and an unobstructed wall panel.
	if not player.is_alive():
		return false
	var origin: Vector3 = player.camera.global_position
	var destination: Vector3 = $InteractionPoint.global_position
	if origin.distance_to(destination) > max_purchase_distance:
		return false
	# Enforce the same look-or-proximity rule as the client prompt. Even a
	# modified client must actually be in the Area or aim its server camera at it.
	if not overlaps_body(player):
		var aim_end: Vector3 = origin - player.camera.global_basis.z * max_purchase_distance
		var aim_query := PhysicsRayQueryParameters3D.create(origin, aim_end, 9)
		aim_query.exclude = [player.get_rid()]
		aim_query.collide_with_areas = true
		var aim_hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(aim_query)
		if aim_hit.get("collider") != self:
			return false
	# Enforce the same look-or-proximity rule as the client prompt. Even a
	# modified client must actually be in the Area or aim its server camera at it.
	if not overlaps_body(player):
		var aim_end: Vector3 = origin - player.camera.global_basis.z * max_purchase_distance
		var aim_query := PhysicsRayQueryParameters3D.create(origin, aim_end, 9)
		aim_query.exclude = [player.get_rid()]
		aim_query.collide_with_areas = true
		var aim_hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(aim_query)
		if aim_hit.get("collider") != self:
			return false
	if not require_line_of_sight:
		return true
	var query := PhysicsRayQueryParameters3D.create(origin, destination, obstruction_mask)
	query.exclude = [player.get_rid()]
	query.collide_with_areas = false
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	return hit.is_empty()


@rpc("any_peer", "call_local", "reliable", 0)
func request_purchase(request_id: int, life_epoch: int) -> void:
	# any_peer allows a request; it does NOT authorize a purchase. call_local
	# supports the listen host. Remote clients execute no inventory mutations.
	if not multiplayer.is_server():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	if sender_id == 0:
		sender_id = 1 # Direct call by the offline/listen host, already server-checked.
	var player: Player = _find_player(sender_id)
	if player == null:
		return # Connected lobby peers and unspawned peers cannot buy.
	if not player.server_accept_purchase_request(request_id, life_epoch):
		return
	if not player.is_alive():
		_reject(player, "You cannot buy while eliminated.")
		return
	if not can_reach(player):
		_reject(player, "Move closer to the weapon panel.")
		return
	if cost < 0 or ammo_cost < 0 or not WeaponCatalog.has_weapon(weapon_id):
		_reject(player, "This wall buy is unavailable.")
		return

	var buying_ammo: bool = player.inventory.has_weapon(weapon_id)
	var price: int = ammo_cost if buying_ammo else cost
	if buying_ammo and player.inventory.is_reserve_full(weapon_id):
		_reject(player, "Reserve ammo is already full.")
		return
	if not buying_ammo and not player.inventory.can_add_weapon(weapon_id):
		_reject(player, "Inventory full — this weapon was not purchased.")
		return
	if player.points < price:
		_reject(player, "Not enough points — need %d more." % (price - player.points))
		return

	# Synchronous transaction: no await between deduction and delivery. If an
	# inventory rule rejects the grant, refund immediately before publishing.
	if not player.server_spend_points(price):
		return
	var delivered: bool
	if buying_ammo:
		delivered = player.inventory.server_refill_weapon(weapon_id)
	else:
		delivered = player.inventory.server_buy_weapon(weapon_id)
	if not delivered:
		player.server_add_points(price)
		_reject(player, "Purchase could not be completed.")
		return
	player.server_publish_state() # Points, owned items and equipped ammo together.
	var message: String = "Refilled %s ammo" if buying_ammo else "Bought %s"
	player.server_purchase_feedback(message % weapon_name, true)


func _find_player(peer_id: int) -> Player:
	for node: Node in get_tree().get_nodes_in_group("players"):
		# The MultiplayerAPI comparison keeps separate test worlds/sessions isolated.
		if node is Player and node.multiplayer == multiplayer and node.owner_peer_id == peer_id:
			return node as Player
	return null


func _reject(player: Player, reason: String) -> void:
	player.server_purchase_feedback(reason, false)

