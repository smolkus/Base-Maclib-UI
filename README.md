# Base Maclib UI

Works together with Jexvral Account Manager V2: see GUIDE.md, "Jexvral Hub",
and `docs/HUB.md` in that repo.

A game-agnostic executor hub template built on MacLib, with the proven
module system from the Anime Expeditions project. Copy this folder as the
starting point for new game scripts; write only game modules, keep the
core untouched.

## Layout

```text
loader.lua            Manifest-based loader: multi-repo fallback, prefetch
                      pool, dependency-graph Import, error diagnostics.
manifest.lua          Module name -> source path map (any nesting depth).
src/Build.lua         Hub name, version, repository/raw URLs, data root.
src/Core/             Game-agnostic infrastructure (do not modify per game):
  Util.lua            SafeCall, Traceback, ElevateIdentity, Clone helpers.
  Janitor.lua         Cleanup container (connections, threads, instances).
  FileSystem.lua      JSON file persistence under the executor's workspace.
  ControlRegistry.lua UI controls bound to config flags with owner
                      versioning; values reapply on config load.
  ConfigManager.lua   Account defaults + named config profiles, auto save.
  ModuleManager.lua   Lifecycle: Register -> Init -> Enable -> Disable,
                      dependency-graph validation, dormant state restore,
                      per-module janitors and scoped registries.
  UIManager.lua       Device class, base window size, responsive helpers.
  MacLibProvider.lua  Fetches/loads the MacLib UI library.
  SessionManager.lua  Auto Execute (queue_on_teleport) + Auto Reconnect.
  CloudSync.lua       Jexvral Hub hello: loader key, applies this account's role.
  HubLive.lua         Jexvral Hub live socket: UI, values, rollouts, buttons.
  HubReadouts.lua     Jexvral Hub readouts (leaderstats, FPS, module values).
  UiSchema.lua        Records each control's tab, sub tab and section.
src/Modules/          Per-game feature modules (this is what you write):
  Misc.lua            Session tab: Auto Execute, Auto Reconnect.
  MobileButton.lua    Draggable PC/mobile toggle button (reclaims stale
                      copies from crashed sessions, syncs with the keybind).
  Performance.lua     Delete Enemies (tag-configurable), FPS Boost,
                      Disable 3D Rendering.
  Settings.lua        Configs (create/load/save/delete), Auto Load Selected,
                      Auto Save, Unload, Hide UI On Load, UI keybind,
                      UI size.
src/Main.lua          Bootstrap: re-execution safety, window, tabs, context.

## Module contract

A module file returns `function(Import)` which returns a definition table:

```lua
return {
    Name = "Example",            -- unique
    Version = 1,                 -- bump to invalidate saved owner state
    Priority = 10,               -- lower loads first
    Dependencies = {"Settings"}, -- module names

    Init = function(self, ctx)
        -- build UI into ctx.Tabs.<Tab>, read ctx.Config/ctx.Game
        -- ctx.Registry:Toggle/Slider/Dropdown/Input/Keybind bind UI <-> config
        -- ctx:RegisterCleanup(x) for every thread/connection/instance
        return state                       -- stored as the module state
    end,
    Enable  = function(self, ctx, state) end,  -- optional (dormant wake)
    Disable = function(self, ctx, state) end,  -- optional
}
```

## Lifecycle guarantees

- Re-execution: `Main` shuts down the previous runtime (`__BASE_HUB_RUNTIME`)
  completely before starting - modules disabled, janitors cleaned, MacLib gui
  and mobile button reclaimed by reserved names. No duplicate features.
- UI unload: `Window.onUnloaded` triggers the same full shutdown.
- New features across versions: registry owner versions apply saved values
  only to known flags; unknown/new flags fall back to defaults safely.
- Game-agnostic: no hardcoded game identifiers in Core; per-game knowledge
  lives only in Modules (and Build.lua URLs).

## Adapting to a new game

1. Copy the folder, rename in `Build.lua` (Name, Repository, RawBase,
   LoaderUrl, DataRoot stays `BaseHubData` or per-game root).
2. Point `REPOSITORIES` in `loader.lua` at the new game's raw paths.
3. Add game modules under `src/Modules/`, register in `manifest.lua` and
   `src/Main.lua`, add tabs in `Main`.
4. Keep `src/Core/` identical across games so fixes upstream can be pulled.
