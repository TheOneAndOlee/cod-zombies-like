# Lobby, player economy, and wall buys

Press **F5** to open `ui/LobbyMenu.tscn`. Enter a name and port, then host. In another instance, enter another name, the host address (default `127.0.0.1`), and the same port, then join. Only the host sees **Start match**. After starting, the arena creates one avatar per lobby member.

In the arena, the Olympia panel is on the north wall near the training target. Approach it and press **E**. Players start with **500 points** and an M16A1. Olympia costs **500**; its reserve-ammo refill costs **250**. Press **1 / 2** to switch owned weapons. Press **Escape**, then **Disconnect to lobby** to leave.

The training target awards points for accepted hits and kills. This lets you earn refill money after spending your starting balance. Those awards run on the server.

## Files and responsibilities

| File | Responsibility |
| --- | --- |
| `ui/LobbyMenu.tscn`, `ui/LobbyMenu.gd` | Control layout, connection fields, roster, host-only start button |
| `multiplayer_code/lobby_session.gd` | Persistent lobby roster, identity registration, match transition, readiness barrier, navigation |
| `multiplayer_code/multiplayer_utils.gd` | ENet/Steam transport creation and connection-loss signals |
| `multiplayer_code/player_spawner.gd` | Server-owned avatar spawning and despawning after readiness |
| `interactables/WallBuy.tscn`, `interactables/WallBuy.gd` | Shop configuration, proximity/look checks, validated purchase transaction |
| `player/weapon_inventory.gd` | Owned weapon IDs, stable slots, ammo per weapon, equip/refill operations |
| `guns/weapon_catalog.gd` | Allowed weapon IDs and local resources; never loads a path supplied by a client |
| `guns/Olympia/Olympia.tres` | Two-shell shotgun configuration with eight hitscan pellets |
| `player/player.gd` | Points, purchase replay/rate guard, inventory snapshots, owner-only feedback |
| `player/object_interactor.gd` | Local interaction targeting and prompts |
| `player/player_input.gd` | E / 1 / 2 input; sends intent without changing gameplay state |
| `player/player_hud.gd` | Points, equipped weapon/ammo, purchase feedback and Disconnect button |

The previous Player scene's `Head/Camera3D/Guns/Weapon` wrapper is preserved. The camera and ammo crate now use the matching path.

## Lobby scene and inspector setup

```text
LobbyMenu (Control; LobbyMenu.gd)
├── Background (ColorRect)
└── Margin (MarginContainer)
    └── Center (CenterContainer)
        └── Panel (PanelContainer)
            └── Content (VBoxContainer)
                ├── Eyebrow (Label)
                ├── Title (Label)
                ├── Subtitle (Label)
                ├── Fields (GridContainer; 2 columns)
                │   ├── NameLabel (Label)
                │   ├── NameEdit (LineEdit; unique name; max length 24)
                │   ├── AddressLabel (Label)
                │   ├── AddressEdit (LineEdit; unique name; 127.0.0.1)
                │   ├── PortLabel (Label)
                │   └── PortEdit (SpinBox; unique name; editable integer 1–65535)
                ├── ConnectionButtons (HBoxContainer)
                │   ├── HostButton (Button; unique name)
                │   └── JoinButton (Button; unique name)
                ├── RosterTitle (Label; unique name)
                ├── RosterList (ItemList; unique name)
                ├── StatusLabel (Label; unique name; wraps)
                └── SessionButtons (HBoxContainer)
                    ├── DisconnectButton (Button; unique name)
                    └── StartButton (Button; unique name)
```

The root/background/margin use full-rect anchors. Containers handle layout; the panel has a 600-pixel minimum width and the list scrolls as needed. The project uses a 1280 × 800 base canvas and `canvas_items` stretching. The theme contains restrained dark panels and a teal start button. The port's SpinBox also provides an editable text field.

These autoloads are already registered in `project.godot`, in order:

```text
MultiplayerUtils → res://multiplayer_code/multiplayer_utils.gd
LobbySession     → res://multiplayer_code/lobby_session.gd
```

LobbySession must survive the menu being freed. Putting all RPCs on the menu would destroy their destination during scene changes.

## Connection lifecycle and roster

The UI calls the coordinator's normal methods:

```gdscript
LobbySession.host_game("Alice", 7000)
LobbySession.join_game("Bob", "127.0.0.1", 7000)
LobbySession.start_match() # Returns false on clients or outside the lobby phase.
LobbySession.leave_lobby()
```

`connected_to_server` sends the local display name to the server. The server identifies the sender using `get_remote_sender_id()`, rather than accepting a peer ID from the packet. It strips control characters, limits the name to 24 characters, substitutes “Player” for a blank name, and inserts it into `roster[peer_id]`.

The server broadcasts the roster through an authority-only reliable RPC. The ItemList shows names, peer IDs, the host marker, and which entry belongs to this peer. Names are presentation only; peer IDs identify ownership. Duplicate names are allowed.

`peer_connected` handles admission, and `peer_disconnected` removes roster/readiness entries. During gameplay, PlayerSpawner also despawns the departing avatar. `connection_failed` and `server_disconnected` are handled by MultiplayerUtils and forwarded to LobbySession, which closes the session, clears its state, restores the mouse, and opens the menu with a reason.

The menu disables Host/Join and connection fields while connected. Start is visible only for the host and enabled only in the LOBBY phase. The server method repeats those checks: hiding a button is not a security boundary.

Existing Steam transport methods are retained. This new menu uses ENet; it does not add a Steam lobby browser or a Steam-specific roster flow.

## Starting a match safely

The coordinator uses `OFFLINE → CONNECTING → LOBBY → LOADING → MATCH` phases.

1. The host verifies every connected peer has registered a name and closes new admission.
2. It sends `_begin_match(epoch)` using `@rpc("authority", "call_local", "reliable")`. The same transition also runs for the listen host.
3. Every peer changes to the fixed gameplay scene. Clients do not choose arbitrary scene paths.
4. Each new PlayerSpawner reports that its world exists through the persistent LobbySession RPC path. It does not spawn anything yet.
5. The server waits until every expected peer has reported the current match epoch.
6. The server releases the match and calls `PlayerSpawner.release_players(peer_ids)`. MultiplayerSpawner creates and replicates the avatars with the proper owner ID, name, display name, team and pose.

All peers start the same transition together; loading cannot finish at exactly the same wall-clock instant on different computers. The readiness barrier makes “start together” mean **no avatars are spawned before all participating worlds are ready**.

A disconnected peer is removed from the barrier. Clients that fail to report readiness within 25 seconds are rejected, so they cannot block the group forever. A local session-generation token invalidates deferred callbacks from a previous session.

This menu deliberately rejects new connections after loading starts. Direct arena/F6 sessions retain the earlier late-join support. To add join-in-progress to the menu, add an explicit match admission/readiness path rather than bypassing the barrier.

## Player currency and inventory

The Player now includes:

```text
Player (CharacterBody3D; authority 1)
├── ...existing body, hitboxes, input and health...
├── Head/Camera3D
│   ├── ObjectInteractor
│   │   └── InteractRay (mask 9; collide with Areas)
│   └── Guns
│       └── Weapon (Gun; one active weapon simulation)
├── Inventory (Node; WeaponInventory; authority 1)
├── StateSynchronizer (authority 1)
└── HUD (CanvasLayer; local player only)
    ├── Margin/Stats
    ├── Crosshair
    ├── Status
    ├── Controls
    ├── InteractionPrompt
    ├── PurchaseFeedback
    └── Disconnect (Button)
```

Set `Player.starting_points` (default 500) and `maximum_points` in the inspector. Points are authoritative on the server. Trusted server systems can award them:

```gdscript
# Server combat/reward code only. These are ordinary methods, not remote APIs.
var granted: int = player.server_add_points(100)
var paid: bool = player.server_spend_points(250)
```

Negative grants/spending are rejected, awards stop at the configured cap, and spending fails when funds are insufficient. A client calling these methods locally cannot change authoritative currency.

`replicated_state` now includes `points`, `display_name`, and `inventory` alongside the existing health/pose/gun state. The inventory snapshot contains ordered slots, equipped ID, and ammo/mode values for every owned ID. Clients resolve IDs through their local catalog **before** applying the equipped Gun's ammo snapshot, so a two-shell weapon never receives rifle-sized ammo limits.

Inventory defaults to two slots and the `m16a1` starting ID. Buying an unowned weapon fills a free slot and equips it. A full inventory rejects the purchase without discarding any weapon. An already-owned ID buys only its reserve ammo, even when that weapon is holstered; it does not switch weapons or fill its magazine.

The Gun node is reused for the selected weapon. Switching stores the previous weapon's magazine/reserve/mode, cancels its reload/burst, changes configuration, restores the new weapon's ammo, and applies the configured swap delay. Its shared shot cooldown cannot be reset by switching away and back.

Points, owned IDs, slot order and selected weapon persist through respawn. Each owned weapon receives a full magazine plus its configured *starting* reserve on respawn. A new match avatar starts with the initial balance and starting weapon. There is no disk/account persistence.

## WallBuy scene and collision settings

```text
WallBuy (Area3D; WallBuy.gd; server authority 1)
├── CollisionShape3D (BoxShape3D; proximity volume)
├── Panel (MeshInstance3D; dark background)
├── WeaponOutline (Node3D; primitive chalk placeholder)
│   ├── BarrelTop (MeshInstance3D)
│   ├── BarrelBottom (MeshInstance3D)
│   ├── Stock (MeshInstance3D)
│   └── Grip (MeshInstance3D)
├── InteractionPoint (Marker3D; visible face of the panel)
└── Label3D (weapon and prices)
```

Place the root at floor level on a wall, with local **+Z facing the player**. The proximity box is centered forward of the panel. Put InteractionPoint slightly in front of the wall so the wall itself does not obstruct the endpoint. The example arena contains Olympia and M16A1 panels on its north wall.

| Inspector field | Example / meaning |
| --- | --- |
| `weapon_id` | `olympia`; must exist in WeaponCatalog |
| `weapon_name` | `Olympia`; presentation text |
| `cost` | 500 for the first purchase |
| `ammo_cost` | 250 for an owned-weapon reserve refill |
| `max_purchase_distance` | 3 meters from the authoritative camera to InteractionPoint |
| `require_line_of_sight` | Enabled by default |
| `obstruction_mask` | 1, world geometry |

| Object | Layer | Mask / behavior |
| --- | --- | --- |
| World floor/walls | Layer 1, bit 1 | Blocks movement, bullets, and purchase line of sight |
| Player physical body | Layer 2, bit 2 | Existing movement mask 3 |
| Damage hitboxes | Layer 3, bit 4 | Existing ShootRay mask 5 |
| WallBuy | Layer 4, bit 8 | Mask 2 detects physical player bodies; monitoring enabled |
| InteractRay | — | Mask 9 = world + interactables; `collide_with_areas = true` |

WallBuy has no physical blocker of its own. Its Area is for interaction; the actual wall behind it stops movement/bullets.

The local interactor prefers the shop under the reticle. If none is aimed at, it finds the nearest eligible shop whose proximity Area contains the player. The server repeats the look-or-proximity, distance and wall-occlusion checks before accepting the purchase.

E is bound to the existing `Interact` action in Input Map. The old F binding was replaced. Hardware input stays in PlayerInput; ObjectInteractor chooses the target and sends the request.

## Purchase RPC and transaction

The requested annotation is used on the shop:

```gdscript
@rpc("any_peer", "call_local", "reliable", 0)
func request_purchase(request_id: int, life_epoch: int) -> void:
    # Full implementation is in interactables/WallBuy.gd.
```

A remote client calls `focused_shop.request_purchase.rpc_id(1, request_id, player.life_epoch)`. The listen host calls it directly. `call_local` supports local invocation; it does not mean every peer should process a sale. The first line of gameplay validation is `multiplayer.is_server()`.

The server performs these checks:

1. Resolve the requesting player's avatar from the transport sender. A direct local call maps to the listen host, peer 1.
2. Reject missing avatars, old-life requests, repeated request IDs, and requests less than 0.25 seconds apart. The request guard belongs to Player, so changing shop nodes cannot bypass it.
3. Require a living player near the panel, either inside its Area or aiming at it, with clear line of sight.
4. Require a catalog-approved weapon ID and nonnegative configured prices.
5. Determine first purchase versus refill from the **server's** inventory.
6. Reject a full inventory, already-full reserve, or insufficient balance.
7. Deduct the server's price and grant the weapon/refill synchronously, with no `await` between those operations. Refund immediately if the inventory operation unexpectedly rejects the grant.
8. Publish one updated player snapshot and send reliable feedback only to that player.

The packet does **not** contain a requested player ID, price, currency balance, resource path, weapon stats or ammunition amount. Editing a client's WallBuy or Player properties cannot change the corresponding server values.

The HUD only displays synchronized points and inventory. A separate authority-only feedback RPC produces messages such as “Not enough points — need 250 more.” Successful purchases show green feedback, failed purchases red. Feedback never changes gameplay state.

## Adding weapons and wall buys

1. Duplicate a `Gun_Properties` resource and configure damage, magazine/reserve limits, spread, RPM, firing mode, range, pellets and swap timing.
2. Add the resource under a stable ID in `WeaponCatalog.WEAPONS` and a label in `DISPLAY_NAMES`.
3. Instance WallBuy.tscn and choose that ID, display name, weapon cost and ammo cost.
4. Place it on clear wall geometry and ensure its proximity Area and InteractionPoint face the room.
5. Distribute matching catalog assets to server and clients.

Olympia fires eight server-traced pellets per shell. The primitive first-person model remains a placeholder; set the weapon resource's `model` to replace it. Shot effects and recoil fire once per trigger, and PvE scoring grants hit points once per damaged target per trigger, rather than once per pellet.

PvE rewards require the damaged actor to be in `pve_enemies` and to use HealthComponent. Rewards occur only after damage is accepted. The weapon's existing hit/body-kill/headshot-kill point settings determine the amount. PvP damage does not award these rewards.

## Validation

Run `./tests/run_tests.ps1` from the project directory. It checks existing combat/movement and networking behavior, wall-buy validation and replication, legacy spawning, and the full menu → lobby → all-ready match → disconnect lifecycle using real local ENet processes.

The optional `tests/menu_visual_test.gd` renders the lobby and an actual purchase using Godot's compatibility renderer, saving ignored preview PNGs in tests. It runs without `--headless`.

Internet latency, Steam relay accounts, host migration, persistent currency and player authentication are outside this implementation. Display names are not account identities. The existing FPS's prediction/lag-compensation limitations still apply.

The networking behavior follows Godot's official [RPC authority and connection-signal rules](https://docs.godotengine.org/en/stable/tutorials/networking/high_level_multiplayer.html), [custom MultiplayerSpawner flow](https://docs.godotengine.org/en/stable/classes/class_multiplayerspawner.html), and [server-owned property replication](https://docs.godotengine.org/en/stable/classes/class_multiplayersynchronizer.html).

