class_name WeaponInventory
extends Node
## Owns weapon IDs and per-weapon ammo. One Gun node presents/simulates the
## equipped weapon. Only server game rules can grant, refill or switch items.

signal inventory_changed
signal weapon_equipped(weapon_id: String)

@export var starting_weapon_id: String = "m16a1"
@export_range(1, 8) var max_weapon_slots: int = 2

var equipped_weapon_id: String = ""
var owned_weapons: Dictionary = {}
## Explicit ordering makes slots stable on every peer, independent of sorting.
var weapon_slots: Array[String] = []
var _gun: Gun


func server_initialize(gun: Gun) -> void:
	# Binding is harmless on clients; only the server grants the starting item.
	_gun = gun
	if not multiplayer.is_server() or not owned_weapons.is_empty():
		return
	var initial_id: String = starting_weapon_id
	if not WeaponCatalog.has_weapon(initial_id):
		push_warning("Unknown starting weapon '%s'; using m16a1." % initial_id)
		initial_id = "m16a1"
	owned_weapons[initial_id] = _new_ammo_state(initial_id, false)
	weapon_slots.append(initial_id)
	_equip(initial_id, false)


func has_weapon(weapon_id: String) -> bool:
	return owned_weapons.has(weapon_id)


func can_add_weapon(weapon_id: String) -> bool:
	return WeaponCatalog.has_weapon(weapon_id) and not has_weapon(weapon_id) and weapon_slots.size() < max_weapon_slots


func server_buy_weapon(weapon_id: String) -> bool:
	# Wall-buy code checks range, price and points before calling this method.
	if not multiplayer.is_server() or _gun == null or not can_add_weapon(weapon_id):
		return false
	_save_equipped_ammo()
	owned_weapons[weapon_id] = _new_ammo_state(weapon_id, true)
	weapon_slots.append(weapon_id)
	_equip(weapon_id, true)
	return true


func server_refill_weapon(weapon_id: String) -> bool:
	if not multiplayer.is_server() or _gun == null or not has_weapon(weapon_id) or not WeaponCatalog.has_weapon(weapon_id):
		return false
	_save_equipped_ammo()
	if is_reserve_full(weapon_id):
		return false
	var configuration: Gun_Properties = WeaponCatalog.get_properties(weapon_id)
	if weapon_id == equipped_weapon_id:
		_gun.server_add_ammo(configuration.max_reserve_ammo)
		_save_equipped_ammo()
	else:
		# Buying ammo for a holstered weapon must not equip it or fill its magazine.
		owned_weapons[weapon_id]["reserve"] = configuration.max_reserve_ammo
	inventory_changed.emit()
	return true


func is_reserve_full(weapon_id: String) -> bool:
	if not has_weapon(weapon_id) or not WeaponCatalog.has_weapon(weapon_id):
		return false
	var reserve: int = int(owned_weapons[weapon_id].get("reserve", 0))
	if weapon_id == equipped_weapon_id and _gun != null:
		reserve = _gun.reserve_ammo
	return reserve >= WeaponCatalog.get_properties(weapon_id).max_reserve_ammo


func server_equip_slot(index: int) -> bool:
	if not multiplayer.is_server() or _gun == null or index < 0 or index >= weapon_slots.size():
		return false
	var weapon_id: String = weapon_slots[index]
	if weapon_id == equipped_weapon_id:
		return false
	_save_equipped_ammo()
	_equip(weapon_id, true)
	return true


func server_reset_for_respawn() -> void:
	if not multiplayer.is_server() or _gun == null:
		return
	if owned_weapons.is_empty():
		server_initialize(_gun)
		return
	# Preserve purchases and the selected slot; replenish each configured loadout.
	for weapon_id: String in weapon_slots:
		owned_weapons[weapon_id] = _new_ammo_state(weapon_id, false)
	_gun.server_reset()
	_equip(equipped_weapon_id, false)


func capture_state() -> Dictionary:
	if multiplayer.is_server():
		_save_equipped_ammo()
	return {"equipped": equipped_weapon_id, "slots": weapon_slots.duplicate(),
		"weapons": owned_weapons.duplicate(true)}


func apply_network_state(state: Dictionary) -> void:
	# Player calls this from its server-owned snapshot BEFORE applying gun ammo.
	# Only catalog IDs cross the network; weapon resources are loaded locally.
	var previous_id: String = equipped_weapon_id
	var incoming_weapons: Dictionary = state.get("weapons", {})
	weapon_slots.clear()
	owned_weapons.clear()
	for value: Variant in state.get("slots", []):
		var weapon_id: String = str(value)
		if WeaponCatalog.has_weapon(weapon_id) and incoming_weapons.has(weapon_id) and not owned_weapons.has(weapon_id):
			weapon_slots.append(weapon_id)
			owned_weapons[weapon_id] = (incoming_weapons[weapon_id] as Dictionary).duplicate(true)
	equipped_weapon_id = str(state.get("equipped", ""))
	if not owned_weapons.has(equipped_weapon_id):
		equipped_weapon_id = weapon_slots[0] if not weapon_slots.is_empty() else ""
	if _gun != null and not equipped_weapon_id.is_empty():
		_gun.set_weapon_properties(WeaponCatalog.get_properties(equipped_weapon_id))
	if equipped_weapon_id != previous_id:
		weapon_equipped.emit(equipped_weapon_id)
	inventory_changed.emit()


func _equip(weapon_id: String, use_swap_delay: bool) -> void:
	equipped_weapon_id = weapon_id
	_gun.server_equip_weapon(WeaponCatalog.get_properties(weapon_id), owned_weapons[weapon_id], use_swap_delay)
	weapon_equipped.emit(weapon_id)
	inventory_changed.emit()


func _save_equipped_ammo() -> void:
	if _gun == null or not owned_weapons.has(equipped_weapon_id):
		return
	owned_weapons[equipped_weapon_id] = {"magazine": _gun.magazine_ammo,
		"reserve": _gun.reserve_ammo, "mode": _gun.current_firing_type}


func _new_ammo_state(weapon_id: String, full_reserve: bool) -> Dictionary:
	var configuration: Gun_Properties = WeaponCatalog.get_properties(weapon_id)
	var reserve: int = configuration.max_reserve_ammo if full_reserve else configuration.reserve_ammo
	return {"magazine": maxi(1, configuration.mag_size),
		"reserve": clampi(reserve, 0, maxi(0, configuration.max_reserve_ammo)),
		"mode": configuration.current_firing_type}
