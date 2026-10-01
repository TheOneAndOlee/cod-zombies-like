class_name WeaponCatalog
extends RefCounted
## The server accepts only these IDs. A client never supplies a resource path,
## damage value, ammo capacity or purchase price to create a weapon.

const WEAPONS: Dictionary = {
	"m16a1": preload("res://guns/M16A1/M16A1.tres"),
	"olympia": preload("res://guns/Olympia/Olympia.tres"),
}

const DISPLAY_NAMES: Dictionary = {
	"m16a1": "M16A1",
	"olympia": "Olympia",
}


static func has_weapon(weapon_id: String) -> bool:
	return WEAPONS.has(weapon_id)


static func get_properties(weapon_id: String) -> Gun_Properties:
	# Shared immutable configuration; each inventory stores its own ammunition.
	return WEAPONS.get(weapon_id) as Gun_Properties


static func get_display_name(weapon_id: String) -> String:
	return str(DISPLAY_NAMES.get(weapon_id, "Unknown weapon"))
