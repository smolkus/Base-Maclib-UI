# Base Hub — usage, new-game setup, and deployment guide

Everything needed to run the base, adapt it to a new game, and serve it from
`jexvral.xyz/game/<game>/loader`. See `README.md` for the file layout and the
module contract.

---

## 1. Using the hub

Execute the loader once (per game, see section 3 for the URL):

```lua
loadstring(game:HttpGet("https://jexvral.xyz/game/base/loader"))()
```

What you get on first run:

- A MacLib window (keybind: RightShift by default) with **Misc**, and
  **Settings** tabs.
- A **Mobile UI Button** bottom-right (drag to move, tap to toggle). It uses
  the same show/hide path as the keybind, so they never desync. Toggle it in
  `Misc -> Session -> Interface`.
- An account config at `workspace/BaseHubData/account.json` storing your
  keybind, UI size, and session toggles.

Session toggles (Misc -> Session):

| Toggle | What it does |
| --- | --- |
| Auto Execute | Re-runs the loader automatically after teleports and rejoins. |
| Auto Reconnect | Recovers a dropped session with exponential backoff teleports. |

Settings tab:

- **Configs** — named config profiles (create / load / save / delete).
- **Auto Load Selected** — loads the selected profile on every execute.
- **Auto Save Settings** — saves changes automatically (Registry -> config).
- **Hide UI on Load**, **UI Hide / Show Key**, **UI Size** — appearance.
- **Unload** — full shutdown: every module disabled, every connection,
  thread, and GUI destroyed.

Re-executing at any time is safe: the previous runtime is shut down fully
before the new one initializes (no duplicate features, no orphan threads or
GUIs), and leftovers from a crashed session are reclaimed by name.

---

## 2. Starting a new game script from this base

1. **Copy the folder** to `projects/<New Game Name>` (keep the structure).
2. **`src/Build.lua`** — set `Name`, `Version`, `Repository`
   (`https://github.com/Byorl/<RepoName>`), `RawBase`
   (`https://jexvral.xyz/game/<code>/`), `LoaderUrl`
   (`https://jexvral.xyz/game/<code>/loader`), and `DataRoot`
   (`<Code>HubData`).
3. **`loader.lua`** — update `REPOSITORIES` to the same two URLs from
   step 2 (keep the GitHub fallback last), and nothing else.
4. **`manifest.lua`** — remove modules you do not need, add game modules.
   Paths may nest arbitrarily deep (`src/Modules/AutoFarm/Core/Scan.lua`).
5. **Add game modules** under `src/Modules/` following the module contract
   in `README.md`. Keep `src/Core/` identical across games so fixes can be
   pulled from one base to another.
6. **Register** new modules in `manifest.lua` and `src/Main.lua`, and add
   tabs (`TabGroup:Tab` / `SubTab`) for their UI.
7. **Do recon before writing logic** — dump the place file and inventory
   remotes, state replication, wave tables, and which side trusts what. The
   data the client ships (or lacks) decides what the modules can do.

Versioning: bump `Version` in `manifest.lua` and `src/Build.lua` together for
every release; the loader uses it as a cache-buster and the registry uses
module versions to migrate saved control state.

---

## Code conventions (required)

- **No Lua comments.** Never write `--` comments in `.lua`/`.luau` files —
  shipped code stays comment-free. Explanations belong here in the markdown
  docs, not in the code. This applies to every module, the loader, and any
  PoC or test script.
- Keep `src/Core/` stock across games; per-game knowledge only in
  `src/Modules/` and `Build.lua`.
- Bump `Version` in `manifest.lua` + `src/Build.lua` together per release.

## 3. Deploying to Hetzner (jexvral.xyz hosting)

Hosting is a **GitHub proxy**: `jexvral.xyz/game/<alias>/<path>` serves
`https://raw.githubusercontent.com/Byorl/<RepoName>/<ref>/<path>` through the
Node API. Deploying an update is therefore just `git push` — the server never
stores script files. The one-time per-game work is a repo + an alias.

### One-time per game

1. **Create the GitHub repo and push** (from the game's project folder):

   ```powershell
   git init
   git add -A
   git commit -m "Initial release"
   gh repo create Byorl/<RepoName> --public --source . --push
   ```

2. **Add the alias** in the Jexvral-Account-Manager repo:
   `jexvral-am-api/game-sources.js` -> `SOURCE_ALIASES`:

   ```js
   <code>: Object.freeze({
     repository: "Byorl/<RepoName>",
     ref: "main",
   }),
   ```

   `<code>` is the short URL code (`ap` = Anime Expeditions, `base` = this
   base). Lowercase, no spaces.

3. **Deploy the alias to the VPS** (only needed when `game-sources.js`
   changed — adding an alias qualifies):

   ```powershell
   scp -i $env:USERPROFILE\.ssh\jexvral_codex_ed25519 `
     jexvral-am-api/game-sources.js root@46.224.215.62:/root/jexvral-am-api/
   ssh -i $env:USERPROFILE\.ssh\jexvral_codex_ed25519 root@46.224.215.62 `
     "cd /root/jexvral-am-api && docker compose up -d --build api"
   ```

   Nginx needs no changes: `/game/` is already proxied to the API for all
   aliases.

### Every update after that

```powershell
git add -A ; git commit -m "changes" ; git push
```

Done. The served files come from GitHub `main` on request; the loader already
cache-busts with the manifest version.

### Verify

```powershell
curl.exe -s https://jexvral.xyz/game/<code>/manifest.lua
curl.exe -s -o NUL -w "%{http_code}" https://jexvral.xyz/game/<code>/loader
curl.exe -s https://jexvral.xyz/game/<code>/some/fake/path.lua
```

Expected: manifest JSON/Lua, `200` for the loader, and
`Source file was not found.` (404) for the fake path. Anything else means the
API container or nginx needs attention.

### Server reference (why this works)

| Piece | Where | Role |
| --- | --- | --- |
| Cloudflare | DNS front | Proxies jexvral.xyz to Hetzner. |
| nginx gateway | `/root/jexvral-gateway/nginx.conf` (docker) | `location /game/` proxies to the API. |
| Node API | `/root/jexvral-am-api/` (docker `jexvralam`) | `GET /game/:alias/*` -> GitHub raw via `game-sources.js`. |
| SSH | `%USERPROFILE%\.ssh\jexvral_codex_ed25519` as `root@46.224.215.62` | Deployment access. |

Server-side hard limits already in place: 5 MB max source file, 10s upstream
timeout, 16 concurrent fetches, clean 404/413/503/504 error text (the loader
rejects HTML/error documents and falls back to its GitHub repository).
