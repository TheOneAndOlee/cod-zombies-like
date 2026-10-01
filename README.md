# COD Zombies Like

A Godot 4 multiplayer FPS foundation with server-controlled movement, hitscan combat, health and respawning.

Open `project.godot` and press F5 for the multiplayer lobby. Host or join, then the host starts the arena once everyone is connected. F6 on `levels/test_level.tscn` still supports direct offline play.

Players start with 500 points. Buy Olympia at the north-wall panel with E, switch weapons with 1/2, and earn refill points by shooting the PvE target. Escape exposes the Disconnect button.

Read [the lobby and wall-buy guide](docs/LOBBY_AND_WALL_BUYS.md) for node trees, inspector settings, server validation, currency, inventory, and match-loading flow.

Read [the controller guide](docs/FPS_CONTROLLER.md) for the complete Player scene hierarchy, authority/RPC explanations, configuration, PvE interfaces, lobby integration, controls and multiplayer commands. See [the tests guide](tests/README.md) for automated validation.

The baseline uses immediate local mouse-look and server-authoritative movement with client interpolation. Client movement prediction and lag-compensated hit detection remain extension work.
