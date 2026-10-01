# Headless regression checks

Run from the project folder using the installed Godot executable:

```powershell
./tests/run_tests.ps1
# Or specify another engine installation:
./tests/run_tests.ps1 -Godot 'C:/Path/To/Godot.exe'
```

The runner waits for Windows GUI executables, checks process exit codes and scans logs for engine/script errors. It runs combat/movement, localhost ENet, and wall-buy purchase assertions, plus separate three-process spawning and lobby scenarios. The spawning scenario also checks current PvE target health, consumed ammo pickup state, and both client despawns.

For individual tests (use absolute log paths so Godot writes inside the project):

```powershell
godot --headless --editor --path . --log-file "$PWD/tests/import.log" --quit
godot --headless --path . --log-file "$PWD/tests/combat.log" --script res://tests/combat_test.gd
godot --headless --path . --log-file "$PWD/tests/network.log" --script res://tests/network_test.gd
godot --headless --path . --log-file "$PWD/tests/wall_buy.log" --script res://tests/wall_buy_test.gd
```

The first command imports resources and registers global script classes. Replace `godot` with your installed executable if it is not on `PATH`. These checks never initialize Steam or open a game window. Logs stay inside the project folder. A failed check returns a nonzero process exit code. Watchdogs stop tests that cannot complete within their configured timeout.

The test suites use UDP ports 24873–24876. The multi-process cases have connection watchdogs; the runner only stops processes it launched. Godot in this restricted environment logs an unavailable Windows root certificate store at startup. The runner exempts that specific unrelated startup message; all other engine/script errors fail validation.

`combat_test.gd` uses the real Player scene and physics world to check body hits, headshots, wall occlusion, team filtering, invalid damage, ammunition accounting, firing modes, reloads, firing cooldowns, death, respawn, acceleration, stopping, sprinting, jumping, pitch clamping, stale input and request budgets.

`network_test.gd` creates two independent MultiplayerAPI branches connected by localhost ENet on UDP port 24873. It checks ownership validation using real RPC packets, rejects client-side server-method calls, and checks replicated damage, death and respawn. It does not require Steam accounts or two running game windows.

`wall_buy_test.gd` uses real wall-buy scenes, physics line of sight, and local ENet RPCs. It checks purchase prices, point balances, duplicate and stale-life requests, rate limits, range and wall occlusion, invalid catalog IDs, insufficient funds, inventory capacity, ammo purchases, and refilling an unequipped weapon. Forged client position, currency and price values must not affect the authoritative purchase.

`lobby_smoke_test.gd` starts a host and two clients through the actual menu/lobby API. It checks name-to-peer-ID mappings, host-only match start, the loading readiness barrier, avatar names and authority, voluntary client departure, host loss, and return-to-menu cleanup for every peer.

The current suites pass 53 combat checks, 25 network checks, and 52 wall-buy/economy checks, plus both three-process scenarios. Economy checks include accepted PvE hit/kill rewards, rejected damage, point caps, and owner-only low-funds feedback.

`menu_visual_test.gd` is an optional rendered check outside the headless runner. Run it without `--headless`, with `--rendering-method gl_compatibility`. It uses UDP port 24877 and saves `lobby_preview.png`, `wall_buy_preview.png`, and `purchase_preview.png` under `tests/`. These generated previews are ignored. It verifies an actual Olympia purchase and records the lobby, prompt, balance, and feedback for visual inspection.

These deterministic tests do not measure internet latency, packet loss, the Steam relay service, or rendered camera behavior. Test those with two game instances as described in the controller guide.
