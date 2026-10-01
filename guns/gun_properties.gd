class_name Gun_Properties
extends Resource
## Shared weapon configuration. Current ammo and timers belong to each Gun node.

enum FIRE_TYPE { FULL_AUTO, BURST, SEMI_AUTO }
enum BULLET_TYPE { HITSCAN, PROJECTILE }

@export_group("Damage and firing")
## Rounds per minute. Also controls the spacing between bullets in a burst.
@export_range(1.0, 3000.0) var fire_rate: float = 600.0
@export var current_firing_type: FIRE_TYPE = FIRE_TYPE.FULL_AUTO
@export_range(0.0, 1000.0) var bullet_damage: float = 25.0
## Shotguns trace several pellets, but consume one round from the magazine.
@export_range(1, 32) var pellets_per_shot: int = 1
@export_range(1.0, 3000.0) var shot_range: float = 150.0
@export var headshottable: bool = true
@export_range(1.0, 10.0) var headshot_multiplier: float = 2.5
@export_range(1, 10) var bullets_per_burst: int = 3
## Extra delay after the last shot of a burst, in seconds.
@export_range(0.0, 2.0) var burst_pause: float = 0.18
@export var switchable_firing_modes: bool = true
@export var possible_firing_modes: Array[FIRE_TYPE] = [FIRE_TYPE.FULL_AUTO, FIRE_TYPE.SEMI_AUTO]

@export_group("Ammunition")
@export_range(1, 500) var mag_size: int = 30
## Starting reserve bullets, excluding the loaded magazine.
@export_range(0, 5000) var reserve_ammo: int = 120
@export_range(0, 5000) var max_reserve_ammo: int = 240
@export_range(0.05, 20.0) var reload_time: float = 1.8
@export var auto_reload_when_empty: bool = true

@export_group("Spread and recoil")
## Server chooses the random direction inside this cone; clients cannot choose hits.
@export_range(0.0, 20.0) var hip_spread_degrees: float = 1.25
@export_range(0.0, 20.0) var ads_spread_degrees: float = 0.15
## Presentation hooks in degrees. Recoil never supplies a trusted hit result.
@export var recoil_strength_x: float = 0.25
@export var recoil_strength_y: float = 0.8
@export var recoil_increase_speed: float = 20.0
@export var recoil_recovery_speed: float = 8.0

@export_group("Movement multipliers")
## Legacy names retained: 1.0 means full speed, 0.0 means no movement.
@export_range(0.0, 1.0) var mobility_penalty: float = 1.0
@export_range(0.0, 1.0) var hipfire_mobility_penalty: float = 0.85
@export_range(0.0, 1.0) var ads_mobility_penalty: float = 0.65
@export_range(0.0, 1.0) var ads_firing_mobility_penalty: float = 0.55

@export_group("Presentation hooks")
@export var ads_enter_time: float = 0.25
@export var ads_exit_time: float = 0.25
@export var swap_to_time: float = 0.5
@export var swap_from_time: float = 0.5
@export var model: PackedScene

@export_group("PvE scoring hooks")
@export var point_per_shot: float = 10.0
@export var point_per_headshot_kill: float = 100.0
@export var point_per_body_kill: float = 40.0
