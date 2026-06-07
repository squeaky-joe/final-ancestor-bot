# Final Ancestor Bot

Discord bot and UE4SS Lua mods for a The Isle Evrima dedicated server.

## License

This project is licensed under the **GNU General Public License v3.0 (GPL-3.0)**.

This means:

- **You are free to** use, copy, modify, and distribute this project
- **If you distribute it** (modified or unmodified), you must release your source code under the same GPL-3.0 license
- **You cannot** take this code, modify it, and release it as closed-source or proprietary software
- **Any derivative work** — including forks, server-specific modifications, or projects that incorporate this code — must also be open source under GPL-3.0

The intent is to keep this project and anything built from it permanently open source. If you run a modified version of this bot for your own server, you're welcome to do so — just keep the source available.

See the [`LICENSE`](LICENSE) file for the full license text.

## Structure

```
final-ancestor-bot/
├── bot/                    # Discord.js v14 bot (TypeScript)
│   └── src/
│       ├── classes/        # FinalAncestorClient, Command, Listener, Logger
│       ├── commands/       # Slash commands (admin/, staff/, dino/)
│       ├── listeners/      # Discord event listeners (client/, interaction/)
│       ├── interactions/   # Button & modal handlers (buttons/, modals/)
│       ├── embeds/         # Embed + component builders
│       ├── heatmap/        # Heatmap collector, renderer, scheduler
│       ├── ipc/            # File-based IPC client
│       ├── db/             # Drizzle ORM schema & queries (PostgreSQL)
│       └── utils/          # Command loader, listener loader, command sync
└── mods/                   # UE4SS Lua mods for the game server
    ├── CommandBridge/      # IPC hub — routes commands to all other mods
    ├── DinoStorage/        # Store/retrieve dino state across respawns
    ├── SkinMod/            # Per-player skin color persistence
    ├── BodyDrop/           # AI-free corpse spawner
    ├── PrimeNotify/        # Prime eligibility quest notifications
    └── HeatmapCollector/   # Polls player positions every 5 min for heatmap
```

## How It Works

The bot communicates with the game server via **file-based IPC** (NDJSON files on a shared path). The bot writes commands to `CommandBridge/Saved/commands.ndjson` and reads results from `CommandBridge/Saved/results.ndjson`. CommandBridge polls for new commands and routes them to the appropriate sub-mod.

The **heatmap** runs on a separate pipeline: `HeatmapCollector` appends player positions to `HeatmapCollector/Saved/positions.ndjson` every 5 minutes. The bot drains this file into PostgreSQL every 30 minutes, renders a 1024×1024 PNG (gaussian heat blobs over a map image), and edits a pinned embed in the configured channel. The message persists across bot restarts.

## Bot Setup

### 1. Environment variables

Copy `.env.example` to `.env` and fill in your values:

```env
# Required
DISCORD_TOKEN=your_bot_token
DISCORD_CLIENT_ID=your_app_id
DISCORD_GUILD_ID=your_guild_id          # omit for global commands
DATABASE_URL=postgresql://user:pass@localhost:5432/final_ancestor
MODS_PATH=C:/Path/To/TheIsle/Binaries/Win64/Mods

# Optional
HEATMAP_MAP_PATH=C:/path/to/map.png     # overlay image for the heatmap
HEATMAP_MIN_X=-176000                   # world-space bounds (UE cm)
HEATMAP_MAX_X=176000
HEATMAP_MIN_Y=-176000
HEATMAP_MAX_Y=176000
HEATMAP_RETENTION_HOURS=24             # how many hours of history to show
```

### 2. Database

First, create the database if it doesn't already exist:

```bash
psql -U postgres -c "CREATE DATABASE final_ancestor;"
```

Then run Drizzle migrations to create all tables:

```bash
bun run db:migrate
```

Tables created: `users`, `skin_presets`, `body_drop_log`, `heatmap_positions`, `heatmap_config`, `guild_config`.

### 3. Install & run

```bash
bun install

bun run dev                       # development (ts-node / watch)
bun run build && bun run start    # production
```

Slash commands are synced automatically on startup — only when the command definitions have changed (SHA-1 hash cache in `.command-hash`).

## Mod Setup

1. Copy the contents of `mods/` into `<game>/Binaries/Win64/Mods/`
2. Merge `mods/mods.txt` with your existing `mods.txt` — **CommandBridge must load first**
3. Restart the server

All mods create their own `Saved/` directories on first run. No manual directory creation needed.

## Discord Commands

### Admin (`Administrator` permission required)

| Command | Description |
|---|---|
| `/setup link [channel]` | Post the Steam account link embed |
| `/setup storage [channel]` | Post the dino storage panel embed |
| `/setup heatmap [channel]` | Post the heatmap embed and start auto-updates |
| `/setup roles [admin] [mod]` | Configure the admin and moderator roles (run with no options to view current config) |

### Staff (Mod role required)

| Command | Description |
|---|---|
| `/bodydrop spawn <species> <x> <y> <z>` | Spawn a corpse at coordinates or near a player |
| `/bodydrop status` | Check body drop system status |

### Player (anyone)

| Command | Description |
|---|---|
| `/skin set <slot> <r> <g> <b>` | Set a color slot on your live dino |
| `/skin reset` | Remove your skin override |
| `/skin preset-save <name>` | Save your current skin as a named preset |
| `/skin preset-apply <name>` | Apply a saved preset to your live dino |
| `/skin preset-list` | List your saved presets |

Players also interact via **buttons** on the persistent embeds:

- **Link embed** — opens a modal to submit their Steam64 ID
- **Storage embed** — Park, Retrieve, List, and Slay buttons for dino storage

## Role Configuration

Roles are configured per-server in the database via `/setup roles` — no env vars needed.

| Role | Controls |
|---|---|
| **Admin role** | Who can run `/setup` subcommands. Falls back to Discord's native `Administrator` permission if not set. |
| **Mod role** | Who can run `/bodydrop` and other staff commands. Falls back to the admin role if not set, or allows everyone if neither is configured. |

```
/setup roles admin: @ServerAdmin mod: @Moderator
```

To view the current config without changing anything, run `/setup roles` with no options.

## Skin Color System

> ⚠️ **Subject to change.** The color system is tied to The Isle's internal material parameter names and may break with game updates. The command interface itself (subcommands, options, and workflow) may also be redesigned as the system evolves.

Colors are applied per-slot directly to the player's live dino via IPC. Each slot maps to a material parameter on the dino's mesh:

| Slot | Parameter |
|---|---|
| `body` | `BodyColor` |
| `markings` | `MarkingsColor` |
| `flank` | `FlankColor` |
| `underbelly` | `UnderbellyColor` |
| `detail` | `Detail1Color` |
| `eyes` | `EyesColor` |
| `breed` | `MaleDisplayColor` |
| `all` | All slots simultaneously |

Color values can be provided as **0–255** integers or **0.0–1.0** floats — the bot normalizes either range automatically. Colors are not persisted to the dino itself; they are re-applied from a saved preset on reconnect if the player has one active. Presets are stored in the `skin_presets` database table and are linked to the player's Discord account.

## Available Scripts

```bash
bun run dev          # run with live reload
bun run build        # compile to dist/ via tsup
bun run start        # run compiled dist/index.js
bun run typecheck    # tsc --noEmit
bun run lint         # biome lint
bun run format       # biome format --write
bun run check        # biome check --write
bun run db:migrate   # apply drizzle migrations
bun run db:studio    # open drizzle studio
```

## Tech Stack

| Layer | Choice |
|---|---|
| Runtime | Bun |
| Language | TypeScript (ESM, node22 target) |
| Discord | discord.js v14 |
| Database | PostgreSQL + Drizzle ORM |
| Heatmap rendering | @napi-rs/canvas |
| Build | tsup (`bundle: false`) |
| Lint / Format | Biome |
| Lua mods | UE4SS (Unreal Engine 5 mod framework) |
