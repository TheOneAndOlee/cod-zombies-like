# Multiplayer FPS controller

This project has a runnable server-authoritative FPS foundation. Press **F5** for the multiplayer lobby, or **F6** on `levels/test_level.tscn` for direct offline play. See [Lobby and wall buys](LOBBY_AND_WALL_BUYS.md) for the new menu, economy, inventory, scene additions and loading barrier. Offline play uses the same server simulation as multiplayer.

The scripts use Godot 4 GDScript. Validation was performed with the installed Godot 4.7.2 build. Existing `Gun_Properties`, input action names, and `MultiplayerUtils.host_lobby(lobby_type, num_players)` remain available.

## Scene hierarchy

The complete `player/player.tscn` hierarchy is:

```text
Player (CharacterBody3D)                  player.gd; server authority = 1
├── CollisionShape3D                     capsule; feet at root origin
├── BodyMesh (MeshInstance3D)             hidden for the local player
├── BodyHitbox (Area3D)                   damage_hitbox.gd; body damage
│   └── CollisionShape3D                 box
├── HeadHitbox (Area3D)                   damage_hitbox.gd; headshot damage
│   └── CollisionShape3D                 sphere
├── Head (Node3D)                         eye height 1.6 m; pitch rotates here
│   └── Camera3D                         camera_controller.gd; local only
│       ├── ShootRay (RayCast3D)          camera center; server hit detection
│       ├── Guns (Node3D)                weapon presentation container
│       │   └── Weapon (Node3D)          gun.gd; selected catalog configuration
│       │       └── ViewModel (Node3D)    local cosmetic recoil
│       │           ├── Receiver (MeshInstance3D)
│       │           ├── Barrel (MeshInstance3D)
│       │           ├── Magazine (MeshInstance3D)
│       │           └── Muzzle (Marker3D)
│       └── ObjectInteractor (Node3D)     local wall-buy targeting and prompts
│           └── InteractRay (RayCast3D)
├── PlayerInput (Node)                    player_input.gd; authority = owner_peer_id
├── Health (Node)                         health_component.gd
├── Inventory (Node)                      weapon_inventory.gd
├── StateSynchronizer (MultiplayerSynchronizer)
└── HUD (CanvasLayer)                     player_hud.gd; local only
    ├── Margin (MarginContainer)
    │   └── Stats (Label)
    ├── Crosshair (Label)
    ├── Status (Label)
    ├── Controls (Label)
    ├── InteractionPrompt (Label)
    ├── PurchaseFeedback (Label)
    └── Disconnect (Button)
```

The world owns spawning, rather than each avatar owning its own spawner:

```text
TestLevel (Node3D)
├── WorldEnvironment
├── Sun (DirectionalLight3D)
├── Arena (Node3D)                        floor, walls, cover, label
├── SpawnPoints (Node3D)
│   ├── South / North / East / West (Marker3D)
│   └── SouthEast / NorthWest / NorthEast / SouthWest (Marker3D)
├── Players (Node3D)                      keep this transform at identity
│   └── <peer_id> (instanced Player)      created only by the server
├── TrainingTarget (StaticBody3D)         reusable PvE damage example
├── AmmoPickup (Area3D)                   server checks body overlap
└── PlayerSpawner (MultiplayerSpawner)   player_spawner.gd; spawn_path = ../Players
```

Keep the same node names and paths on every peer: Godot routes RPCs using matching paths.

## Controls

| Control | Action |
| --- | --- |
| WASD / arrow keys | Move |
| Space | Jump |
| Left Shift | Sprint forward |
| Mouse | Look; pitch clamped to -89° through +89° |
| Left mouse button | Fire |
| Right mouse button | Aim down sights |
| R | Reload |
| X | Cycle configured fire modes |
| E | Buy a wall weapon or refill its reserve ammo |
| 1 / 2 | Equip owned weapon slots |
| Escape | Toggle mouse capture |
| Click with mouse released | Capture the mouse |
| Enter | Request respawn when dead and the server timer has expired |

Automatic respawn is enabled by default after three seconds. Disable `Player.auto_respawn` for manual respawn. Losing window focus releases mouse capture and stops gameplay input.

## Who owns what, and why?

`owner_peer_id` means “the person controlling this avatar.” Godot's *multiplayer authority* means “the peer allowed to publish authoritative state.” Those are different concepts here.

The server keeps authority over the root Player, Health, Gun and StateSynchronizer. Only the PlayerInput child receives the controlling peer's authority. The spawner assigns `owner_peer_id` before adding the scene; `Player._enter_tree()` then sets authority before children enter their ready callbacks.

- `PlayerInput.is_multiplayer_authority()` prevents remote avatars from reading this computer's keyboard or mouse.
- `Player.is_local_player()` compares the controlling ID against this peer for the camera and HUD. Checking authority on the root Player would incorrectly make every avatar local on the server.
- `multiplayer.is_server()` guards physics, shots, ammo grants, health changes, and respawn. A client editing its own script does not change server state.
- On every input RPC, the server compares `get_remote_sender_id()` with `owner_peer_id`. An `any_peer` annotation alone does not establish ownership.

Headless servers enable no camera or hardware input. Remote camera setup uses `clear_current(false)` so Godot cannot automatically select another remote avatar's camera.

## RPCs and synchronization

This implementation uses **validated input RPCs plus a server-owned MultiplayerSynchronizer**. They solve different problems.

| Message | Sender → receiver | Delivery |
| --- | --- | --- |
| `submit_input(sequence, epoch, movement, look, sprint, fire, ads)` | Owner → server | Unreliable ordered, channel 1, 30 Hz |
| `request_action(action, epoch, look)` | Owner → server | Reliable, channel 0 |
| `replicated_state` | Server → visible clients | Synchronizer ALWAYS mode, 30 Hz |
| `Gun._play_shot(origin, destination, hit)` | Server → visible clients | Unreliable ordered, channel 2 |

Input packets contain the whole held-button state, so losing one packet does not require retransmitting it. Reliable actions preserve quick fire taps, jumps, reloads, mode changes, and respawn requests. The listen host calls these methods directly through the same validation path instead of sending an RPC to itself.

The requested `@rpc("any_peer", "call_local", "reliable")` annotation is **not a firing verification system by itself**. It would let every peer invoke the function. A safe version must still send to peer 1, check that execution is on the server, validate the sender, and enforce all weapon rules. Here requests use `"call_remote"`; only the server-approved cosmetic event uses `"authority"` and `"call_local"`.

Do not synchronize client-written position, health, ammo, or hit results. Do not transfer the entire Player node's authority to its client.

The synchronizer sends one dictionary containing position, look, velocity, health/hurt state, weapon state, life epoch, and respawn countdown. That atomic snapshot prevents mixing a new life with an old position. A snapshot sequence ignores older snapshots. The snapshot is also a spawn property, so late joiners receive current state. Full snapshots repeat: a lost state update is corrected by the next one.

The server validates finite vectors, normalizes movement, clamps pitch, rejects duplicate input sequences and wrong life epochs, caps accepted input/action messages per second, and releases held input after 0.35 seconds without a valid packet. None of these packets supplies a simulation delta, damage amount, shot origin, victim, or respawn location.

## Movement and responsiveness

The server applies gravity, accelerates horizontal velocity toward a target, decelerates on release, and calls `move_and_slide()`. Jumping requires floor contact. Sprinting requires forward input and ends while aiming. Weapon movement multipliers apply to walking and sprinting.

Clients interpolate toward server positions. The owner's view rotation responds immediately to mouse movement. Movement does **not** include client prediction/reconciliation, and shots do **not** rewind historical target positions for lag compensation. This keeps the baseline readable and its authority model consistent, but remote movement and firing have noticeable latency on internet connections.

For a competitive shooter, add prediction/reconciliation, buffered remote interpolation, and server-validated lag compensation as separate systems. The current authority checks stop clients from directly choosing hits or health; they are not a complete anti-cheat system and cannot stop aim assistance or a dishonest host.

## Weapons and customization

Select `Head/Camera3D/Guns/Weapon` for weapon presentation. Configure weapon stats/range in the catalog's `Gun_Properties` resources. Duplicate `guns/M16A1/M16A1.tres` and register a new ID in WeaponCatalog to create another purchasable weapon.

Implemented settings include RPM, damage, headshot multiplier, automatic/semi-automatic/burst fire, burst count/pause, available firing modes, magazine capacity, starting/capped reserve bullets, reload duration, automatic reload, hip/ADS spread, and movement multipliers. Mutable ammo and timers belong to each Gun node, so players can safely share a resource.

The server fires the camera's ShootRay after applying validated look and movement. It samples spread on the server, calls `force_raycast_update()`, and damages the first eligible hit. World geometry blocks the ray. All of the shooter's collision objects are excluded.

The fire interval is `60.0 / fire_rate`. Timers use server physics time; repeatedly sending requests cannot bypass cooldown, reload, death, or ammunition checks. At most one round is emitted per physics tick. Bursts finish after trigger release but stop on death, reload, mode changes, respawn, or a prohibited sprint.

Reloading transfers `min(missing_rounds, reserve_ammo)` from reserves into the magazine. A partial reload never invents ammo. The HUD shows loaded bullets, reserve bullets, and the number of complete magazine refills available in reserve.

The camera uses ADS/sprint FOV and a simple local view-model recoil kick. Recoil is a **cosmetic placeholder**; it does not force server aim upward. Server-generated spread is the gameplay accuracy mechanism. `shot_fired` is the extension point for audio, tracers, muzzle flashes, and impact effects. An optional `properties.model` scene replaces the primitive model inside ViewModel.

Inventory switching and PvE point awards are implemented in the lobby/wall-buy extension. Swap timing gates firing; the ADS animation timing and horizontal recoil fields remain presentation hooks. Projectiles and full animation systems are not implemented.

## Health, teams, enemies and ammo

`HealthComponent` works on players and AI actors. Server damage goes through:

```gdscript
# Run from server AI/combat logic after validating an actual attack.
victim.health.server_take_damage(20.0, attacker_peer_id, attacker_team_id)
```

The interface returns whether damage was accepted. It rejects negative/non-finite damage and repeated damage to a dead actor. Signals are `health_changed(current, maximum)`, `damaged(amount, attacker_peer_id)`, and `died(attacker_peer_id)`. Its snapshot carries health, maximum health, hurt duration remaining, and last attacker.

For free-for-all, leave `team_id = -1`. For cooperative players, assign a shared nonnegative team in the server spawner and leave `allow_friendly_fire = false`. The target uses team 99. Friendly-fire filtering is configured on the victim's HealthComponent. Team values come from server actors, never fire packets.

An AI actor can add HealthComponent and DamageHitbox areas, or implement:

```gdscript
func server_take_damage(amount: float, attacker_peer_id: int, attacker_team: int) -> bool:
    return $Health.server_take_damage(amount, attacker_peer_id, attacker_team)
```

Synchronize its health using the same server snapshot approach as `combat/training_target.gd`. The supplied target resets five seconds after death; replace its behavior with AI without modifying the weapon.

Physics layers are configured as:

| Layer | Bit mask | Use |
| --- | --- | --- |
| 1 | 1 | World walls, floor and cover |
| 2 | 2 | Physical player/target bodies |
| 3 | 4 | DamageHitbox areas |

Player movement uses mask 3 (world + physical bodies). ShootRay uses mask 5 (world + damage hitboxes). Separate hitboxes keep the physical capsule from swallowing headshots. All damageable custom actors need either a hitbox on layer 3 or a ray-visible collider with the damage interface.

Ammo replenishment is a server method:

```gdscript
# Call only after the server validates the pickup/reward.
var accepted: int = player.gun.server_add_ammo(60)
```

The supplied ammo crate checks authoritative body overlap and grants up to the reserve cap. It is consumed only if at least one round fits, then returns after ten seconds. Players at full reserve cannot waste it.

## Death and respawn

Death zeroes velocity, clears held/queued commands, cancels reload/burst state, disables physical and damage collision shapes, and starts the server countdown. The avatar remains spawned so its network path stays stable.

After the delay, Player emits `respawn_requested(player)`. PlayerSpawner chooses a configured marker furthest from living players and calls `server_respawn(transform)`. With no spawner listener, the player falls back to its initial spawn.

Respawn increments `life_epoch`, teleports, restores health and starting ammo for every owned weapon, clears velocity/look pitch/cooldowns/commands, and publishes a snapshot. Points, owned weapon IDs, and the selected weapon persist. Clients snap on an epoch change rather than sliding through the map. Packets sent before death carry the old epoch and cannot affect the new life.

Place spawn markers in clear floor space. The demo's distance selection does not perform a general map collision search or guarantee safety from enemies; custom game rules should select valid spawn regions and can add spawn protection.

## Existing lobby integration

`MultiplayerUtils` sets up the transport. `PlayerSpawner` creates/removes avatars. The previous utility's manual `_add_player()` path was replaced to avoid local-only and duplicate instances.

Your lobby can keep calling `host_lobby(lobby_type, num_players)` and call `join_lobby(lobby_id)` to join. Steam initialization is lazy, so offline and ENet do not initialize Steam. The utility pumps Steam callbacks when embedded callbacks are disabled. It requires a GodotSteam build exposing both Steam and SteamMultiplayerPeer; app ID 480 remains the development default.

For another transport, set `multiplayer.multiplayer_peer` and load this arena on every peer, with the server world loaded before clients announce readiness. If replacing the transport in an already loaded arena, use the utility APIs so `session_ended` clears the old avatars and `session_started` starts the new session.

The custom spawn callback sets the avatar name, owner, team, and initial pose before adding it. Clients send a reliable world-ready message only once their level exists. The server derives their ID from the sender and enables existing/new avatar visibility. Static demo target/pickup synchronizers use the `world_state_sync` group and the same readiness gate. Disconnecting despawns that player's avatar on all peers.

To use your own gameplay level, copy Players, SpawnPoints and PlayerSpawner, preserve matching paths across peers, and configure the spawner's exported scene/marker paths. Add static synchronizers to `world_state_sync` with public visibility disabled. Runtime-spawned AI should use its own server-owned MultiplayerSpawner.

Steam relay behavior requires a real two-account integration test; it was not exercised by the local ENet checks.

## Running two peers

From this project directory, replace `godot` with your installed executable:

```powershell
# Listen host
godot --path . -- --host --port=7000

# Second instance; replace the address for another machine
godot --path . -- --join=127.0.0.1 --port=7000

# Optional dedicated server: no host avatar
godot --headless --path . -- --dedicated --port=7000
```

On this computer the engine is `D:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe`. In PowerShell, prefix the quoted path with `&`.

Check that each visible instance has one active local camera, movement only controls its own avatar, the other avatar moves, body/head hits reduce the remote health, walls block hits, reload and ammo counts agree, dead actors cannot fire, and respawn agrees. Join during a match and disconnect a peer to inspect spawn/despawn behavior.

See `tests/README.md` for automated combat, movement, ownership, replication and multi-process spawning checks.

## Godot references

The design follows the official [high-level multiplayer RPC and authority rules](https://docs.godotengine.org/en/stable/tutorials/networking/high_level_multiplayer.html), [MultiplayerSynchronizer property replication](https://docs.godotengine.org/en/stable/classes/class_multiplayersynchronizer.html), [MultiplayerSpawner custom spawning](https://docs.godotengine.org/en/stable/classes/class_multiplayerspawner.html), and [RayCast3D immediate collision queries](https://docs.godotengine.org/en/stable/classes/class_raycast3d.html).

