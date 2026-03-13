# Project Guidelines

## Code Style
- Use typed GDScript (`var x: Type`, typed returns) and snake_case naming, matching patterns in `components/player.gd`, `multiplayer/lobby.gd`, and `ui/main_menu.gd`.
- Keep script structure consistent: constants/enums/state first, then `_ready`/`_process`/`_input`, then helpers/RPC handlers.
- Prefer signal-driven flow over polling when a signal already exists (examples: `multiplayer/lobby.gd`, `ui/chat.gd`, `maps/lps_manager.gd`).
- Keep edits minimal and local; preserve existing section-divider comment style used across UI/multiplayer scripts.

## Architecture
- Entry scene is `res://ui/MainMenu.tscn` (see `project.godot`), with global state in autoloads (`GameSettings`, `GameLobby`, `EOSBootstrap`).
- Core flow: `ui/MainMenu.tscn` → `multiplayer/ConnectScreen.tscn` → `multiplayer/LobbyRoom.tscn` → `multiplayer/SelectionScreen.tscn` → map scenes via `maps/main.gd`.
- `maps/main.gd` instantiates players and delegates mode logic to managers (`maps/lps_manager.gd`, `maps/banana_frenzy_manager.gd`, `maps/tag_manager.gd`).
- Keep cross-scene state in `scripts/game_settings.gd` (round/match selections, chat history, disconnect messaging), not in transient scene nodes.

## Build and Test
- Engine target is Godot `4.6.1` (see `.github/workflows/export.yml`, `SETUP_EOS.md`).
- Local run (editor): open project and run main scene (`res://ui/MainMenu.tscn`).
- Local run (CLI): `godot --path .`
- Headless export (Windows preset): `godot --headless --export-release "Windows Desktop" "build/windows/monke.exe"`
- No automated test suite is currently present in this workspace; validate by running affected scenes/flows in editor.

## Project Conventions rizz lord
- Input actions come from `project.godot`; do not hardcode alternate action names without updating input map.
- Scene transitions use `get_tree().change_scene_to_file(...)` and usually include cleanup (mouse mode, network disconnect/reset, UI state).
- For 3D card UIs, keep the existing SubViewport-to-quad forwarding approach (`ui/main_menu.gd`, `multiplayer/selection_screen.gd`).
- For multiplayer changes, keep host-authoritative RPC patterns and peer ID/state handling in `multiplayer/lobby.gd`.

## Integration Points
- EOS integration is bootstrapped by `multiplayer/eos_bootstrap.gd` and autoloaded EOS helpers configured in `project.godot`.
- Networking supports EOS and ENet fallback; preserve both paths in `multiplayer/lobby.gd` and `multiplayer/connect_screen.gd`.
- Plugin code under `addons/` is third-party; prefer integrating via project scripts unless a plugin fix is required.

## Security
- Treat `eos_credentials.cfg` as sensitive (contains client credentials). Never print or commit secrets in code/comments/logs.
- Use `eos_credentials.cfg.template` as the format reference and environment/CI secrets for real values.
- Follow the CI pattern in `.github/workflows/export.yml` (inject secrets at build time, copy config to runtime output).
- If updating setup docs or EOS code, keep guidance aligned with current config-file loading in `multiplayer/eos_bootstrap.gd`.

## SUPER IMPORTANT
- Always make scenes with nodes, and use resources rather than trying to create things purely in code. This is a Godot project, not a pure codebase. The scene system is a core part of how the project is structured and how things are instantiated and managed. Avoid trying to bypass it or create things purely in code (scripts) unless absolutely necessary for dynamic content.

- Utilize the Godot MCP to help create scenes and resources, and to understand how to structure things in a way that fits with Godot's architecture. The MCP can provide guidance on best practices for scene organization, resource management, and how to leverage Godot's features effectively.